/// model_page.dart
///
/// Loads the reasoning model and shows what it is doing.
///
/// The flow is deliberately three separate steps — pick, inspect, load —
/// rather than one button that does all three. Loading a 1.3 GB int4 model
/// takes tens of seconds and can abort the process if the file is the wrong
/// container, so the inspect step sits between: it reads sixteen bytes,
/// says what the file actually is, and only then offers to load it.
///
/// That ordering is worth the extra tap. The alternative — pick and load in
/// one action — means the common mistakes (a GGUF download, a truncated
/// file, a path under /data/local/tmp the app cannot read) all present as
/// the same thing: a long wait ending in a crash.

library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/llm/llm_runtime.dart';
import '../core/llm/model_probe.dart';
import '../core/llm/capsule_prompt.dart';
import 'theme.dart';
import 'widgets/common.dart';

class ModelPage extends StatefulWidget {
  final LlmRuntime llm;

  /// Persists the chosen path so it survives a relaunch.
  final Future<void> Function(String path) onRemember;
  final String? rememberedPath;

  const ModelPage({
    super.key,
    required this.llm,
    required this.onRemember,
    required this.rememberedPath,
  });

  @override
  State<ModelPage> createState() => _ModelPageState();
}

class _ModelPageState extends State<ModelPage> {
  final _pathController = TextEditingController();
  ModelProbeResult? _inspection;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    final remembered = widget.rememberedPath;
    if (remembered != null) _pathController.text = remembered;
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty || !mounted) return;
    final path = files.first.path;
    if (path == null) return;
    setState(() => _pathController.text = path);
    await _inspect();
  }

  Future<void> _inspect() async {
    final path = _pathController.text.trim();
    if (path.isEmpty) return;
    setState(() => _working = true);
    final result = await widget.llm.inspect(path);
    if (!mounted) return;
    setState(() {
      _inspection = result;
      _working = false;
    });
  }

  Future<void> _load() async {
    final path = _pathController.text.trim();
    if (path.isEmpty) return;
    setState(() => _working = true);

    final ok = await widget.llm.load(path);
    if (ok) await widget.onRemember(path);
    if (!mounted) return;
    setState(() => _working = false);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Loaded on ${widget.llm.backendLabel.toUpperCase()} in '
              '${widget.llm.loadMs} ms'
          : widget.llm.error ?? 'Load failed'),
      duration: const Duration(seconds: 6),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.llm,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(
          VaultSpace.lg,
          VaultSpace.md,
          VaultSpace.lg,
          VaultSpace.xxl,
        ),
        children: [
          _statusCard(),
          const SizedBox(height: VaultSpace.md),
          _pickerCard(),
          if (_inspection != null) ...[
            const SizedBox(height: VaultSpace.md),
            _inspectionCard(_inspection!),
          ],
          const SizedBox(height: VaultSpace.md),
          _roleCard(),
        ],
      ),
    );
  }

  Widget _statusCard() {
    final llm = widget.llm;
    final (label, color) = switch (llm.state) {
      LlmState.ready => ('LOADED', VaultColors.accent),
      LlmState.loading => ('LOADING', VaultColors.warn),
      LlmState.probing => ('INSPECTING', VaultColors.warn),
      LlmState.failed => ('FAILED', VaultColors.danger),
      LlmState.unloaded => ('NOT LOADED', VaultColors.faint),
    };

    return SectionCard(
      title: 'Reasoning model',
      subtitle: llm.isReady
          ? '${llm.modelLabel} on ${llm.backendLabel.toUpperCase()}'
          : 'Retrieval works without this. Generation does not.',
      trailing: StatusPill(
        label: label,
        color: color,
        pulsing: llm.isGenerating || llm.state == LlmState.loading,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (llm.isReady) ...[
            Row(
              children: [
                Expanded(
                  child: MetricTile(
                    label: 'BACKEND',
                    value: llm.backendLabel.toUpperCase(),
                    accent: VaultColors.accent,
                  ),
                ),
                const SizedBox(width: VaultSpace.sm),
                Expanded(
                  child: MetricTile(
                    label: 'LOAD',
                    value: '${llm.loadMs}',
                    unit: 'ms',
                  ),
                ),
                const SizedBox(width: VaultSpace.sm),
                Expanded(
                  child: MetricTile(
                    label: 'QUEUE',
                    value: '${llm.queueDepth}',
                    accent: llm.queueDepth > 0 ? VaultColors.warn : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: VaultSpace.md),
            OutlinedButton.icon(
              onPressed: _working ? null : widget.llm.unload,
              icon: const Icon(Icons.eject_rounded, size: 18),
              label: const Text('Unload'),
            ),
          ] else if (llm.state == LlmState.loading)
            const _LoadingBlock()
          else
            const Text(
              'No model loaded. Queries still work — they return a capsule '
              'built from retrieval alone, with the answer quoted verbatim '
              'from the corpus instead of written.',
              style: TextStyle(
                color: VaultColors.faint,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          if (llm.error != null) ...[
            const SizedBox(height: VaultSpace.md),
            Container(
              padding: const EdgeInsets.all(VaultSpace.md),
              decoration: BoxDecoration(
                color: VaultColors.danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
                border:
                    Border.all(color: VaultColors.danger.withValues(alpha: 0.3)),
              ),
              child: Text(
                llm.error!,
                style: const TextStyle(
                  color: VaultColors.muted,
                  fontSize: 11.5,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pickerCard() {
    return SectionCard(
      title: 'Model file',
      subtitle: 'Gemma 2B int4, MediaPipe container (.task or .bin).',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _pathController,
            enabled: !_working,
            autocorrect: false,
            style: VaultText.mono.copyWith(
              color: VaultColors.foreground,
              fontSize: 12,
            ),
            maxLines: 2,
            minLines: 1,
            decoration: const InputDecoration(
              labelText: 'Path',
              hintText: '/storage/emulated/0/Download/gemma2-2b-it-'
                  'cpu-int4.task',
            ),
          ),
          const SizedBox(height: VaultSpace.md),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _working ? null : _browse,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text('Browse'),
                ),
              ),
              const SizedBox(width: VaultSpace.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _working ? null : _inspect,
                  icon: const Icon(Icons.search_rounded, size: 18),
                  label: const Text('Inspect'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _inspectionCard(ModelProbeResult probe) {
    final usable = probe.isUsable;
    return SectionCard(
      title: 'What that file is',
      trailing: StatusPill(
        label: usable ? 'SUPPORTED' : 'CANNOT LOAD',
        color: usable ? VaultColors.accent : VaultColors.danger,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: MetricTile(
                  label: 'FORMAT',
                  value: probe.format.label.split(' ').first,
                  accent: usable ? VaultColors.accent : VaultColors.danger,
                  footnote: probe.format.label,
                ),
              ),
              const SizedBox(width: VaultSpace.sm),
              Expanded(
                child: MetricTile(
                  label: 'SIZE',
                  value: probe.sizeLabel,
                  unavailable: probe.sizeBytes == 0,
                ),
              ),
            ],
          ),
          if (probe.sizeWarning != null) ...[
            const SizedBox(height: VaultSpace.md),
            _note(probe.sizeWarning!, VaultColors.warn),
          ],
          if (probe.magicHex != null) ...[
            const SizedBox(height: VaultSpace.md),
            const Text(
              'FIRST BYTES',
              style: TextStyle(
                color: VaultColors.muted,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: VaultSpace.xs),
            CodeBlock(probe.magicHex!),
          ],
          if (probe.error != null) ...[
            const SizedBox(height: VaultSpace.md),
            _note(probe.error!, VaultColors.danger),
          ],
          if (probe.format.remedy != null) ...[
            const SizedBox(height: VaultSpace.md),
            _note(probe.format.remedy!, VaultColors.info),
          ],
          if (usable) ...[
            const SizedBox(height: VaultSpace.lg),
            FilledButton.icon(
              onPressed: _working ? null : _load,
              icon: const Icon(Icons.memory_rounded, size: 19),
              label: Text(_working ? 'Working…' : 'Load into memory'),
            ),
            const SizedBox(height: VaultSpace.sm),
            const Text(
              'Tries the GPU backend first and falls back to CPU. Expect '
              'tens of seconds and a large jump in memory use.',
              style: TextStyle(
                color: VaultColors.faint,
                fontSize: 11,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _note(String text, Color color) {
    return Container(
      padding: const EdgeInsets.all(VaultSpace.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: VaultColors.muted,
          fontSize: 11.5,
          height: 1.5,
        ),
      ),
    );
  }

  Widget _roleCard() {
    return SectionCard(
      title: 'How the two models divide the work',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _role(
            'MiniLM-L6-v2',
            'Encoding',
            'Turns every chunk and every query into a 384-dimension vector. '
                'Runs on every ingest and every search. Always loaded.',
            VaultColors.info,
          ),
          const SizedBox(height: VaultSpace.sm),
          _role(
            'Gemma 2B int4',
            'Reasoning',
            'Reads the chunks retrieval already found and writes them up as '
                'a JSON capsule. Runs once per query, only when loaded, and '
                'never sees anything retrieval did not hand it.',
            VaultColors.accent,
          ),
          const SizedBox(height: VaultSpace.md),
          Text(
            'Capsule schema $promptVersion. The generator prompt is fixed and '
            'versioned, so a stored capsule can be traced back to the '
            'instructions that produced it.',
            style: const TextStyle(
              color: VaultColors.faint,
              fontSize: 11,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _role(String name, String job, String detail, Color color) {
    return Container(
      padding: const EdgeInsets.all(VaultSpace.md),
      decoration: BoxDecoration(
        color: VaultColors.surfaceHigh,
        borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
        border: Border.all(color: VaultColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: VaultSpace.sm),
              Text(
                name,
                style: const TextStyle(
                  color: VaultColors.foreground,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                job.toUpperCase(),
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: VaultSpace.sm),
          Text(
            detail,
            style: const TextStyle(
              color: VaultColors.faint,
              fontSize: 11.5,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Load has no progress signal to report — MediaPipe's API is a single
/// blocking call with no callback — so this says what is happening and how
/// long it usually takes rather than showing a bar that cannot move.
class _LoadingBlock extends StatelessWidget {
  const _LoadingBlock();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          backgroundColor: VaultColors.surfaceHigh,
          color: VaultColors.accent,
        ),
        SizedBox(height: VaultSpace.md),
        Text(
          'Loading weights into memory. This takes tens of seconds for a '
          '1.3 GB model and there is no progress signal to report — '
          'MediaPipe exposes one blocking call, not a callback. The app '
          'stays responsive because the load runs on its own thread.',
          style: TextStyle(
            color: VaultColors.faint,
            fontSize: 11.5,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}
