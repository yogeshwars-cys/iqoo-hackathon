/// ephemeral_clipboard.dart
///
/// Put a capsule on the clipboard for [kClipboardTtl], then remove it — but
/// only if it is still the capsule.
///
/// THE COMPARISON IS THE WHOLE FEATURE. After 20 seconds the user may have
/// copied a phone number, a password, anything. Clearing "the clipboard" at
/// that point would destroy their data to protect ours. So at expiry the
/// current clip is read back and cleared only when it is byte-identical to
/// what Vault wrote. Anything else is left alone.
///
/// Honest limits:
///
///  * Android has no atomic compare-and-clear. A copy landing in the few
///    milliseconds between the read and the clear would be removed.
///  * Android 10+ lets only the foreground app read the clipboard. If Vault
///    is backgrounded at expiry the read returns null; we then cannot prove
///    the clip is still ours, so nothing is cleared until [checkNow] runs
///    again (the page calls it on resume).
///  * Clipboard history, sync services (Office Kit included) and keyboard
///    apps may already hold a copy. Scrubbing the primary clip does not reach
///    them.
///
/// A second [copy] supersedes the first: its timer is cancelled and a fresh
/// 20-second lifecycle starts for the new text.

library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'security_constants.dart';

/// The three clipboard operations, behind an interface for tests.
abstract interface class ClipboardPort {
  Future<String?> read();
  Future<void> write(String text);
  Future<void> clear();
}

/// Platform clipboard. Writes go through `vault/clipboard` so Android 13+
/// masks the preview (EXTRA_IS_SENSITIVE) and clears use clearPrimaryClip();
/// both fall back to Flutter's Clipboard where that channel does not exist.
class SystemClipboardPort implements ClipboardPort {
  static const _channel = MethodChannel('vault/clipboard');

  const SystemClipboardPort();

  @override
  Future<String?> read() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  @override
  Future<void> write(String text) async {
    try {
      await _channel.invokeMethod<void>('setSensitiveText', text);
    } on MissingPluginException {
      await Clipboard.setData(ClipboardData(text: text));
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _channel.invokeMethod<void>('clear');
    } on MissingPluginException {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  }
}

enum ScrubOutcome {
  /// Still ours at expiry; removed.
  cleared,

  /// The user copied something else; left untouched.
  replaced,

  /// Could not read the clipboard (backgrounded); will retry on [checkNow].
  unreadable,

  /// A newer [copy] took over before this one expired.
  superseded,
}

class EphemeralClipboard extends ChangeNotifier {
  final ClipboardPort port;
  final Duration ttl;

  EphemeralClipboard({
    this.port = const SystemClipboardPort(),
    this.ttl = kClipboardTtl,
  });

  String? _owned;
  int _generation = 0;
  Timer? _ticker;

  /// Whole seconds elapsed in the current lifecycle, counted by the ticker
  /// (not a Stopwatch) so tests can drive it with fake time.
  int _elapsedSeconds = 0;
  bool _disposed = false;
  ScrubOutcome? _lastOutcome;

  /// A capsule Vault wrote is (as far as we know) still on the clipboard.
  bool get isActive => _owned != null && _ticker != null;

  /// Whole seconds until expiry, counting down ttl..0.
  int get secondsRemaining =>
      isActive ? (ttl.inSeconds - _elapsedSeconds).clamp(0, ttl.inSeconds) : 0;

  /// 1.0 at copy time, 0.0 at expiry.
  double get fractionRemaining => ttl.inSeconds == 0
      ? 0
      : secondsRemaining / ttl.inSeconds;

  ScrubOutcome? get lastOutcome => _lastOutcome;

  /// Writes [text] and starts (or restarts) the TTL.
  Future<void> copy(String text) async {
    _stopTicker();
    final generation = ++_generation;
    await port.write(text);
    if (_disposed || generation != _generation) return;

    _owned = text;
    _lastOutcome = null;
    _elapsedSeconds = 0;
    // One tick per second drives both the visible countdown and expiry.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _elapsedSeconds++;
      if (_elapsedSeconds >= ttl.inSeconds) {
        unawaited(_expire(generation));
      }
      _notify();
    });
    _notify();
  }

  /// Re-attempts a pending scrub (e.g. on app resume, when the clipboard is
  /// readable again). No-op when nothing is pending.
  Future<ScrubOutcome?> checkNow() async {
    if (_owned == null) return null;
    if (_ticker != null) return null; // still counting down
    return _expire(_generation);
  }

  Future<ScrubOutcome> _expire(int generation) async {
    if (generation != _generation) return ScrubOutcome.superseded;
    _stopTicker();
    final owned = _owned;
    if (owned == null) return _finish(ScrubOutcome.superseded);

    final String? current;
    try {
      current = await port.read();
    } catch (_) {
      return _finish(ScrubOutcome.unreadable, keepPending: true);
    }
    if (generation != _generation) return ScrubOutcome.superseded;
    if (current == null) {
      return _finish(ScrubOutcome.unreadable, keepPending: true);
    }
    if (current != owned) {
      _owned = null;
      return _finish(ScrubOutcome.replaced);
    }
    await port.clear();
    _owned = null;
    return _finish(ScrubOutcome.cleared);
  }

  ScrubOutcome _finish(ScrubOutcome outcome, {bool keepPending = false}) {
    if (!keepPending) _owned = null;
    _lastOutcome = outcome;
    _notify();
    return outcome;
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Cancels the timer. The pending capsule, if any, is NOT force-cleared
  /// here: without a successful read-back we cannot know it is still ours.
  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _stopTicker();
    super.dispose();
  }
}
