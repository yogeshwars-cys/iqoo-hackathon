/// The 20-second clipboard lifecycle, under fake time. No real clipboard.

library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/security/ephemeral_clipboard.dart';

class FakeClipboard implements ClipboardPort {
  String? content;
  bool readable = true;
  int clears = 0;

  @override
  Future<String?> read() async => readable ? content : null;
  @override
  Future<void> write(String text) async => content = text;
  @override
  Future<void> clear() async {
    clears++;
    content = null;
  }
}

void main() {
  late FakeClipboard port;
  setUp(() => port = FakeClipboard());

  test('copy starts a 20-second countdown', () {
    fakeAsync((async) {
      final clip = EphemeralClipboard(port: port);
      clip.copy('{"capsule": 1}');
      async.flushMicrotasks();
      expect(port.content, '{"capsule": 1}');
      expect(clip.isActive, isTrue);
      expect(clip.secondsRemaining, 20);
      async.elapse(const Duration(seconds: 5));
      expect(clip.secondsRemaining, 15);
      async.elapse(const Duration(seconds: 14));
      expect(clip.secondsRemaining, 1);
      expect(port.clears, 0);
      clip.dispose();
    });
  });

  test('an unchanged capsule is cleared at t=20s', () {
    fakeAsync((async) {
      final clip = EphemeralClipboard(port: port);
      clip.copy('capsule');
      async.elapse(const Duration(seconds: 20));
      async.flushMicrotasks();
      expect(port.clears, 1);
      expect(port.content, isNull);
      expect(clip.isActive, isFalse);
      expect(clip.lastOutcome, ScrubOutcome.cleared);
      clip.dispose();
    });
  });

  test('a clipboard the user replaced is left untouched', () {
    fakeAsync((async) {
      final clip = EphemeralClipboard(port: port);
      clip.copy('capsule');
      async.elapse(const Duration(seconds: 8));
      port.content = '+91 98765 43210'; // the user copied something else
      async.elapse(const Duration(seconds: 12));
      async.flushMicrotasks();
      expect(port.clears, 0);
      expect(port.content, '+91 98765 43210');
      expect(clip.lastOutcome, ScrubOutcome.replaced);
      clip.dispose();
    });
  });

  test('copying again resets the lifecycle for the new capsule', () {
    fakeAsync((async) {
      final clip = EphemeralClipboard(port: port);
      clip.copy('first');
      async.elapse(const Duration(seconds: 15));
      clip.copy('second');
      async.flushMicrotasks();
      expect(clip.secondsRemaining, 20);
      async.elapse(const Duration(seconds: 10)); // 25 s after the first copy
      async.flushMicrotasks();
      expect(port.clears, 0);
      expect(port.content, 'second');
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(port.clears, 1);
      clip.dispose();
    });
  });

  test('dispose cancels the timer; nothing is cleared afterwards', () {
    fakeAsync((async) {
      final clip = EphemeralClipboard(port: port);
      clip.copy('capsule');
      async.elapse(const Duration(seconds: 3));
      clip.dispose();
      async.elapse(const Duration(seconds: 60));
      async.flushMicrotasks();
      expect(port.clears, 0);
      expect(async.periodicTimerCount, 0);
    });
  });

  test('unreadable at expiry (backgrounded) defers to checkNow on resume', () {
    fakeAsync((async) {
      final clip = EphemeralClipboard(port: port);
      clip.copy('capsule');
      port.readable = false;
      async.elapse(const Duration(seconds: 20));
      async.flushMicrotasks();
      expect(port.clears, 0);
      expect(clip.lastOutcome, ScrubOutcome.unreadable);

      port.readable = true; // app resumed
      clip.checkNow();
      async.flushMicrotasks();
      expect(port.clears, 1);
      expect(clip.lastOutcome, ScrubOutcome.cleared);
      clip.dispose();
    });
  });
}
