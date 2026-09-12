/// device_info.dart
///
/// Dart side of the `vault/device` method channel.
///
/// Only two things live here, because only two things genuinely need native
/// code: the SoC identity and the thermal throttling state. Everything else
/// the stats screen shows comes from procfs via telemetry_sources.dart.
///
/// Thermal status is the important one. A phone benchmark that does not
/// report throttling is close to meaningless — the same workload on the
/// same device returns a completely different number depending on how warm
/// it already was, and there is no sysfs file an unprivileged app can read
/// to find out. PowerManager knows, so we ask it.

library;

import 'package:flutter/services.dart';

const _channel = MethodChannel('vault/device');

class DeviceFacts {
  final String? manufacturer;
  final String? model;
  final String? socManufacturer;
  final String? socModel;
  final String? androidRelease;
  final int? sdkInt;
  final int? totalMemMb;
  final List<String> abis;

  const DeviceFacts({
    this.manufacturer,
    this.model,
    this.socManufacturer,
    this.socModel,
    this.androidRelease,
    this.sdkInt,
    this.totalMemMb,
    this.abis = const [],
  });

  static const unknown = DeviceFacts();

  /// "realme RMX3660 · Qualcomm SM6375 · Android 14"
  String get summary {
    final parts = <String>[];
    final device = [manufacturer, model].whereType<String>().join(' ').trim();
    if (device.isNotEmpty) parts.add(device);

    final soc = [socManufacturer, socModel].whereType<String>().join(' ').trim();
    // SOC_MODEL is API 31+; below that the honest answer is that the
    // platform will not say, not a guess derived from the board name.
    if (soc.isNotEmpty) parts.add(soc);

    if (androidRelease != null) parts.add('Android $androidRelease');
    return parts.isEmpty ? 'Unknown device' : parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
        'manufacturer': manufacturer,
        'model': model,
        'soc_manufacturer': socManufacturer,
        'soc_model': socModel,
        'android_release': androidRelease,
        'sdk_int': sdkInt,
        'total_mem_mb': totalMemMb,
        'abis': abis,
      };

  static Future<DeviceFacts> load() async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('deviceInfo');
      if (map == null) return unknown;
      return DeviceFacts(
        manufacturer: map['manufacturer'] as String?,
        model: map['model'] as String?,
        socManufacturer: map['socManufacturer'] as String?,
        socModel: map['socModel'] as String?,
        androidRelease: map['androidRelease'] as String?,
        sdkInt: (map['sdkInt'] as num?)?.toInt(),
        totalMemMb: (map['totalMemMb'] as num?)?.toInt(),
        abis: (map['supportedAbis'] as List?)?.cast<String>() ?? const [],
      );
    } catch (_) {
      // MissingPluginException on a hot restart, or a non-Android host.
      // Neither is worth failing a screen over.
      return unknown;
    }
  }
}

class ThermalState {
  /// PowerManager's 0..6 scale.
  final int status;
  final String label;
  final bool throttling;

  const ThermalState({
    required this.status,
    required this.label,
    required this.throttling,
  });

  /// API 28 and below, or the platform declined to answer.
  static const unknown =
      ThermalState(status: -1, label: 'unknown', throttling: false);

  bool get isKnown => status >= 0;

  Map<String, dynamic> toJson() =>
      {'status': status, 'label': label, 'throttling': throttling};

  static Future<ThermalState> read() async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('thermal');
      if (map == null) return unknown;
      return ThermalState(
        status: (map['status'] as num?)?.toInt() ?? -1,
        label: (map['label'] as String?) ?? 'unknown',
        throttling: (map['throttling'] as bool?) ?? false,
      );
    } catch (_) {
      return unknown;
    }
  }
}
