/// vault_engine.dart
///
/// The retrieval engine, extracted from the widget layer.
///
/// WHY THIS FILE EXISTS AT ALL: in the previous build every step of the
/// pipeline lived inside `_VaultHomePageState` — picking files, chunking,
/// embedding and searching were all methods on a widget. That was fine
/// while a human tapping buttons was the only caller. It stops being fine
/// the moment a second caller appears, and the co-processor bridge is
/// exactly that: a socket that has to ingest and query with no widget
/// mounted, possibly while the user is on a different tab.
///
/// So the pipeline moved here and the widgets became one of its two
/// clients. The bridge is the other. Neither owns it.
///
/// CONCURRENCY, WHICH IS THE REAL REASON THIS IS NOT JUST A MIXIN:
/// a TFLite [Interpreter] is not reentrant. Two overlapping `embed` calls
/// against one interpreter is undefined behaviour in native code — which on
/// a good day is a wrong vector and on a bad one is a SIGSEGV that Dart
/// cannot catch. With a bridge indexing a pushed document while the user
/// hits Search locally, overlap is not hypothetical. Every call that
/// touches the interpreter therefore goes through [_serialized], a simple
/// promise chain that guarantees one at a time, in arrival order.

library;

import 'dart:async';

// Float32List comes in via foundation, which re-exports dart:typed_data.
import 'package:flutter/foundation.dart';

import 'answer_synthesizer.dart';
import 'chunking.dart';
import 'embedding_service.dart';
import 'llm/capsule.dart';
import 'llm/capsule_prompt.dart';
import 'llm/llama_runtime.dart';
import 'llm/llm_runtime.dart';
import 'vector_store.dart';

/// Extensions the vault will read. Enforced here rather than at the picker:
/// Android's document picker filters by MIME type, and source extensions
/// like .dart or .kt have no registered MIME type, so a `FileType.custom`
/// filter greys out exactly the files this app exists to index. Pick
/// anything, reject in Dart where we can be precise.
const allowedExtensions = {
  'txt', 'md', 'dart', 'py', 'js', 'ts', 'json', 'yaml', 'yml',
  'java', 'kt', 'c', 'h', 'cpp', 'rs', 'go', 'sh', 'csv', 'html', 'css',
  'toml', 'ini', 'cfg', 'conf', 'env', 'sql', 'xml', 'gradle', 'kts',
};

class IndexResult {
  final String fileName;
  final int chunksAdded;
  final int totalIndexed;
  final int elapsedMs;

  /// Milliseconds spent inside the interpreter, as opposed to wall clock.
  final int inferenceMs;

  const IndexResult({
    required this.fileName,
    required this.chunksAdded,
    required this.totalIndexed,
    required this.elapsedMs,
    required this.inferenceMs,
  });

  double get msPerChunk => chunksAdded == 0 ? 0 : elapsedMs / chunksAdded;

  Map<String, dynamic> toJson() => {
        'file': fileName,
        'chunks_added': chunksAdded,
        'total_indexed': totalIndexed,
        'elapsed_ms': elapsedMs,
        'inference_ms': inferenceMs,
        'ms_per_chunk': double.parse(msPerChunk.toStringAsFixed(2)),
      };
}

class SearchResult {
  final String query;
  final List<RetrievedChunk> chunks;
  final DirectAnswer? directAnswer;

  /// Wall clock for the whole query: embed + scan + rank.
  final int latencyMs;

  /// Of which, inside the interpreter.
  final int embedMs;
  final int totalIndexed;

  const SearchResult({
    required this.query,
    required this.chunks,
    required this.directAnswer,
    required this.latencyMs,
    required this.embedMs,
    required this.totalIndexed,
  });

