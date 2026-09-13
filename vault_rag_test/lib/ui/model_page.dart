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

import '../core/llm/llama_runtime.dart';
import '../core/llm/llm_runtime.dart';
import '../core/llm/model_probe.dart';
import '../core/llm/capsule_prompt.dart';
import '../core/embedding_service.dart';
import '../core/llm/reasoner_coordinator.dart';
import 'theme.dart';
import 'widgets/common.dart';

class ModelPage extends StatefulWidget {
  final LlmRuntime llm;
  final LlamaRuntime llama;

  /// Every load goes through here so exactly one reasoner is ever loaded.
  final ReasonerCoordinator reasoner;

  /// The encoder's verified accelerator, for the role card.
  final EmbeddingAcceleratorStatus Function() embeddingStatus;

  /// Persists the chosen path so it survives a relaunch.
  final Future<void> Function(String path) onRemember;
  final String? rememberedPath;

  /// Same idea, for the llama.cpp card — path and backend remembered
  /// together since loading one without the other is not a valid state to
  /// restore into.
  final Future<void> Function(String path, LlamaBackend backend) onRememberLlama;
  final String? rememberedLlamaPath;
  final LlamaBackend? rememberedLlamaBackend;

  const ModelPage({
    super.key,
    required this.llm,
    required this.llama,
    required this.reasoner,
    required this.embeddingStatus,
    required this.onRemember,
    required this.rememberedPath,
    required this.onRememberLlama,
    required this.rememberedLlamaPath,
    required this.rememberedLlamaBackend,
  });

  @override
  State<ModelPage> createState() => _ModelPageState();
}

class _ModelPageState extends State<ModelPage> {
  final _pathController = TextEditingController();
  ModelProbeResult? _inspection;
  bool _working = false;

  /// User's explicit answer to "which build is this file?", when they gave
  /// one. Null means "use the filename inference", which is the right default
  /// whenever the filename actually says something. Only offered, and only
  /// meaningful, when the inference came back [SuggestedBackend.unknown].
  LlmBackend? _backendOverride;

  // --- llama.cpp (GGUF) card state ---------------------------------------
  final _llamaPathController = TextEditingController();
  LlamaBackend _llamaBackend = LlamaBackend.cpu;
  final _llamaPromptController = TextEditingController();
  bool _llamaWorking = false;
  String? _llamaGenerationResult;

  @override
  void initState() {
    super.initState();
    final remembered = widget.rememberedPath;
    if (remembered != null) _pathController.text = remembered;

    final rememberedLlama = widget.rememberedLlamaPath;
    if (rememberedLlama != null) _llamaPathController.text = rememberedLlama;
    final rememberedBackend = widget.rememberedLlamaBackend;
    if (rememberedBackend != null) _llamaBackend = rememberedBackend;
  }

