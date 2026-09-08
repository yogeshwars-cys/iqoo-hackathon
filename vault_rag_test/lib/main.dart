/// main.dart
///
/// Single-screen test harness:
///   [Upload files]  ->  [Convert to Vector DB]  ->  [query field + Search]
///   -> results list -> [Copy results as JSON]
///
/// This is the whole "app" for the v0 test build. No navigation, no
/// theming beyond a seed color — the point is to prove the pipeline works,
/// not to look finished. See implementation.md for what's deliberately
/// left out (encryption at rest, on-device generation, Office Kit).

library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'chunking.dart';
import 'embedding_service.dart';
import 'vector_store.dart';

/// Extensions we are willing to read. Enforced here rather than in the
/// picker: Android's document picker filters by MIME type, and source-code
/// extensions like .dart or .kt have no registered MIME type, so a
/// `FileType.custom` filter greys out exactly the files this test needs.
/// Pick anything, then reject in Dart where we can be precise.
const _allowedExtensions = {
  'txt', 'md', 'dart', 'py', 'js', 'ts', 'json', 'yaml', 'yml',
  'java', 'kt', 'c', 'h', 'cpp', 'rs', 'go', 'sh', 'csv', 'html', 'css',
};

void main() => runApp(const VaultTestApp());

class VaultTestApp extends StatelessWidget {
  const VaultTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vault RAG test',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const VaultHomePage(),
    );
  }
}

class VaultHomePage extends StatefulWidget {
  const VaultHomePage({super.key});

  @override
  State<VaultHomePage> createState() => _VaultHomePageState();
}

class _VaultHomePageState extends State<VaultHomePage> {
  final MiniLMEmbeddingService _embeddingService = MiniLMEmbeddingService();
  final Chunker _chunker = Chunker();
  VectorStore? _store;

  bool _modelReady = false;
  bool _busy = false;
  String _status = 'Loading embedding model...';
  String _progress = '';

  List<PlatformFile> _pickedFiles = [];
  final Map<String, String> _ingestStatus = {};

  final TextEditingController _queryController = TextEditingController();
  List<RetrievedChunk> _results = [];
  String _searchInfo = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _queryController.dispose();
    _store?.close();
    _embeddingService.close();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final vocabText = await rootBundle.loadString('assets/models/vocab.txt');
      final sw = Stopwatch()..start();
      await _embeddingService.load(vocabText: vocabText);
      sw.stop();

      final dir = await getApplicationDocumentsDirectory();
      _store = VectorStore.open('${dir.path}/vault.db');

