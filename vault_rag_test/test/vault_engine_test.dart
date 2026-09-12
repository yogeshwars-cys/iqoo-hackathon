/// Host-side tests for VaultEngine's serialisation and disposal.
///
/// These run with no model and no database: every case here is about the
/// promise chain and the lifecycle guards around it, which is exactly the
/// machinery that has no visible symptom until it fails natively on a
/// device. A queued task reaching a freed TFLite interpreter is a SIGSEGV,
/// not an exception, so it cannot be caught after the fact — it has to be
/// made impossible beforehand, and that is what these assert.

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/vault_engine.dart';

void main() {
  group('VaultEngine disposal', () {
    test('refuses new work once disposed', () async {
      final engine = VaultEngine();
      engine.dispose();

      // search() goes through _serialized, which must reject at the entry
      // point rather than reaching the interpreter.
      await expectLater(
        engine.search('anything'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        engine.indexDocument('a.txt', 'body'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        engine.embedOnce('text'),
        throwsA(isA<StateError>()),
      );
    });

    test('a call queued before disposal does not run after it', () async {
      // The dangerous ordering: work is accepted while the engine is alive,
      // then dispose() happens before that work reaches the front of the
      // queue. Without the inner guard the task would call embed() on a
      // closed interpreter.
      final engine = VaultEngine();

      // Not awaited: this sits in the queue. It fails either way (no model
      // is loaded), but it must fail as a StateError from the guard rather
      // than by touching native memory.
      final queued = engine.search('queued before dispose');
      engine.dispose();

      await expectLater(queued, throwsA(isA<StateError>()));
    });

    test('disposing twice asserts, as ChangeNotifier intends', () {
      // Documenting the convention rather than defending against it. Flutter
      // asserts on a double dispose on purpose: it is a lifecycle bug in the
      // caller, and swallowing it here would hide the real one. The engine
      // has exactly one owner (AppShell) and is disposed exactly once.
      final engine = VaultEngine()..dispose();
      expect(engine.dispose, throwsA(isA<AssertionError>()));
    });

    test('does not notify listeners after disposal', () async {
      // ChangeNotifier throws if notified post-dispose. Async work finishing
      // after the widget tree is gone is the normal case here, not an edge
      // one, so a raw notifyListeners() in the queue would crash the app on
      // backgrounding mid-request.
      final engine = VaultEngine();
      var notifications = 0;
      engine.addListener(() => notifications++);

      engine.dispose();
      // Give the drained-lock callback a turn to run.
      await Future<void>.delayed(Duration.zero);

      expect(notifications, 0);
    });
  });

  group('VaultEngine serialisation', () {
    test('an engine with no store reports zero chunks rather than throwing',
        () {
      final engine = VaultEngine();
      expect(engine.chunkCount, 0);
      expect(engine.isReady, isFalse);
      expect(engine.state, EngineState.loading);
      engine.dispose();
    });

    test('a failing call does not break the chain for the next one',
        () async {
      // The lock is a promise chain. If a rejected task poisoned it, the
      // first failure would wedge the engine permanently — and the bridge
      // has no way to recover from that short of a restart.
      final engine = VaultEngine();

      await expectLater(engine.search('one'), throwsA(anything));
      await expectLater(engine.search('two'), throwsA(anything));

      // Still accepting work, still failing for the same honest reason
      // (no store) rather than a wedged chain.
      await expectLater(engine.search('three'), throwsA(isA<StateError>()));
      engine.dispose();
    });

    test('describe() is safe before initialise and reports the true state',
        () {
      final engine = VaultEngine();
      final described = engine.describe();

      expect(described['state'], 'loading');
      expect(described['total_indexed'], 0);
      // The LLM block must always be present so a consumer can branch on it
      // without a null check.
      expect(described['llm'], isNotNull);
      expect((described['llm'] as Map)['state'], 'unloaded');
      engine.dispose();
    });
  });

  group('VaultEngine.ask without a model', () {
    test('is not wrapped in the lock, so it cannot deadlock', () async {
      // ask() calls search(), which takes the lock itself. If ask() also
      // took it, the inner call would queue behind the outer one and wait
      // for a future that can never complete — the first query would hang
      // forever with no error.
      //
      // With no store the call fails fast; the point of the test is that it
      // COMPLETES rather than hanging.
      final engine = VaultEngine();

      await expectLater(
        engine.ask('anything').timeout(const Duration(seconds: 2)),
        throwsA(isA<StateError>()),
      );
      engine.dispose();
    });
  });
}
