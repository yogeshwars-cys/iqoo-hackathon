/// compute_ledger.dart
///
/// Who is running on which silicon, right now — recorded by the code that
/// actually dispatched the work, not inferred from utilisation counters.
///
/// WHY LEASES AND NOT ONE "ACTIVE HARDWARE" SLOT
///
/// The whole point of the two-model pipeline is that MiniLM embeds on the
/// NPU while the reasoner decodes on the GPU, at the same time. A single
/// global "current hardware" field can only hold one of those, so whichever
/// operation started last overwrote the other and the telemetry showed a
/// pipeline that never overlapped. Here every operation takes a lease on the
/// hardware it runs on; hardware is active while its lease count is > 0, and
/// any number of leases on different hardware coexist.
///
/// WHERE THE HARDWARE LABEL COMES FROM
///
/// The caller passes the hardware the RUNTIME confirmed:
///  * MiniLM: `npu` only when the QNN HTP delegate was accepted by the
///    validation in embedding_service.dart; otherwise `cpu` (XNNPACK / CPU).
///  * llama.cpp: the device type of `loaded_backend` from ggml's own
///    registry (LlamaChannel backendStatus), not the button pressed.
///  * MediaPipe: the backend its `load` succeeded on.
/// Nothing is ever labelled NPU because of the SoC's branding.

library;

enum ComputeHardware { cpu, gpu, npu }

/// A handle for one in-progress operation. [end] is idempotent.
abstract interface class ComputeLease {
  ComputeHardware get hardware;
  String get source;
  void end();
}

abstract interface class ComputeLedger {
  /// Starts an operation of [source] (e.g. "minilm", "llama.cpp") on
  /// [hardware]. [evidence] says why that hardware was attributed.
  ComputeLease begin(ComputeHardware hardware, String source, {String? evidence});
}

/// For code paths with no telemetry attached (tests, benchmarks).
class NullComputeLedger implements ComputeLedger {
  const NullComputeLedger();

  @override
  ComputeLease begin(ComputeHardware hardware, String source, {String? evidence}) =>
      _NullLease(hardware, source);
}

class _NullLease implements ComputeLease {
  @override
  final ComputeHardware hardware;
  @override
  final String source;
  _NullLease(this.hardware, this.source);
  @override
  void end() {}
}