  /// The wire shape the desktop bridge, the MCP tools and query.py expect.
  ///
  /// `direct_answer` is a plain string because query.py prints it straight
  /// into a highlighted box; the provenance goes in a sibling key so older
  /// clients keep working.
  Map<String, dynamic> toBridgeJson() => {
        'query': query,
        'results': chunks
            .map((c) => {
                  'file': c.fileName,
                  'similarity': double.parse(c.score.toStringAsFixed(4)),
                  'content': c.content,
                  'id': c.id,
                })
            .toList(),
        'direct_answer': directAnswer?.text,
        'direct_answer_meta': directAnswer?.toJson(),
        'latency_ms': latencyMs,
        'embed_ms': embedMs,
        'total_indexed': totalIndexed,
      };
}

/// Lifecycle of the engine, so the UI can render each state honestly rather
/// than showing a disabled button with no explanation.
enum EngineState { loading, ready, failed }

class VaultEngine extends ChangeNotifier {
  final MiniLMEmbeddingService embeddings;
  final Chunker chunker;

  /// Optional generation stage. The engine works fully without it — [ask]
  /// falls back to a retrieval-only capsule — so nothing here may assume a
  /// model is loaded.
  LlmRuntime? llm;

  /// The llama.cpp/GGUF path, independent of [llm] — see
  /// llama_runtime.dart's file header for why both exist side by side.
  /// [ask] prefers this one when it is ready, since loading a GGUF model is
  /// the more deliberate, specific action of the two.
  LlamaRuntime? llama;

  VectorStore? _store;
  EngineState _state = EngineState.loading;
  String _statusLine = 'Loading embedding model…';
  Object? _error;

  int _modelLoadMs = 0;

  /// Tail of the promise chain that serialises interpreter access.
  Future<void> _lock = Future<void>.value();

  /// Set by [dispose]. Read by [_serialized] and [_notify]; see both.
  bool _disposed = false;

  VaultEngine({
    MiniLMEmbeddingService? embeddings,
    Chunker? chunker,
  })  : embeddings = embeddings ?? MiniLMEmbeddingService(),
        chunker = chunker ?? Chunker();

  EngineState get state => _state;
  String get statusLine => _statusLine;
  Object? get error => _error;
  bool get isReady => _state == EngineState.ready;
  int get modelLoadMs => _modelLoadMs;
  int get chunkCount => _store?.count ?? 0;

  String get backend => embeddings.backend;
  String get backendReport => embeddings.backendReport;
  int get embeddingDim => embeddings.embeddingDim;
  int get sequenceLength => embeddings.sequenceLength;

