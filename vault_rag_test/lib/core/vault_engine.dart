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
import 'dart:convert';

// Float32List comes in via foundation, which re-exports dart:typed_data.
import 'package:flutter/foundation.dart';

import 'answer_synthesizer.dart';
import 'chunking.dart';
import 'embedding_service.dart';
import 'gating.dart';
import 'llm/capsule.dart';
import 'llm/capsule_prompt.dart';
import 'llm/reasoner_coordinator.dart';
import 'security/capsule_signer.dart';
import 'security/security_constants.dart';
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

  /// Of which, the pure in-RAM vector ranking (no SQLite, no decryption).
  final int rankMicros;

  /// Of which, keystore decryption of the top-K winners only.
  final int decryptMicros;

  /// The encoder's verified accelerator label ("QNN HTP verified",
  /// "QNN unavailable", "XNNPACK fallback", or the plain backend name) and
  /// the hardware that implies. Carried into capsules so a label is always
  /// the runtime's result, never a guess from device branding.
  final String embeddingBackend;
  final String embeddingHardware;

  const SearchResult({
    required this.query,
    required this.chunks,
    required this.directAnswer,
    required this.latencyMs,
    required this.embedMs,
    required this.totalIndexed,
    this.rankMicros = 0,
    this.decryptMicros = 0,
    this.embeddingBackend = 'unknown',
    this.embeddingHardware = 'unknown',
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
        'rank_us': rankMicros,
        'embedding_backend': embeddingBackend,
        'embedding_hardware': embeddingHardware,
        'decrypt_us': decryptMicros,
        'total_indexed': totalIndexed,
      };
}

/// Output of one generation, whichever runtime produced it.
class SynthesisOutput {
  final String text;
  final int elapsedMs;
  final int? tokens;

  /// Prompt processing and decode split, when the runtime reports them
  /// (llama.cpp does, from ggml_time_us; MediaPipe does not).
  final int? prefillMs;
  final int? decodeMs;

  const SynthesisOutput({
    required this.text,
    required this.elapsedMs,
    this.tokens,
    this.prefillMs,
    this.decodeMs,
  });
}

/// The tier-2 language model, behind one interface so [VaultEngine.ask]'s
/// gate can be tested without a model and so "was the LLM invoked" is a
/// question with a checkable answer.
abstract interface class CapsuleSynthesizer {
  bool get isReady;
  String get modelLabel;
  String get backendLabel;
  Future<SynthesisOutput> synthesize(SearchResult result);
}

/// Lifecycle of the engine, so the UI can render each state honestly rather
/// than showing a disabled button with no explanation.
enum EngineState { loading, ready, failed }

class VaultEngine extends ChangeNotifier {
  final MiniLMEmbeddingService embeddings;
  final Chunker chunker;

  /// The single selected reasoner (see reasoner_coordinator.dart). Optional:
  /// the engine works fully without one — [ask] degrades to the extractive
  /// capsule — so nothing here may assume a model is loaded.
  ///
  /// This replaced two independent `llm` / `llama` fields and an implicit
  /// "llama.cpp wins when both are ready" rule. Routing now follows the
  /// persisted selection and nothing else.
  ReasonerCoordinator? reasoner;

  /// Forces a specific tier-2 model (tests). When null, [llama] then [llm].
  @visibleForTesting
  CapsuleSynthesizer? synthesizerOverride;

  /// Score gates for [ask]. See gating.dart before changing the defaults.
  GatingPolicy gatingPolicy;

  /// Signs every capsule [ask] returns.
  CapsuleSigner signer;

