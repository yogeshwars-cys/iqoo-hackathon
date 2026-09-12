/// Host-side tests for the reasoning benchmark.
///
/// `LlmRuntime` talks to the real MediaPipe engine over the `vault/llm`
/// method channel, which does not exist on a test host. Every test here
/// stands a fake handler in for it — `flutter_test`'s mock binary messenger
/// runs the same encode/decode path a real platform channel would, so this
/// still exercises [LlmRuntime]'s backend bookkeeping and
/// [LlmBenchmarkRunner]'s timing/error handling for real, just without an
/// actual model or an actual phone.

library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/llm/llm_runtime.dart';
import 'package:vault_rag_test/telemetry/benchmark_runner.dart' show LatencyStats;
import 'package:vault_rag_test/telemetry/compute_telemetry.dart';
import 'package:vault_rag_test/telemetry/llm_benchmark_runner.dart';

const _channel = MethodChannel('vault/llm');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late File modelFile;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('vault_llm_bench_test');
    // Filename carries "-cpu-" so model_probe.dart's backend inference is
    // unambiguous and LlmRuntime.load never has to guess.
    modelFile = File('${tmpDir.path}/gemma-cpu-int4.task');
    // A MediaPipe .task bundle is a zip; only the local-file-header magic
    // (PK\x03\x04) is checked, so this is enough for probeModel to call it
    // supported without needing real weights.
    await modelFile.writeAsBytes(
      Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, ...List.filled(32, 0)]),
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    await tmpDir.delete(recursive: true);
  });

  /// Installs [onCall] as the fake native side and loads [modelFile] through
  /// it, asserting the load itself succeeds so a test failure inside the
  /// benchmark can't be confused with a broken fixture.
  Future<LlmRuntime> loadedRuntime(
    Future<dynamic> Function(MethodCall call) onCall,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, onCall);
    final runtime = LlmRuntime();
    final ok = await runtime.load(modelFile.path);
    expect(ok, isTrue,
        reason: 'fixture load failed: ${runtime.error} — a broken fixture, '
            'not the thing under test');
    return runtime;
  }

  group('LlmBenchmarkRunner', () {
    test('refuses to run when nothing is loaded, rather than throwing',
        () async {
      final runtime = LlmRuntime();
      final telemetry = ComputeTelemetry(meter: InferenceMeter());
      addTearDown(telemetry.dispose);
      final runner = LlmBenchmarkRunner(llm: runtime, telemetry: telemetry);

      final report = await runner.run(warmup: 0, iterations: 1);

      expect(report, isNull);
      expect(runner.report, isNull);
    });

    test('times generation on whichever backend is already loaded, and '
        'never asks the channel to load a second one', () async {
      var loadCalls = 0;
      var generateCalls = 0;
      final runtime = await loadedRuntime((call) async {
        if (call.method == 'load') {
          loadCalls++;
          return null;
        }
        if (call.method == 'generate') {
          generateCalls++;
          // A real generation takes seconds; this only has to take long
          // enough that the Stopwatch around it reads a positive elapsed
          // time, so tokens/second is not spuriously divided by zero.
          await Future<void>.delayed(const Duration(milliseconds: 2));
          return {'text': 'answer $generateCalls', 'tokens': 12};
        }
        return null;
      });
      addTearDown(runtime.dispose);

      final telemetry = ComputeTelemetry(meter: InferenceMeter());
      addTearDown(telemetry.dispose);
      final runner = LlmBenchmarkRunner(llm: runtime, telemetry: telemetry);

      final report = await runner.run(warmup: 1, iterations: 3);

      expect(report, isNotNull);
      expect(report!.backend, 'cpu');
      expect(report.error, isNull);
      expect(report.latency.count, 3);
      expect(report.tokensPerSecond.length, 3);
      // One warm-up, discarded, plus the three timed iterations.
      expect(generateCalls, 4);
      // The whole point of this runner: it must never re-invoke load.
      expect(loadCalls, 1);
    });

    test('a generation failure stops the run and lands in the report '
        'instead of throwing past the caller', () async {
      var generateCalls = 0;
      final runtime = await loadedRuntime((call) async {
        if (call.method == 'load') return null;
        if (call.method == 'generate') {
          generateCalls++;
          if (generateCalls == 2) {
            throw PlatformException(
                code: 'GENERATE_FAILED', message: 'boom');
          }
          return {'text': 'ok', 'tokens': 5};
        }
        return null;
      });
      addTearDown(runtime.dispose);

      final telemetry = ComputeTelemetry(meter: InferenceMeter());
      addTearDown(telemetry.dispose);
      final runner = LlmBenchmarkRunner(llm: runtime, telemetry: telemetry);

      final report = await runner.run(warmup: 0, iterations: 5);

      expect(report, isNotNull);
      expect(report!.error, contains('boom'));
      // Stopped after the failing call, not padded out to 5 with zeros.
      expect(report.latency.count, 1);
    });

    test('a generation that reports no token count is timed but excluded '
        'from the tokens/second figures, never estimated', () async {
      final runtime = await loadedRuntime((call) async {
        if (call.method == 'load') return null;
        if (call.method == 'generate') {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          return {'text': 'ok', 'tokens': null};
        }
        return null;
      });
      addTearDown(runtime.dispose);

      final telemetry = ComputeTelemetry(meter: InferenceMeter());
      addTearDown(telemetry.dispose);
      final runner = LlmBenchmarkRunner(llm: runtime, telemetry: telemetry);

      final report = await runner.run(warmup: 0, iterations: 2);

      expect(report!.latency.count, 2);
      expect(report.tokensPerSecond, isEmpty);
      expect(report.meanTokensPerSecond, isNull);
      expect(report.toJson().containsKey('tokens_per_second_mean'), isFalse);
    });
  });

  group('LlmBenchmarkReport.toJson', () {
    test('carries backend, model and compute usage through verbatim', () {
      final report = LlmBenchmarkReport(
        startedAt: DateTime(2026, 1, 1),
        warmup: 1,
        backend: 'cpu',
        modelLabel: 'gemma-cpu-int4.task',
        loadMs: 1234,
        latency: LatencyStats([1000, 1500, 1200]),
        tokensPerSecond: const [4.2, 4.4],
        computeUsage: summarizeUsage(const []),
      );

      final json = report.toJson();
      expect(json['backend'], 'cpu');
      expect(json['model'], 'gemma-cpu-int4.task');
      expect(json['load_ms'], 1234);
      expect(json['tokens_per_second_mean'], 4.3);
      expect(json['generation'], report.latency.toJson());
      expect(json.containsKey('stopped_early'), isFalse);
    });
  });
}