  /// Runs [action] with exclusive access to the interpreter.
  ///
  /// Chaining onto `_lock` rather than using a boolean flag means callers
  /// queue instead of failing, which is what a socket peer needs — the
  /// bridge cannot retry a rejected index the way a user can re-tap a
  /// button.
  ///
  /// The [_disposed] check is inside the chained callback as well as at the
  /// entry point, and both are load-bearing. Entry catches calls made after
  /// disposal; the inner one catches the worse case — a task that was queued
  /// while the engine was alive and reaches the front of the queue after
  /// [dispose] has run. Without it that task calls `embed()` on a closed
  /// interpreter, which is a use-after-free in native memory rather than a
  /// Dart exception.
  Future<T> _serialized<T>(Future<T> Function() action) {
    if (_disposed) {
      return Future.error(StateError('Vault engine has been disposed.'));
    }
    final completer = Completer<T>();
    _lock = _lock.then((_) async {
      if (_disposed) {
        completer.completeError(
          StateError('Vault engine was disposed while this call was queued.'),
        );
        return;
      }
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// [notifyListeners] that tolerates being called after disposal.
  ///
  /// Work runs asynchronously and can finish after the widget tree that
  /// started it is gone — a bridge request in flight when the app is
  /// backgrounded, most obviously. ChangeNotifier throws if notified after
  /// dispose, so every notification from inside the queue goes through here.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  Future<void> initialize({
    required String vocabText,
    required String databasePath,
  }) async {
    try {
      final sw = Stopwatch()..start();
      await embeddings.load(vocabText: vocabText);
      sw.stop();
      _modelLoadMs = sw.elapsedMilliseconds;

      _store = VectorStore.open(databasePath);

      _state = EngineState.ready;
      _statusLine = '${embeddings.backend} · ${embeddings.embeddingDim}-dim · '
          '${embeddings.sequenceLength} tokens · $_modelLoadMs ms to load';
    } catch (e) {
      _state = EngineState.failed;
      _error = e;
      _statusLine = 'Model failed to load: $e';
    }
    _notify();
  }

  /// Chunks [content], embeds every chunk, and writes them to the vault.
  ///
  /// [onProgress] fires per chunk so a long file can show real progress
  /// instead of a frozen screen.
  Future<IndexResult> indexDocument(
    String fileName,
    String content, {
    void Function(int done, int total)? onProgress,
  }) {
    return _serialized(() async {
      final store = _requireStore();
      final chunks = chunker.chunk(fileName, content);
      final sw = Stopwatch()..start();
      var inferenceMicros = 0;

      for (var i = 0; i < chunks.length; i++) {
        final vector = await embeddings.embed(chunks[i].content);
        inferenceMicros += embeddings.lastInferenceMicros;
        store.insert(chunks[i], vector);
        onProgress?.call(i + 1, chunks.length);
        // Yield to the event loop. Inference is synchronous native work, so
        // without this a multi-chunk file starves the raster thread and the
        // progress line never repaints — the app just looks hung.
        await Future<void>.delayed(Duration.zero);
      }

      sw.stop();
      _notify();
      return IndexResult(
        fileName: fileName,
        chunksAdded: chunks.length,
        totalIndexed: store.count,
        elapsedMs: sw.elapsedMilliseconds,
        inferenceMs: (inferenceMicros / 1000).round(),
      );
    });
  }

  Future<SearchResult> search(String query, {int topK = 5}) {
    return _serialized(() async {
      final store = _requireStore();
      final sw = Stopwatch()..start();
      final vector = await embeddings.embed(query);
      final embedMicros = embeddings.lastInferenceMicros;
      final chunks = store.topK(vector, k: topK);
      final answer = synthesizeDirectAnswer(query, chunks);
      sw.stop();

      return SearchResult(
        query: query,
        chunks: chunks,
        directAnswer: answer,
        latencyMs: sw.elapsedMilliseconds,
        embedMs: (embedMicros / 1000).round(),
        totalIndexed: store.count,
      );
    });
  }

  /// Retrieval plus, when a model is loaded, a generated context capsule.
  ///
  /// NOT wrapped in [_serialized], and that is load-bearing rather than an
  /// oversight: it calls [search], which takes the lock itself. Nesting the
  /// two would deadlock the engine on the first query — the inner call
  /// would queue behind the outer one, which is waiting for it.
  ///
  /// Generation has its own queue inside whichever runtime answers. The two
  /// stages are serialised independently, so an embedding can start while a
  /// previous query is still being written up.
  ///
  /// TWO ENGINES, ONE CALL SITE
  ///
  /// [llama] wins when it is ready, [llm] (MediaPipe/Gemma) otherwise —
  /// never both. The two use different prompt shapes on purpose:
  /// [buildCapsulePrompt] hand-wraps Gemma's own turn markers because
  /// MediaPipe's `generateResponse` has no chat-template support of its own,
  /// while [buildCapsuleContent] is deliberately unwrapped because
  /// llama.cpp applies whichever template the loaded GGUF model actually
  /// declares. Handing [buildCapsulePrompt]'s Gemma-wrapped text to the
  /// llama.cpp path would not skip templating, it would template *around*
  /// literal Gemma syntax — see capsule_prompt.dart for why that produces a
  /// capsule the parser cannot recover.
  Future<ContextCapsule> ask(
    String query, {
    int topK = 5,
    bool generate = true,
  }) async {
    final result = await search(query, topK: topK);

    final activeLlama = llama;
    final useLlama = generate && activeLlama != null && activeLlama.isReady;
    final activeLlm = llm;
    final useLlm =
        generate && !useLlama && activeLlm != null && activeLlm.isReady;

    if (!useLlama && !useLlm) {
      return ContextCapsule.fromRetrievalOnly(result);
    }

    // Nothing retrieved means nothing to summarise. Running the model here
    // would burn seconds to have it correctly say it does not know, which
    // the deterministic capsule already says for free.
    if (result.chunks.isEmpty) {
      return ContextCapsule.fromRetrievalOnly(result);
    }

    final model = useLlama ? activeLlama.modelLabel : activeLlm!.modelLabel;
    final backend = useLlama
        ? 'llama.cpp/${activeLlama.backend?.label ?? "?"}'
        : activeLlm!.backendLabel;

    try {
      final String text;
      final int elapsedMs;
      final int? tokens;
      if (useLlama) {
        final generated = await activeLlama.generate(buildCapsuleContent(result));
        text = generated.text;
        elapsedMs = generated.prefillMs + generated.decodeMs;
        tokens = generated.tokens;
      } else {
        final generated = await activeLlm!.generate(buildCapsulePrompt(result));
        text = generated.text;
        elapsedMs = generated.elapsedMs;
        tokens = generated.tokens;
      }

      return ContextCapsule.fromModelOutput(
        text,
        result,
        model: model,
        backend: backend,
        elapsedMs: elapsedMs,
        tokens: tokens,
      );
    } catch (e) {
      // A generation failure must never lose the retrieval. The capsule
      // degrades to the extractive answer and records why.
      return ContextCapsule.fromRetrievalOnly(
        result,
        generation: CapsuleGeneration(
          ran: true,
          model: model,
          backend: backend,
          parseError: 'Generation failed: $e',
        ),
      );
    }
  }

  /// One embedding, for the benchmark harness. Goes through the same lock
  /// as everything else so a benchmark cannot race a bridge query.
  Future<Float32List> embedOnce(String text) =>
      _serialized(() => embeddings.embed(text));

  Future<void> clear() => _serialized(() async {
        _requireStore().clear();
        _notify();
      });

  VectorStore _requireStore() {
    final store = _store;
    if (store == null) {
      throw StateError('Vault engine is not initialised (state: ${_state.name}).');
    }
    return store;
  }

  /// Device/engine facts for the bridge telemetry frame.
  Map<String, dynamic> describe() => {
        'engine': 'vault-minilm-l6-v2',
        'state': _state.name,
        'backend': embeddings.backend,
        'backend_report': embeddings.backendReport,
        'embedding_dim': embeddings.embeddingDim,
        'sequence_length': embeddings.sequenceLength,
        'model_load_ms': _modelLoadMs,
        'total_indexed': chunkCount,
        'llm': llm?.describe() ?? {'state': 'unloaded'},
        'llama': llama?.describe() ?? {'state': 'unloaded'},
        'capsule_prompt_version': promptVersion,
      };

  /// Releases the interpreter and the database — but only once the queue has
  /// drained.
  ///
  /// Closing them synchronously here is a use-after-free. `dispose()` runs
  /// when the widget tree goes away, which can happen with a bridge request
  /// mid-flight or an ingest still queued; those tasks then call into a
  /// freed TFLite interpreter and a closed SQLite handle. That is a native
  /// SIGSEGV, not a catchable Dart error — the exact failure class the rest
  /// of this file exists to avoid.
  ///
  /// So [_disposed] goes up first, which makes every queued task bail out at
  /// the front of the queue without touching native memory, and the actual
  /// close is chained onto the tail of the lock. ChangeNotifier's own
  /// `dispose` is called immediately because callers may not notify after
  /// it; [_notify] is what keeps that safe.
  @override
  void dispose() {
    _disposed = true;
    final drained = _lock;
    super.dispose();

    unawaited(drained.whenComplete(() {
      _store?.close();
      _store = null;
      embeddings.close();
    }));
  }
}