  /// Where the encrypted store lives; injectable for tests.
  final ChunkCipher chunkCipher;

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
    this.gatingPolicy = GatingPolicy.standard,
    CapsuleSigner? signer,
    this.chunkCipher = const KeystoreChunkCipher(),
  })  : embeddings = embeddings ?? MiniLMEmbeddingService(),
        chunker = chunker ?? Chunker(),
        signer = signer ?? CapsuleSigner();

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

      if (embeddings.embeddingDim != kEmbeddingDim) {
        throw StateError('Encoder produces ${embeddings.embeddingDim}-dim '
            'vectors; the vault index is laid out for $kEmbeddingDim.');
      }
      // Opens, migrates legacy plaintext rows to AES-GCM if needed, and
      // loads the embedding matrix into RAM. Fails closed if the keystore
      // cannot encrypt a legacy vault.
      _store = await VectorStore.open(
        databasePath,
        cipher: chunkCipher,
        dimension: kEmbeddingDim,
      );

      _state = EngineState.ready;
      _statusLine = '${embeddings.backend} · ${embeddings.embeddingDim}-dim · '
          '${embeddings.sequenceLength} tokens · $_modelLoadMs ms to load';
      final skipped = _store!.skippedRows;
      if (skipped > 0) {
        _statusLine += ' · $skipped malformed rows skipped';
      }
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
        // Encrypted before it reaches SQLite; indexed only after it lands.
        await store.insert(chunks[i], vector);
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
      // Ranked in RAM, then only the winners are fetched and decrypted.
      final chunks = await store.topK(vector, k: topK);
      final answer = synthesizeDirectAnswer(query, chunks);
      sw.stop();

      return SearchResult(
        query: query,
        chunks: chunks,
        directAnswer: answer,
        latencyMs: sw.elapsedMilliseconds,
        embedMs: (embedMicros / 1000).round(),
        totalIndexed: store.count,
        rankMicros: store.lastRankMicros,
        decryptMicros: store.lastDecryptMicros,
        embeddingBackend: embeddings.acceleratorStatus.label,
        embeddingHardware: embeddings.acceleratorStatus.hardware.name,
      );
    });
  }

  /// Retrieval, a three-tier gate, and a signed context capsule.
  ///
  /// NOT wrapped in [_serialized], and that is load-bearing rather than an
  /// oversight: it calls [search], which takes the lock itself. Nesting the
  /// two would deadlock the engine on the first query. Generation has its own
  /// queue inside whichever runtime answers.
  ///
  /// THE GATE (gating.dart), decided on the best retrieval score alone:
  ///
  ///   >= 0.82       extractive_early_exit      the LLM is never touched
  ///   0.50 – 0.82   llm_synthesized            llama.cpp if ready, else
  ///                                            MediaPipe; extractive_fallback
  ///                                            if neither can run
  ///   < 0.50        below_relevance_threshold  fixed refusal, no LLM
  ///
  /// Tier 1 and 3 never read [llama] or [llm] beyond this method's gate, so
  /// a deterministic hit costs embed + rank + top-K decrypt and nothing
  /// else. Whatever the tier, the capsule is signed before it is returned.
  Future<ContextCapsule> ask(
    String query, {
    int topK = 5,
    bool generate = true,
  }) async {
    final result = await search(query, topK: topK);
    final capsule = await buildCapsule(result, generate: generate);
    return signer.sign(capsule);
  }

  /// The gate itself, over an existing [SearchResult]. Split from [ask] so
  /// it is testable without an encoder or a database.
  @visibleForTesting
  Future<ContextCapsule> buildCapsule(
    SearchResult result, {
    bool generate = true,
  }) async {
    double? top;
    for (final c in result.chunks) {
      if (top == null || c.score > top) top = c.score;
    }
    final path = gatingPolicy.decide(top);
    final gating = <String, dynamic>{
      'top_score': top == null ? null : double.parse(top.toStringAsFixed(4)),
      ...gatingPolicy.toJson(),
    };

    switch (path) {
      case GatingPath.extractiveEarlyExit:
        return ContextCapsule.fromRetrievalOnly(result,
            gatingPath: GatingPath.extractiveEarlyExit, gating: gating);
      case GatingPath.belowRelevanceThreshold:
        return ContextCapsule.belowRelevanceThreshold(result, gating: gating);
      case GatingPath.llmSynthesized:
      case GatingPath.extractiveFallback:
        break;
    }

    final synthesizer = generate ? _activeSynthesizer() : null;
    if (synthesizer == null) {
      return ContextCapsule.fromRetrievalOnly(result,
          gatingPath: GatingPath.extractiveFallback, gating: gating);
    }

    final model = synthesizer.modelLabel;
    final backend = synthesizer.backendLabel;
    try {
      final generated = await synthesizer.synthesize(result);
      return ContextCapsule.fromModelOutput(
        generated.text,
        result,
        model: model,
        backend: backend,
        elapsedMs: generated.elapsedMs,
        tokens: generated.tokens,
        gating: gating,
      );
    } catch (e) {
      // A generation failure must never lose the retrieval. The capsule
      // degrades to the extractive answer and records why.
      return ContextCapsule.fromRetrievalOnly(
        result,
        gatingPath: GatingPath.extractiveFallback,
        gating: gating,
        generation: CapsuleGeneration(
          ran: true,
          model: model,
          backend: backend,
          parseError: 'Generation failed: ${e.runtimeType}',
        ),
      );
    }
  }

  /// [synthesizerOverride], else llama.cpp when ready, else MediaPipe when
  /// ready — never both. See llama_runtime.dart for why both exist.
  CapsuleSynthesizer? _activeSynthesizer() {
    final forced = synthesizerOverride;
    if (forced != null) return forced.isReady ? forced : null;
    return reasoner?.activeSynthesizer;
  }

  /// Microseconds for one in-RAM ranking of [query] against the live store —
  /// CPU vector search only: no encoder, no SQLite, no decryption.
  Future<int> benchmarkRankMicros(Float32List query, {int k = 5}) =>
      _serialized(() async {
        final store = _requireStore();
        store.rank(query, k: k);
        return store.lastRankMicros;
      });

  /// The per-chunk cost of indexing — embed, then AES-GCM encrypt through
  /// the keystore — WITHOUT writing to the vault, so a sustained-load
  /// benchmark leaves the user's corpus untouched. Returns native inference
  /// microseconds for the embedding.
  Future<int> indexingWorkload(String chunkText) => _serialized(() async {
        await embeddings.embed(chunkText);
        final micros = embeddings.lastInferenceMicros;
        await chunkCipher.encrypt(Uint8List.fromList(utf8.encode(chunkText)));
        return micros;
      });

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
        'embedding_status': embeddings.acceleratorStatus.toJson(),
        'reasoner': reasoner?.describe() ?? {'active_reasoner': null},
        // Compatibility view for bridge_server.py / query.py / the MCP
        // server, which read `llm.state/model/backend`: now describes THE
        // selected reasoner, whichever runtime it is. Always present.
        'llm': _reasonerCompat(),
        'capsule_prompt_version': promptVersion,
      };

  Map<String, dynamic> _reasonerCompat() {
    final slot = reasoner?.activeSlot;
    if (slot == null) return {'state': 'unloaded', 'runtime': null};
    return {
      'state': slot.isReady ? 'ready' : 'unloaded',
      'runtime': slot.kind.settingsName,
      if (slot.isReady) 'model': slot.modelLabel,
      if (slot.isReady) 'backend': slot.backendLabel,
    };
  }

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
