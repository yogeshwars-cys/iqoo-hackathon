/// qnn_htp_delegate.dart
///
/// Qualcomm QNN HTP (Hexagon NPU) as a tflite_flutter [Delegate], for the
/// MiniLM encoder only.
///
/// The TfLiteDelegate* comes from `libvault_qnn_delegate.so`
/// (android/app/src/main/cpp/vault_qnn_delegate.cpp), which dlopen()s
/// Qualcomm's `libQnnTFLiteDelegate.so` through the external-delegate plugin
/// ABI. Creating one proves only that a delegate object exists — NOT that the
/// NPU runs the model. That is decided afterwards by qnn_acceptance.dart,
/// from the delegate's own partition report, output equivalence against
/// XNNPACK, and latency.

library;

import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
// TfLiteDelegate is the generated FFI struct the Delegate interface exposes.
// ignore: implementation_imports
import 'package:tflite_flutter/src/bindings/tensorflow_lite_bindings_generated.dart'
    show TfLiteDelegate;

/// QnnDelegate$Options$HtpPerformanceMode values (read from the AAR).
abstract final class HtpPerformanceMode {
  static const defaultMode = 0;
  static const sustainedHighPerformance = 1;
  static const burst = 2;
  static const highPerformance = 3;
  static const powerSaver = 4;
}

/// QnnDelegate$Options$HtpPrecision values.
abstract final class HtpPrecision {
  static const quantized = 0;
  static const fp16 = 1;
}

class QnnUnavailableException implements Exception {
  final String reason;
  const QnnUnavailableException(this.reason);
  @override
  String toString() => 'QNN unavailable: $reason';
}

/// What the device and the APK provide, from `vault/qnn` `environment`.
class QnnEnvironment {
  final String nativeLibraryDir;
  final String cacheDir;
  final String qnnRuntimeVersion;
  final bool delegateLibraryPackaged;
  final bool htpLibraryPackaged;
  final bool shimPackaged;
  final List<String> skels;
  final bool fastRpcLibraryPresent;
  final String? socManufacturer;
  final String? socModel;

  const QnnEnvironment({
    required this.nativeLibraryDir,
    required this.cacheDir,
    required this.qnnRuntimeVersion,
    required this.delegateLibraryPackaged,
    required this.htpLibraryPackaged,
    required this.shimPackaged,
    required this.skels,
    required this.fastRpcLibraryPresent,
    this.socManufacturer,
    this.socModel,
  });

  factory QnnEnvironment.fromMap(Map<Object?, Object?> m) => QnnEnvironment(
        nativeLibraryDir: m['nativeLibraryDir'] as String? ?? '',
        cacheDir: m['cacheDir'] as String? ?? '',
        qnnRuntimeVersion: m['qnnRuntimeVersion'] as String? ?? '?',
        delegateLibraryPackaged: m['delegateLibraryPackaged'] == true,
        htpLibraryPackaged: m['htpLibraryPackaged'] == true,
        shimPackaged: m['shimPackaged'] == true,
        skels: (m['skels'] as List?)?.cast<String>() ?? const [],
        fastRpcLibraryPresent: m['fastRpcLibraryPresent'] == true,
        socManufacturer: m['socManufacturer'] as String?,
        socModel: m['socModel'] as String?,
      );

  /// A reason QNN cannot possibly work, or null. Packaging and vendor-file
  /// checks only — passing them does not mean the NPU will run anything.
  String? get blockingReason {
    if (!shimPackaged) return 'libvault_qnn_delegate.so is not packaged';
    if (!delegateLibraryPackaged) return 'libQnnTFLiteDelegate.so is not packaged';
    if (!htpLibraryPackaged) return 'libQnnHtp.so is not packaged';
    if (skels.isEmpty) return 'no libQnnHtpV*Skel.so is packaged';
    if (!fastRpcLibraryPresent) {
      return 'vendor libcdsprpc.so (FastRPC) not found on this device';
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'native_library_dir': nativeLibraryDir,
        'qnn_runtime_version': qnnRuntimeVersion,
        'delegate_library_packaged': delegateLibraryPackaged,
        'htp_library_packaged': htpLibraryPackaged,
        'shim_packaged': shimPackaged,
        'skels': skels,
        'fastrpc_library_present': fastRpcLibraryPresent,
        'soc_manufacturer': socManufacturer,
        'soc_model': socModel,
      };
}

/// The delegate's own "N nodes delegated out of M" line.
class QnnDelegationReport {
  final bool found;
  final int? nodesDelegated;
  final int? nodesTotal;
  final int? partitions;
  final List<String> lines;

  const QnnDelegationReport({
    required this.found,
    this.nodesDelegated,
    this.nodesTotal,
    this.partitions,
    this.lines = const [],
  });

  static const missing = QnnDelegationReport(found: false);

  factory QnnDelegationReport.fromMap(Map<Object?, Object?> m) =>
      QnnDelegationReport(
        found: m['found'] == true,
        nodesDelegated: (m['nodesDelegated'] as num?)?.toInt(),
        nodesTotal: (m['nodesTotal'] as num?)?.toInt(),
        partitions: (m['partitions'] as num?)?.toInt(),
        lines: (m['lines'] as List?)?.cast<String>() ?? const [],
      );

  double? get delegatedFraction =>
      (found && (nodesTotal ?? 0) > 0) ? nodesDelegated! / nodesTotal! : null;