  @override
  void dispose() {
    _pathController.dispose();
    _llamaPathController.dispose();
    _llamaPromptController.dispose();
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
      // A new file invalidates the previous answer. Carrying an override
      // from the last inspection onto a different model is exactly the kind
      // of stale-state bug that produces the crash this page is guarding
      // against, so it is dropped on every inspect.
      _backendOverride = null;
    });
  }

  Future<void> _load() async {
    final path = _pathController.text.trim();
    if (path.isEmpty) return;
    setState(() => _working = true);

    final activation = await widget.reasoner.activate(
      ReasonerKind.mediapipe,
      () => widget.llm.load(path, backendOverride: _backendOverride),
    );
    final ok = activation.ok;
    if (ok) await widget.onRemember(path);
    if (!mounted) return;
    setState(() => _working = false);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Loaded on ${widget.llm.backendLabel.toUpperCase()} in '
              '${widget.llm.loadMs} ms${_unloadedNote(activation)}'
          : widget.llm.error ?? 'Load failed'),
      duration: const Duration(seconds: 6),
    ));
  }

  /// " · MediaPipe unloaded" when activating one reasoner evicted the other.
  static String _unloadedNote(ReasonerActivation a) => a.unloaded.isEmpty
      ? ''
      : ' · ${a.unloaded.map((k) => k.label).join(', ')} unloaded (one reasoner at a time)';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.llm, widget.llama, widget.reasoner]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(
          VaultSpace.lg,
          VaultSpace.sm,
          VaultSpace.lg,
          VaultSpace.xxl,
        ),
        children: [
          _statusCard(),
          const SizedBox(height: VaultSpace.lg),
          _roleCard(),
          const SizedBox(height: VaultSpace.xl),
          _sectionHeader('Load a reasoner',
              'Loading either runtime unloads the other.'),
          const SizedBox(height: VaultSpace.md),
          _llamaCard(),
          const SizedBox(height: VaultSpace.lg),
          _pickerCard(),
          if (_inspection != null) ...[
            const SizedBox(height: VaultSpace.lg),
            _inspectionCard(_inspection!),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, String subtitle) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VaultSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(header: true, child: Text(title, style: text.titleLarge)),
          const SizedBox(height: 2),
          Text(subtitle,
              style: text.bodyMedium!.copyWith(color: VaultColors.muted)),
        ],
      ),
    );
  }

  /// The one card read first, so it answers honestly: which reasoner is
  /// selected, and is it loaded. It reads [ReasonerCoordinator] — the same
  /// selection [VaultEngine.ask] routes by — rather than inferring from
  /// whichever runtime happens to be ready, so it can never contradict what
  /// "Ask on device" will actually use.
  Widget _statusCard() {
    final text = Theme.of(context).textTheme;
    final llm = widget.llm;
    final llama = widget.llama;
    final slot = widget.reasoner.activeSlot;
    final ready = slot?.isReady ?? false;
    final loading = llm.state == LlmState.loading ||
        llm.state == LlmState.probing ||
        llama.state == LlamaState.loading;
    final failed =
        llm.state == LlmState.failed || llama.state == LlamaState.failed;

    final (label, color) = switch (true) {
      _ when ready => ('Loaded', VaultColors.accent),
      _ when loading => ('Loading', VaultColors.warn),
      _ when failed => ('Failed', VaultColors.danger),
      _ => ('Not loaded', VaultColors.faint),
    };

    return SectionCard(
      icon: Icons.psychology_rounded,
      title: 'Active reasoner',
      subtitle: slot == null ? 'None selected' : slot.kind.label,
      trailing: StatusPill(
        label: label,
        color: color,
        pulsing: llm.isGenerating || llama.isGenerating || loading,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ready) ...[
            Text(slot!.modelLabel, style: text.titleMedium!.copyWith(
                fontFamily: 'monospace', fontWeight: FontWeight.w400,
                fontSize: 15)),
            const SizedBox(height: VaultSpace.md),
            if (slot.kind == ReasonerKind.llama)
              _engineMetrics(
                backend: llama.backend?.label ?? '?',
                loadMs: llama.loadMs,
                queueDepth: llama.queueDepth,
              )
            else
              _engineMetrics(
                backend: llm.backendLabel.toUpperCase(),
                loadMs: llm.loadMs,
                queueDepth: llm.queueDepth,
              ),
            const SizedBox(height: VaultSpace.md),
            OutlinedButton.icon(
              onPressed: _working || _llamaWorking
                  ? null
                  : () => widget.reasoner.unloadActive(),
              icon: const Icon(Icons.eject_rounded, size: 18),
              label: const Text('Unload'),
            ),
          ] else if (loading)
            const _LoadingBlock()
          else
            Text(
              'Queries still work without a model: the capsule is built from '
              'retrieval alone and the answer is quoted verbatim from the '
              'corpus instead of written.',
              style: text.bodyMedium!.copyWith(color: VaultColors.muted),
            ),
          if (llm.error != null) ...[
            const SizedBox(height: VaultSpace.md),
            _note(llm.error!, NoticeTone.danger),
          ],
          if (llama.error != null) ...[
            const SizedBox(height: VaultSpace.md),
            _note(llama.error!, NoticeTone.danger),
          ],
        ],
      ),
    );
  }

  Widget _engineMetrics({
    required String backend,
    required int loadMs,
    required int queueDepth,
  }) {
    return Row(
      children: [
        Expanded(
          child: MetricTile(
            label: 'Backend',
            value: backend.toUpperCase(),
            accent: VaultColors.accent,
          ),
        ),
        const SizedBox(width: VaultSpace.sm),
        Expanded(
          child: MetricTile(
              label: 'Load', value: _seconds(loadMs), unit: loadMs < 1000 ? 'ms' : 's'),
        ),
        const SizedBox(width: VaultSpace.sm),
        Expanded(
          child: MetricTile(
            label: 'Queue',
            value: '$queueDepth',
            accent: queueDepth > 0 ? VaultColors.warn : null,
          ),
        ),
      ],
    );
  }

  static String _seconds(int ms) =>
      ms < 1000 ? '$ms' : (ms / 1000).toStringAsFixed(1);

  Widget _pickerCard() {
    final llm = widget.llm;
    return SectionCard(
      icon: Icons.token_outlined,
      title: 'MediaPipe',
      subtitle: 'Gemma int4 bundle (.task or .bin)',
      trailing: llm.isReady
          ? const VaultTag('Loaded', selected: true)
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _pathController,
            enabled: !_working,
            autocorrect: false,
            style: VaultText.mono.copyWith(
              color: VaultColors.foreground,
              fontSize: 13,
            ),
            maxLines: 2,
            minLines: 1,
            decoration: const InputDecoration(
              labelText: 'Model path',
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
                child: FilledButton.tonalIcon(
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
    final text = Theme.of(context).textTheme;
    final usable = probe.isUsable;
    return SectionCard(
      icon: usable ? Icons.fact_check_outlined : Icons.block_rounded,
      title: 'What that file is',
      trailing: StatusPill(
        label: usable ? 'Supported' : 'Cannot load',
        color: usable ? VaultColors.accent : VaultColors.danger,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: MetricTile(
                  label: 'Format',
                  value: probe.format.label.split(' ').first,
                  accent: usable ? VaultColors.accent : VaultColors.danger,
                  footnote: probe.format.label,
                ),
              ),
              const SizedBox(width: VaultSpace.sm),
              Expanded(
                child: MetricTile(
                  label: 'Size',
                  value: probe.sizeLabel,
                  unavailable: probe.sizeBytes == 0,
                ),
              ),
              const SizedBox(width: VaultSpace.sm),
              // Shown before the Load button, not in the success snackbar
              // afterwards. Which backend the weights were built for is the
              // one fact on this card that decides whether tapping Load
              // returns or kills the process, so it belongs next to the
              // format, at the moment the decision is still reversible.
              Expanded(
                child: MetricTile(
                  label: 'Built for',
                  value: _plannedBackend(probe).label,
                  // Amber, not the greyed-out `unavailable` treatment. An
                  // unknown backend is not a lane the device declined to
                  // report — it is the one unresolved risk on the card, and
                  // it should look like an alert rather than an absence.
                  accent: _unsure(probe) ? VaultColors.warn : VaultColors.accent,
                  footnote: _backendSource(probe),
                ),
              ),
            ],
          ),
          if (probe.sizeWarning != null) ...[
            const SizedBox(height: VaultSpace.md),
            _note(probe.sizeWarning!, NoticeTone.warn),
          ],
          if (probe.backendWarning != null) ...[
            const SizedBox(height: VaultSpace.md),
            _note(probe.backendWarning!, NoticeTone.warn),
            const SizedBox(height: VaultSpace.lg),
            _backendOverridePicker(),
          ],
          if (probe.magicHex != null) ...[
            const SizedBox(height: VaultSpace.lg),
            Text('First bytes', style: text.titleSmall),
            const SizedBox(height: VaultSpace.sm),
            CodeBlock(probe.magicHex!),
          ],
          if (probe.error != null) ...[
            const SizedBox(height: VaultSpace.md),
            _note(probe.error!, NoticeTone.danger),
          ],
          if (probe.format.remedy != null) ...[
            const SizedBox(height: VaultSpace.md),
            _note(probe.format.remedy!, NoticeTone.info),
          ],
          if (usable) ...[
            const SizedBox(height: VaultSpace.lg),
            FilledButton.icon(
              onPressed: _working ? null : _load,
              icon: const Icon(Icons.memory_rounded, size: 18),
              label: Text(_working ? 'Working…' : 'Load into memory'),
            ),
            const SizedBox(height: VaultSpace.sm),
            Text(
              // Derived, never hardcoded. This line used to read "Tries the
              // GPU backend first and falls back to CPU", which stopped being
              // true the moment the filename started deciding the order — and
              // a caption that confidently describes the opposite of what the
              // button does is worse than no caption on a screen whose whole
              // job is to stop a crash.
              '${_planDescription(probe)} Expect tens of seconds and a large '
              'jump in memory use.',
              style: text.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  /// True when nothing — not the filename, not the user — has said which
  /// build this is, so the backend about to be used is a guess.
  bool _unsure(ModelProbeResult probe) =>
      _backendOverride == null &&
      probe.suggestedBackend == SuggestedBackend.unknown;

  /// What the BUILT FOR tile shows: the user's answer if they gave one,
  /// otherwise whatever the filename implied.
  SuggestedBackend _plannedBackend(ModelProbeResult probe) =>
      switch (_backendOverride) {
        LlmBackend.cpu => SuggestedBackend.cpu,
        LlmBackend.gpu => SuggestedBackend.gpu,
        null => probe.suggestedBackend,
      };

  /// Where that value came from. Provenance matters more than the value
  /// here — "you told us" and "we read it off the filename" warrant very
  /// different levels of trust, and the tile should not flatten them.
  String _backendSource(ModelProbeResult probe) {
    if (_backendOverride != null) return 'you chose this';
    return switch (probe.suggestedBackend) {
      SuggestedBackend.unknown => 'not in filename',
      _ => 'from filename',
    };
  }

  String _planDescription(ModelProbeResult probe) {
    if (_backendOverride != null) {
      return 'Loads on ${_backendOverride!.name.toUpperCase()} only, because '
          'you selected it — no fallback to the other backend.';
    }
    return switch (probe.suggestedBackend) {
      SuggestedBackend.cpu => 'Loads on CPU only. The filename says these are '
          'CPU weights, and the GPU backend is never offered them.',
      SuggestedBackend.gpu =>
        'Tries GPU first and falls back to CPU if GPU initialisation fails.',
      SuggestedBackend.unknown =>
        'Tries CPU first, then GPU — CPU first because it is the guess you '
            'can recover from.',
    };
  }

  /// Inline choice rather than a dialog.
  ///
  /// The page's whole shape is progressive disclosure — pick, inspect, load —
  /// and a modal asking "CPU or GPU?" would ask for the answer at the worst
  /// moment, after the user has committed to loading and while they are
  /// waiting. Asking inline, on the card that just told them the filename is
  /// ambiguous, puts the question next to the evidence for it.
  Widget _backendOverridePicker() {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('If you know which build this is', style: text.titleSmall),
        const SizedBox(height: VaultSpace.sm),
        SegmentedButton<LlmBackend>(
          // Deselecting the chosen option returns to "I don't know" without
          // re-inspecting the file.
          emptySelectionAllowed: true,
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
                value: LlmBackend.cpu, label: Text('CPU · safer')),
            ButtonSegment(
                value: LlmBackend.gpu, label: Text('GPU · faster')),
          ],
          selected: {?_backendOverride},
          onSelectionChanged: _working
              ? null
              : (s) => setState(
                  () => _backendOverride = s.isEmpty ? null : s.first),
        ),
      ],
    );
  }

  Widget _note(String message, NoticeTone tone) =>
      Notice(message: message, tone: tone);

  /// The GGUF / llama.cpp path. Deliberately no backend-mismatch warning
  /// here the way [_inspectionCard] has one: llama.cpp resolves
  /// "cpu"/"gpu"/"npu" to a specific device by name on the native side, so an
  /// unavailable device is a clean load error, never the silent-crash risk a
  /// MediaPipe backend guess is.
  Widget _llamaCard() {
    return ListenableBuilder(
      listenable: widget.llama,
      builder: (context, _) {
        final text = Theme.of(context).textTheme;
        final llama = widget.llama;

        return SectionCard(
          icon: Icons.developer_board_rounded,
          title: 'llama.cpp',
          subtitle: 'GGUF: SmolLM2, Qwen3, Gemma',
          trailing: switch (llama.state) {
            LlamaState.ready => const VaultTag('Loaded', selected: true),
            LlamaState.loading =>
              const VaultTag('Loading', color: VaultColors.warn),
            LlamaState.failed =>
              const VaultTag('Failed', color: VaultColors.danger),
            LlamaState.unloaded => null,
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _llamaPathController,
                enabled: !_llamaWorking,
                autocorrect: false,
                style: VaultText.mono.copyWith(
                  color: VaultColors.foreground,
                  fontSize: 13,
                ),
                maxLines: 2,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: 'GGUF path',
                  hintText: '/storage/emulated/0/Download/'
                      'qwen3-1.7b-q4_k_m.gguf',
                  suffixIcon: IconButton(
                    tooltip: 'Browse',
                    onPressed: _llamaWorking ? null : _llamaBrowse,
                    icon: const Icon(Icons.folder_open_rounded),
                  ),
                ),
              ),
              const SizedBox(height: VaultSpace.lg),
              Text('Backend', style: text.titleSmall),
              const SizedBox(height: VaultSpace.sm),
              SegmentedButton<LlamaBackend>(
                showSelectedIcon: false,
                segments: [
                  for (final b in LlamaBackend.values)
                    ButtonSegment(value: b, label: Text(b.label)),
                ],
                selected: {_llamaBackend},
                onSelectionChanged: _llamaWorking
                    ? null
                    : (s) => setState(() => _llamaBackend = s.first),
              ),
              const SizedBox(height: VaultSpace.lg),
              FilledButton.icon(
                onPressed: _llamaWorking ? null : _llamaLoad,
                icon: const Icon(Icons.memory_rounded, size: 18),
                label: Text(_llamaWorking ? 'Working…' : 'Load into memory'),
              ),
              if (llama.isReady) ...[
                const SizedBox(height: VaultSpace.xl),
                Text('Smoke test', style: text.titleSmall),
                const SizedBox(height: 2),
                Text('Raw generation, no retrieval involved.',
                    style: text.bodySmall),
                const SizedBox(height: VaultSpace.md),
                TextField(
                  controller: _llamaPromptController,
                  enabled: !_llamaWorking,
                  maxLines: 3,
                  minLines: 1,
                  decoration: const InputDecoration(
                    labelText: 'Test prompt',
                  ),
                ),
                const SizedBox(height: VaultSpace.sm),
                OutlinedButton.icon(
                  onPressed: _llamaWorking ? null : _llamaGenerate,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Generate'),
                ),
                if (_llamaGenerationResult != null) ...[
                  const SizedBox(height: VaultSpace.md),
                  CodeBlock(_llamaGenerationResult!),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _llamaBrowse() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty || !mounted) return;
    final path = files.first.path;
    if (path == null) return;
    setState(() => _llamaPathController.text = path);
  }

  Future<void> _llamaLoad() async {
    final path = _llamaPathController.text.trim();
    if (path.isEmpty) return;
    setState(() {
      _llamaWorking = true;
      _llamaGenerationResult = null;
    });

    final activation = await widget.reasoner.activate(
      ReasonerKind.llama,
      () => widget.llama.load(path, backend: _llamaBackend),
    );
    final ok = activation.ok;
    if (ok) await widget.onRememberLlama(path, _llamaBackend);
    if (!mounted) return;
    setState(() => _llamaWorking = false);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Loaded on ${widget.llama.backend?.label} in '
              '${widget.llama.loadMs} ms${_unloadedNote(activation)}'
          : widget.llama.error ?? 'Load failed'),
      duration: const Duration(seconds: 6),
    ));
  }

  Future<void> _llamaGenerate() async {
    final prompt = _llamaPromptController.text.trim();
    if (prompt.isEmpty) return;
    setState(() {
      _llamaWorking = true;
      _llamaGenerationResult = null;
    });

    try {
      final result = await widget.llama.generate(prompt);
      if (!mounted) return;
      setState(() {
        _llamaGenerationResult = '${result.text}\n\n'
            '— ${result.tokens} tokens, ${result.prefillMs} ms prefill, '
            '${result.decodeMs} ms decode'
            '${result.tokensPerSecond != null ? ', ${result.tokensPerSecond!.toStringAsFixed(1)} tok/s' : ''}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _llamaGenerationResult = 'Generation failed: $e');
    } finally {
      if (mounted) setState(() => _llamaWorking = false);
    }
  }

  Widget _roleCard() {
    final slot = widget.reasoner.activeSlot;
    final status = widget.embeddingStatus();
    final (encoderTag, encoderColor, encoderWhere) = switch (status.verdict) {
      AcceleratorVerdict.qnnHtpVerified => (
          'QNN HTP verified',
          VaultColors.accent,
          'Running on the Hexagon NPU (${status.detail}).',
        ),
      AcceleratorVerdict.qnnUnavailable => (
          'QNN unavailable',
          VaultColors.warn,
          '${status.detail ?? 'No detail'}. Running on ${status.activeBackend}.',
        ),
      AcceleratorVerdict.xnnpackFallback => (
          'XNNPACK fallback',
          VaultColors.warn,
          'QNN HTP was rejected: ${status.detail ?? 'no detail'}.',
        ),
      AcceleratorVerdict.notAttempted => (
          status.activeBackend,
          VaultColors.muted,
          'Running on ${status.activeBackend}.',
        ),
    };
    final reasonerText = slot == null
        ? 'No reasoner selected. Load a GGUF model or a Gemma bundle below.'
        : slot.isReady
            ? 'Reads the chunks retrieval found and writes them up as a JSON '
                'capsule, once per query.'
            : '${slot.kind.label} is selected but not loaded. Queries return '
                'the extractive capsule until it is.';

    return SectionCard(
      icon: Icons.account_tree_outlined,
      title: 'On-device pipeline',
      subtitle: 'Two models, one reasoner at a time',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _role(
            step: '1',
            name: 'MiniLM-L6-v2',
            job: 'Encode',
            tag: encoderTag,
            tagColor: encoderColor,
            detail: 'Every chunk and query becomes a 384-dim vector. '
                'Always loaded. $encoderWhere',
          ),
          const SizedBox(height: VaultSpace.sm),
          _role(
            step: '2',
            name: slot?.isReady ?? false ? slot!.modelLabel : 'Reasoner',
            job: 'Reason',
            tag: slot?.isReady ?? false ? slot!.backendLabel : 'Not loaded',
            tagColor: slot?.isReady ?? false ? VaultColors.accent : VaultColors.faint,
            detail: reasonerText,
          ),
          const SizedBox(height: VaultSpace.md),
          Text(
            'Capsule schema $promptVersion. The prompt is fixed and versioned, '
            'so a stored capsule traces back to the instructions that '
            'produced it.',
            style: Theme.of(context).textTheme.bodySmall!
                .copyWith(color: VaultColors.faint),
          ),
        ],
      ),
    );
  }

  Widget _role({
    required String step,
    required String name,
    required String job,
    required String tag,
    required Color tagColor,
    required String detail,
  }) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(VaultSpace.md),
      decoration: BoxDecoration(
        color: VaultColors.surfaceHigh,
        borderRadius: BorderRadius.circular(VaultSpace.radiusMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: VaultColors.surfaceHighest,
              shape: BoxShape.circle,
            ),
            child: Text(step, style: text.labelLarge),
          ),
          const SizedBox(width: VaultSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$job · $name',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall),
                const SizedBox(height: VaultSpace.xs),
                VaultTag(tag, color: tagColor),
                const SizedBox(height: VaultSpace.sm),
                Text(detail,
                    style: text.bodyMedium!.copyWith(color: VaultColors.muted)),
              ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const LinearProgressIndicator(),
        const SizedBox(height: VaultSpace.md),
        Text(
          'Loading weights into memory. This takes tens of seconds for a '
          '1–2 GB model and the runtime reports no progress. The app stays '
          'responsive because the load runs on its own thread.',
          style: Theme.of(context).textTheme.bodyMedium!
              .copyWith(color: VaultColors.muted),
        ),
      ],
    );
  }
}
