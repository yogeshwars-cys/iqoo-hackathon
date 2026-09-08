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

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'chunking.dart';
import 'embedding_service.dart';
import 'vector_store.dart';

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
  final EmbeddingService _embeddingService = MiniLMEmbeddingService();
  final Chunker _chunker = Chunker();
  VectorStore? _store;

  bool _modelReady = false;
  bool _busy = false;
  String _status = 'Loading embedding model...';

  List<PlatformFile> _pickedFiles = [];
  final Map<String, String> _ingestStatus = {};

  final TextEditingController _queryController = TextEditingController();
  List<RetrievedChunk> _results = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final vocabText = await rootBundle.loadString('assets/models/vocab.txt');
      await _embeddingService.load(vocabText: vocabText);

      final dir = await getApplicationDocumentsDirectory();
      _store = VectorStore.open('${dir.path}/vault.db');

      setState(() {
        _modelReady = true;
        _status = 'Model ready. Vault has ${_store!.count} chunks.';
      });
    } catch (e) {
      setState(() => _status = 'Failed to load model/vocab assets: $e');
    }
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: [
        'txt', 'md', 'dart', 'py', 'js', 'json', 'yaml', 'yml', 'java', 'kt',
      ],
    );
    if (result == null) return;
    setState(() {
      _pickedFiles = result.files;
      _ingestStatus.clear();
    });
  }

  Future<void> _convertToVectorDb() async {
    final store = _store;
    if (store == null || _pickedFiles.isEmpty) return;

    setState(() {
      _busy = true;
      _status = 'Converting...';
    });

    for (final file in _pickedFiles) {
      final path = file.path;
      if (path == null) {
        setState(() => _ingestStatus[file.name] = 'Skipped — unreadable');
        continue;
      }
      try {
        final content = await File(path).readAsString();
        final chunks = _chunker.chunk(file.name, content);
        for (final chunk in chunks) {
          final embedding = await _embeddingService.embed(chunk.content);
          store.insert(chunk, embedding);
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

    setState(() {
      _busy = false;
      _status = 'Vault has ${store.count} chunks total.';
    });
  }

  Future<void> _search() async {
    final store = _store;
    if (store == null || _queryController.text.trim().isEmpty) return;

    setState(() => _busy = true);
    final queryEmbedding = await _embeddingService.embed(_queryController.text);
    final results = store.topK(queryEmbedding, k: 5);
    setState(() {
      _results = results;
      _busy = false;
    });
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
    try {
      final dir = await getExternalStorageDirectory();
      if (dir != null) {
        await File('${dir.path}/query_result.json').writeAsString(jsonStr);
      }
    } catch (_) {
      // Non-fatal — clipboard copy above already succeeded.
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Copied to clipboard, also saved to query_result.json'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vault RAG test')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            Center(
              child: ElevatedButton.icon(
                onPressed: _modelReady && !_busy ? _pickFiles : null,
                icon: const Icon(Icons.upload_file),
                label: const Text('Upload files'),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _modelReady && !_busy && _pickedFiles.isNotEmpty
                  ? _convertToVectorDb
                  : null,
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
                      title: Text('${r.fileName}  (${r.score.toStringAsFixed(3)})'),
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