  Map<String, dynamic> toJson() => {
        'found': found,
        // Tail of the delegate / LiteRT / FastRPC log for this process, so a
        // failure can be diagnosed from a VaultLink ping without USB.
        if (lines.isNotEmpty)
          'log': lines.length > 20 ? lines.sublist(lines.length - 20) : lines,
        'nodes_delegated': nodesDelegated,
        'nodes_total': nodesTotal,
        'partitions': partitions,
      };
}

/// Platform hooks, injectable so the load/accept flow is testable on host.
abstract interface class QnnPlatform {
  Future<QnnEnvironment> environment();
  Future<QnnDelegationReport> delegationReport(DateTime since);

  /// Creates a native delegate or throws [QnnUnavailableException].
  Delegate createDelegate(QnnEnvironment env);
}

class AndroidQnnPlatform implements QnnPlatform {
  static const _channel = MethodChannel('vault/qnn');

  /// HTP settings for a float MiniLM: FP16 precision, burst clocks while
  /// embedding (the encoder runs in short bursts, not sustained load).
  final int performanceMode;
  final int precision;

  const AndroidQnnPlatform({
    this.performanceMode = HtpPerformanceMode.burst,
    this.precision = HtpPrecision.fp16,
  });

  @override
  Future<QnnEnvironment> environment() async {
    if (!Platform.isAndroid) {
      throw const QnnUnavailableException('QNN HTP requires Android');
    }
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>('environment');
      return QnnEnvironment.fromMap(map ?? const {});
    } on MissingPluginException {
      throw const QnnUnavailableException('vault/qnn channel not registered');
    }
  }

  @override
  Future<QnnDelegationReport> delegationReport(DateTime since) async {
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>(
        'delegationReport',
        {'sinceEpochMs': since.millisecondsSinceEpoch},
      );
      return map == null ? QnnDelegationReport.missing : QnnDelegationReport.fromMap(map);
    } catch (_) {
      return QnnDelegationReport.missing;
    }
  }

  @override
  Delegate createDelegate(QnnEnvironment env) => QnnHtpDelegate.create(
        env,
        performanceMode: performanceMode,
        precision: precision,
      );
}

typedef _PrepareNative = Int32 Function(Pointer<Utf8>);
typedef _PrepareDart = int Function(Pointer<Utf8>);
typedef _CreateNative = Pointer<Void> Function(
    Pointer<Utf8>, Int32, Int32, Int32, Pointer<Utf8>, Pointer<Utf8>);
typedef _CreateDart = Pointer<Void> Function(
    Pointer<Utf8>, int, int, int, Pointer<Utf8>, Pointer<Utf8>);
typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _DestroyDart = void Function(Pointer<Void>);
typedef _ErrorNative = Pointer<Utf8> Function();

class _QnnShim {
  final _PrepareDart prepare;
  final _CreateDart create;
  final _DestroyDart destroy;
  final Pointer<Utf8> Function() lastError;

  _QnnShim._(this.prepare, this.create, this.destroy, this.lastError);

  static _QnnShim? _instance;

  static _QnnShim load() {
    final existing = _instance;
    if (existing != null) return existing;
    final DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open('libvault_qnn_delegate.so');
    } catch (e) {
      throw QnnUnavailableException('cannot open libvault_qnn_delegate.so ($e)');
    }
    return _instance = _QnnShim._(
      lib.lookupFunction<_PrepareNative, _PrepareDart>('vault_qnn_prepare'),
      lib.lookupFunction<_CreateNative, _CreateDart>('vault_qnn_delegate_create'),
      lib.lookupFunction<_DestroyNative, _DestroyDart>('vault_qnn_delegate_destroy'),
      lib.lookupFunction<_ErrorNative, Pointer<Utf8> Function()>('vault_qnn_last_error'),
    );
  }
}

/// A live QNN HTP delegate. Must outlive every interpreter it was added to.
class QnnHtpDelegate implements Delegate {
  final Pointer<Void> _handle;
  bool _deleted = false;

  QnnHtpDelegate._(this._handle);

  static const modelToken = 'minilm_l6_v2';

  factory QnnHtpDelegate.create(
    QnnEnvironment env, {
    int performanceMode = HtpPerformanceMode.burst,
    int precision = HtpPrecision.fp16,
    int logLevel = 3, // INFO: needed for the delegation report
  }) {
    final blocking = env.blockingReason;
    if (blocking != null) throw QnnUnavailableException(blocking);

    final shim = _QnnShim.load();
    final dir = env.nativeLibraryDir.toNativeUtf8();
    final cache = env.cacheDir.toNativeUtf8();
    final token = modelToken.toNativeUtf8();
    try {
      final rc = shim.prepare(dir);
      if (rc != 0) {
        throw QnnUnavailableException(shim.lastError().toDartString());
      }
      final handle =
          shim.create(dir, performanceMode, precision, logLevel, cache, token);
      if (handle == nullptr) {
        throw QnnUnavailableException(shim.lastError().toDartString());
      }
      return QnnHtpDelegate._(handle);
    } finally {
      calloc.free(dir);
      calloc.free(cache);
      calloc.free(token);
    }
  }

  @override
  Pointer<TfLiteDelegate> get base => _handle.cast<TfLiteDelegate>();

  @override
  void delete() {
    if (_deleted) return;
    _deleted = true;
    _QnnShim.load().destroy(_handle);
  }
}
