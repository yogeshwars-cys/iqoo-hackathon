/// Per-hardware leases: NPU embedding and GPU generation are tracked
/// independently, and their overlap is measurable.

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/compute_ledger.dart';
import 'package:vault_rag_test/core/llm/llama_runtime.dart';
import 'package:vault_rag_test/telemetry/compute_telemetry.dart';

void main() {
  late DateTime now;
  late InferenceMeter meter;
  final t0 = DateTime(2026, 9, 13, 12);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  setUp(() {
    now = t0;
    meter = InferenceMeter(now: () => now);
  });

  test('GPU and NPU are active independently — no single slot to overwrite', () {
    final gen = meter.begin(ComputeHardware.gpu, 'llama.cpp');
    final emb = meter.begin(ComputeHardware.npu, 'minilm');
    expect(meter.activeHardware, {ComputeHardware.gpu, ComputeHardware.npu});

    emb.end();
    expect(meter.activeHardware, {ComputeHardware.gpu});
    gen.end();
    expect(meter.activeHardware, isEmpty);
  });

  test('nested leases on one hardware count, and end() is idempotent', () {
    final a = meter.begin(ComputeHardware.npu, 'minilm');
    final b = meter.begin(ComputeHardware.npu, 'minilm');
    a.end();
    a.end();
    expect(meter.activeCount(ComputeHardware.npu), 1);
    expect(meter.activeHardware, {ComputeHardware.npu});
    b.end();
    expect(meter.activeCount(ComputeHardware.npu), 0);
  });

  test('busy time is a union, overlap is an intersection', () {
    // GPU generation 0..1000 ms; NPU embeddings 200..300, 250..400, 900..1200.
    now = at(0);
    final gen = meter.begin(ComputeHardware.gpu, 'llama.cpp');
    now = at(200);
    final e1 = meter.begin(ComputeHardware.npu, 'minilm');
    now = at(250);
    final e2 = meter.begin(ComputeHardware.npu, 'minilm');
    now = at(300);
    e1.end();
    now = at(400);
    e2.end();
    now = at(900);
    final e3 = meter.begin(ComputeHardware.npu, 'minilm');
    now = at(1000);
    gen.end();
    now = at(1200);
    e3.end();

    expect(meter.busyTime(ComputeHardware.gpu, at(0), at(1200)),
        const Duration(milliseconds: 1000));
    expect(meter.busyTime(ComputeHardware.npu, at(0), at(1200)),
        const Duration(milliseconds: 500)); // 200..400 merged + 900..1200
    expect(meter.overlapTime(ComputeHardware.npu, ComputeHardware.gpu, at(0), at(1200)),
        const Duration(milliseconds: 300)); // 200..400 + 900..1000
    // Clipped to a window.
    expect(meter.overlapTime(ComputeHardware.npu, ComputeHardware.gpu, at(950), at(1200)),
        const Duration(milliseconds: 50));
  });

  test('an open lease counts as busy up to now', () {
    meter.begin(ComputeHardware.gpu, 'mediapipe');
    now = at(700);
    expect(meter.busyTime(ComputeHardware.gpu, at(0), at(700)),
        const Duration(milliseconds: 700));
  });

  group('llama.cpp hardware comes from ggml, not the button', () {
    test('OpenCL GPU device resolves to GPU', () {
      expect(
        hardwareFromLlamaStatus({
          'loaded_backend': 'GPUOpenCL (QUALCOMM Adreno(TM) 840)',
          'devices': [
            {'name': 'CPU', 'type': 'cpu'},
            {'name': 'GPUOpenCL', 'type': 'gpu'},
          ],
        }),
        ComputeHardware.gpu,
      );
    });

    test('CPU, unknown or missing status is CPU — never NPU', () {
      expect(hardwareFromLlamaStatus(null), ComputeHardware.cpu);
      expect(hardwareFromLlamaStatus({'loaded_backend': 'CPU'}), ComputeHardware.cpu);
      expect(
        hardwareFromLlamaStatus({
          'loaded_backend': 'HTP0',
          'devices': [
            {'name': 'HTP0', 'type': 'accel'},
          ],
        }),
        ComputeHardware.cpu,
      );
    });
  });
}
