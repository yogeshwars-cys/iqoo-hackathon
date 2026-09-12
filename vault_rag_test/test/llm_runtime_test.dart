/// Host-side tests for LlmRuntime's pre-flight length guard.
///
/// Everything else about LlmRuntime needs the real `vault/llm` channel and a
/// real model; this one behaviour is pure Dart arithmetic gating a call, so
/// it is worth locking down on its own. See the long comment on
/// LlmRuntime.generate for why the guard exists at all: a prompt that
/// overflows the session's KV-cache crashes the process natively, with no
/// Dart or Kotlin catch possible, so refusing before the channel call is the
/// only place this can be caught.

library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/llm/llm_runtime.dart';

const _channel = MethodChannel('vault/llm');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late File modelFile;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('vault_llm_runtime_test');
    modelFile = File('${tmpDir.path}/gemma-cpu-int4.task');
    await modelFile.writeAsBytes(
      Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, ...List.filled(32, 0)]),
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    await tmpDir.delete(recursive: true);
  });

  Future<LlmRuntime> loadedRuntime({
    required int maxTokens,
    required Future<dynamic> Function(MethodCall call) onCall,
  }) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, onCall);
    final runtime = LlmRuntime();
    final ok = await runtime.load(modelFile.path, maxTokens: maxTokens);
    expect(ok, isTrue, reason: 'fixture load failed: ${runtime.error}');
    return runtime;
  }

  group('LlmRuntime prompt-length guard', () {
    test('a prompt that fits comfortably reaches the channel', () async {
      var generateCalls = 0;
      final runtime = await loadedRuntime(
        maxTokens: 1024,
        onCall: (call) async {
          if (call.method == 'load') return null;
          if (call.method == 'generate') {
            generateCalls++;
            return {'text': 'ok', 'tokens': 3};
          }
          return null;
        },
      );
      addTearDown(runtime.dispose);

      final result = await runtime.generate('short prompt');
      expect(result.text, 'ok');
      expect(generateCalls, 1);
    });

    test('a prompt that would overflow the loaded session\'s budget is '
        'refused before the channel is ever called', () async {
      var generateCalls = 0;
      final runtime = await loadedRuntime(
        maxTokens: 1024,
        onCall: (call) async {
          if (call.method == 'load') return null;
          if (call.method == 'generate') {
            generateCalls++;
            return {'text': 'should never happen', 'tokens': 1};
          }
          return null;
        },
      );
      addTearDown(runtime.dispose);

      // ~2200 tokens at the same 3.6-chars-per-token estimate the guard
      // uses — comfortably over a 1024-token session, matching the measured
      // worst case for the real capsule prompt.
      final oversizedPrompt = 'x' * 8000;

      await expectLater(
        runtime.generate(oversizedPrompt),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('too long'), contains('1024')),
        )),
      );
      // The whole point of the guard: the crash-prone native call is never
      // reached for a prompt this size.
      expect(generateCalls, 0);
    });

    test('the reserved response headroom means a prompt right at the limit '
        'is still refused, not just one that exceeds it outright', () async {
      var generateCalls = 0;
      final runtime = await loadedRuntime(
        maxTokens: 100,
        onCall: (call) async {
          if (call.method == 'load') return null;
          if (call.method == 'generate') {
            generateCalls++;
            return {'text': 'ok', 'tokens': 1};
          }
          return null;
        },
      );
      addTearDown(runtime.dispose);

      // ~100 tokens of prompt against a 100-token budget leaves no room for
      // even one output token once the reserve is subtracted.
      final borderlinePrompt = 'x' * 360;

      await expectLater(
        runtime.generate(borderlinePrompt),
        throwsA(isA<StateError>()),
      );
      expect(generateCalls, 0);
    });
  });
}