      if (!mounted) return;
      setState(() {
        _modelReady = true;
        _status = 'Model ready — ${_embeddingService.backend}, '
            '${_embeddingService.embeddingDim}-dim, '
            '${_embeddingService.sequenceLength} tokens, '
            '${sw.elapsedMilliseconds} ms to load. '
            'Vault has ${_store!.count} chunks.\n'
            'Backends: ${_embeddingService.backendReport}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Failed to load model: $e');
    }
  }

  Future<void> _pickFiles() async {
    // file_picker 12 dropped FilePickerResult: pickFiles is static and
    // returns the list directly, empty when the user cancels.
    final files = await FilePicker.pickFiles();
    if (files.isEmpty || !mounted) return;
    setState(() {
      _pickedFiles = files;
      _ingestStatus.clear();
    });
  }

  Future<void> _convertToVectorDb() async {
    final store = _store;
    if (store == null || _pickedFiles.isEmpty) return;

    setState(() {
      _busy = true;
      _status = 'Converting...';
      _progress = '';
    });

    final sw = Stopwatch()..start();
    var totalChunks = 0;
    var fileNo = 0;

    for (final file in _pickedFiles) {
      fileNo++;
      final path = file.path;
      final ext = (file.extension ?? '').toLowerCase();

      if (path == null) {
        setState(() => _ingestStatus[file.name] = 'Skipped — unreadable');
        continue;
      }
      if (!_allowedExtensions.contains(ext)) {
        setState(() => _ingestStatus[file.name] = 'Skipped — .$ext not allowed');
        continue;
      }

      try {
        final content = await File(path).readAsString();
        final chunks = _chunker.chunk(file.name, content);
        for (var i = 0; i < chunks.length; i++) {
          final embedding = await _embeddingService.embed(chunks[i].content);
          store.insert(chunks[i], embedding);
          totalChunks++;
          // Inference is synchronous; yield so the progress line actually
          // repaints instead of the app looking frozen for a whole file.
          setState(() => _progress =
              'File $fileNo/${_pickedFiles.length}: ${file.name} — '
              'chunk ${i + 1}/${chunks.length}');
          await Future<void>.delayed(Duration.zero);
        }
        setState(() {
          _ingestStatus[file.name] = 'Ingested (${chunks.length} chunks)';
        });
      } catch (e) {
        setState(() {
          _ingestStatus[file.name] = 'Skipped — unsupported or unreadable';
        });
      }
    }

    sw.stop();
    final perChunk = totalChunks == 0
        ? '—'
        : '${(sw.elapsedMilliseconds / totalChunks).toStringAsFixed(0)} ms/chunk';
    if (!mounted) return;
    setState(() {
      _busy = false;
      _progress = '';
      _status = 'Vault has ${store.count} chunks total. '
          'Embedded $totalChunks in ${sw.elapsedMilliseconds} ms ($perChunk, '
          '${_embeddingService.backend}).';
    });
  }

  Future<void> _clearVault() async {
    final store = _store;
    if (store == null) return;
    store.clear();
    if (!mounted) return;
    setState(() {
      _results = [];
      _searchInfo = '';
      _ingestStatus.clear();
      _status = 'Vault cleared. 0 chunks.';
    });
  }

  Future<void> _search() async {
    final store = _store;
    if (store == null || _queryController.text.trim().isEmpty) return;

    setState(() => _busy = true);
    try {
      final sw = Stopwatch()..start();
      final queryEmbedding =
          await _embeddingService.embed(_queryController.text);
      final results = store.topK(queryEmbedding, k: 5);
      sw.stop();
      if (!mounted) return;
      final modelMs = _embeddingService.lastInferenceMicros / 1000;
      setState(() {
        _results = results;
        _searchInfo = results.isEmpty
            ? 'No chunks in the vault yet.'
            : 'Searched ${store.count} chunks in ${sw.elapsedMilliseconds} ms '
                '(model ${modelMs.toStringAsFixed(0)} ms).';
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _searchInfo = 'Search failed: $e';
      });
    }
  }

  Future<void> _copyResultsAsJson() async {
    final payload = {
      'query': _queryController.text,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'top_k': _results.map((r) => r.toJson()).toList(),
    };
    final jsonStr = const JsonEncoder.withIndent('  ').convert(payload);

    await Clipboard.setData(ClipboardData(text: jsonStr));

    // Fallback bridge for when clipboard doesn't sync to the laptop:
    //   adb pull /storage/emulated/0/Android/data/<package>/files/query_result.json
    String? savedTo;
    try {
      final dir = await getExternalStorageDirectory();
      if (dir != null) {
        final f = File('${dir.path}/query_result.json');
        await f.writeAsString(jsonStr);
        savedTo = f.path;
      }
    } catch (_) {
      // Non-fatal — clipboard copy above already succeeded.
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(savedTo == null
            ? 'Copied to clipboard (file write unavailable)'
            : 'Copied to clipboard, also saved to $savedTo'),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canIngest = _modelReady && !_busy && _pickedFiles.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Vault RAG test')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status, style: Theme.of(context).textTheme.bodyMedium),
            if (_progress.isNotEmpty) ...[
              const SizedBox(height: 6),
              const LinearProgressIndicator(),
              const SizedBox(height: 4),
              Text(_progress, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _modelReady && !_busy ? _pickFiles : null,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Upload files'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Clear vault',
                  onPressed: _modelReady && !_busy ? _clearVault : null,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: canIngest ? _convertToVectorDb : null,
              icon: const Icon(Icons.storage),
              label: const Text('Convert to Vector DB'),
            ),
            if (_pickedFiles.isNotEmpty) ...[
              const SizedBox(height: 8),
              ..._pickedFiles.map(
                (f) => Text(
                  '${f.name}: ${_ingestStatus[f.name] ?? 'Pending'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
            const Divider(height: 32),
            TextField(
              controller: _queryController,
              onSubmitted: (_) => _modelReady && !_busy ? _search() : null,
              decoration: const InputDecoration(
                labelText: 'Test query',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _modelReady && !_busy ? _search : null,
              icon: const Icon(Icons.search),
              label: const Text('Search'),
            ),
            if (_searchInfo.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_searchInfo, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _results.length,
                itemBuilder: (context, i) {
                  final r = _results[i];
                  final preview = r.content.length > 200
                      ? '${r.content.substring(0, 200)}...'
                      : r.content;
                  return Card(
                    child: ListTile(
                      title:
                          Text('${r.fileName}  (${r.score.toStringAsFixed(3)})'),
                      subtitle: Text(preview),
                    ),
                  );
                },
              ),
            ),
            if (_results.isNotEmpty)
              ElevatedButton.icon(
                onPressed: _copyResultsAsJson,
                icon: const Icon(Icons.copy),
                label: const Text('Copy results as JSON'),
              ),
          ],
        ),
      ),
    );
  }
}
