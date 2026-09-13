/// vault_page.dart
///
/// Local ingest and retrieval — the vault working entirely on its own, with
/// no desktop attached.
///
/// This path is kept deliberately, not for backwards compatibility. It is
/// the one that demonstrates the actual claim: the phone does the work.
/// With the bridge connected it is easy to lose track of which machine is
/// embedding, so being able to pull the network out and have everything
/// still function is the proof.

library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/gating.dart';
import '../core/llm/capsule.dart';
import '../core/security/ephemeral_clipboard.dart';
import '../core/security/security_constants.dart';
import '../core/llm/reasoner_coordinator.dart';
import '../core/vault_engine.dart';
import '../core/vector_store.dart';
import 'theme.dart';
import 'widgets/common.dart';

class VaultPage extends StatefulWidget {
  final VaultEngine engine;
  /// The single selected reasoner; see reasoner_coordinator.dart.
  final ReasonerCoordinator reasoner;

  /// Injectable for widget tests; a platform-backed one is created otherwise.
  final EphemeralClipboard? clipboard;

  /// Pre-populated result, for screenshot and widget tests.
  @visibleForTesting
  final ContextCapsule? initialCapsule;

  const VaultPage({
    super.key,
    required this.engine,
    required this.reasoner,
    this.clipboard,
    this.initialCapsule,
  });

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  final _queryController = TextEditingController();

  List<PlatformFile> _picked = [];
  final Map<String, String> _fileStatus = {};

  bool _busy = false;
  String _progress = '';
  ContextCapsule? _capsule;
  String? _searchError;

  /// Defaults to on, but only does anything when a model is loaded. The
  /// switch stays visible while unloaded so the reason a query came back
  /// without written prose is discoverable rather than mysterious.
  bool _generate = true;
  bool _showRawJson = false;

  /// Owns the 20-second lifecycle of whatever capsule was last copied.
  late final EphemeralClipboard _clipboard;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _clipboard = widget.clipboard ?? EphemeralClipboard();
    _capsule = widget.initialCapsule;
    // Android only lets the foreground app read the clipboard, so an expiry
    // that fired while backgrounded is retried when the app comes back.
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_clipboard.checkNow()),
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _clipboard.dispose();
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    // file_picker 12 dropped FilePickerResult: pickFiles is static and
    // returns the list directly, empty when the user cancels.
    final files = await FilePicker.pickFiles();
    if (files.isEmpty || !mounted) return;
    setState(() {
      _picked = files;
      _fileStatus.clear();
    });
  }

  Future<void> _ingest() async {
    if (_picked.isEmpty) return;
    setState(() {
      _busy = true;
      _progress = '';
    });

    var totalChunks = 0;
    var totalMs = 0;

    for (var i = 0; i < _picked.length; i++) {
      final file = _picked[i];
      final path = file.path;
      final ext = (file.extension ?? '').toLowerCase();

      if (path == null) {
        setState(() => _fileStatus[file.name] = 'Skipped — unreadable');
        continue;
      }
      if (!allowedExtensions.contains(ext)) {
        setState(() => _fileStatus[file.name] = 'Skipped — .$ext not allowed');
        continue;
      }

      try {
        final content = await File(path).readAsString();
        final result = await widget.engine.indexDocument(
          file.name,
          content,
          onProgress: (done, total) {
            if (!mounted) return;
            setState(() => _progress = 'File ${i + 1}/${_picked.length} · '
                '${file.name} · chunk $done/$total');
          },
        );
        totalChunks += result.chunksAdded;
        totalMs += result.elapsedMs;
        if (!mounted) return;
        setState(() => _fileStatus[file.name] =
            '${result.chunksAdded} chunks · ${result.elapsedMs} ms');
      } catch (e) {
        if (!mounted) return;
        // Binary files land here via readAsString throwing on invalid UTF-8,
        // which is the cheapest reliable "is this text" test available.
        setState(() => _fileStatus[file.name] = 'Skipped — not readable text');
      }
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _progress = '';
    });
    final perChunk = totalChunks == 0 ? 0 : totalMs / totalChunks;
    if (totalChunks > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Indexed $totalChunks chunks · '
            '${perChunk.toStringAsFixed(0)} ms/chunk'),
      ));
    }
  }

  Future<void> _ask() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _searchError = null;
    });
    try {
      final capsule = await widget.engine.ask(
        query,
        topK: 5,
        generate: _generate,
      );
      if (!mounted) return;
      setState(() {
        _capsule = capsule;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _searchError = '$e';
      });
    }
  }

  Future<void> _clear() async {
    await widget.engine.clear();
    if (!mounted) return;
    setState(() {
      _capsule = null;
      _fileStatus.clear();
      _picked = [];
    });
  }

  /// Copies the capsule with a 20-second lifetime.
  ///
  /// The previous build also wrote the JSON to external storage as an adb
  /// fallback. That file was decrypted vault content persisted in plaintext
  /// with no expiry, readable by anything with USB debugging — the exact
  /// leak the encrypted store exists to prevent — so it is gone.
  Future<void> _copyResults() async {
    final capsule = _capsule;
    if (capsule == null) return;
    await _clipboard.copy(capsule.toPrettyJson());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(
        children: [
          const Icon(Icons.lock_clock_outlined,
              size: 18, color: Color(0xFF006D36)),
          const SizedBox(width: VaultSpace.sm),
          Expanded(
            child: Text('Ephemeral buffer active: auto-destructs in '
                '${kClipboardTtl.inSeconds}s'),
          ),
        ],
      ),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    final canIngest = engine.isReady && !_busy && _picked.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        VaultSpace.lg,
        VaultSpace.sm,
        VaultSpace.lg,
        VaultSpace.xxl,
      ),
      children: [
        _queryCard(),
        if (_capsule != null) ...[
          const SizedBox(height: VaultSpace.lg),
          _capsuleCard(_capsule!),
        ],
        const SizedBox(height: VaultSpace.lg),
        _ingestCard(canIngest),
      ],
    );
  }

  Widget _ingestCard(bool canIngest) {
    return ListenableBuilder(
      listenable: widget.engine,
      builder: (context, _) {
        final text = Theme.of(context).textTheme;
        return SectionCard(
          icon: Icons.folder_rounded,
          title: 'Corpus',
          subtitle: '${widget.engine.chunkCount} encrypted chunks on this device',
          trailing: IconButton(
            tooltip: 'Clear the vault',
            onPressed: widget.engine.isReady && !_busy ? _confirmClear : null,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_picked.isNotEmpty) ...[
                for (final f in _picked) _pickedFileRow(f, text),
                const SizedBox(height: VaultSpace.md),
              ],
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          widget.engine.isReady && !_busy ? _pickFiles : null,
                      icon: const Icon(Icons.upload_file_rounded, size: 18),
                      label: Text(_picked.isEmpty ? 'Choose files' : 'Change'),
                    ),
                  ),
                  if (_picked.isNotEmpty) ...[
                    const SizedBox(width: VaultSpace.sm),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: canIngest ? _ingest : null,
                        icon: const Icon(Icons.lock_rounded, size: 18),
                        label: const Text('Embed'),
                      ),
                    ),
                  ],
                ],
              ),
              if (_progress.isNotEmpty) ...[
                const SizedBox(height: VaultSpace.lg),
                const LinearProgressIndicator(),
                const SizedBox(height: VaultSpace.sm),
                Text(_progress, style: text.bodySmall),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _pickedFileRow(PlatformFile f, TextTheme text) {
    final status = _fileStatus[f.name];
    final skipped = (status ?? '').startsWith('Skip');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VaultSpace.xs),
      child: Row(
        children: [
          Icon(
            skipped
                ? Icons.block_rounded
                : status == null
                    ? Icons.description_outlined
                    : Icons.check_circle_outline_rounded,
            size: 20,
            color: skipped
                ? VaultColors.warn
                : status == null
                    ? VaultColors.muted
                    : VaultColors.accent,
          ),
          const SizedBox(width: VaultSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(f.name,
                    overflow: TextOverflow.ellipsis, style: text.bodyMedium),
                Text(
                  status ?? 'Ready to embed',
                  style: text.bodySmall!.copyWith(
                    color: skipped ? VaultColors.warn : VaultColors.faint,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear() async {
    // Destructive and irreversible — re-embedding a corpus is minutes of
    // work, so this one gets a confirmation even though nothing else does.
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: const Text('Clear the vault?'),
        content: Text(
          'Deletes all ${widget.engine.chunkCount} chunks. The source files '
          'are untouched, but re-embedding them takes as long as it did the '
          'first time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: VaultColors.danger),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) await _clear();
  }

  Widget _queryCard() {
    return SectionCard(
      icon: Icons.search_rounded,
      title: 'Ask the vault',
      subtitle: 'Retrieval and reasoning run on this phone',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _queryController,
            enabled: widget.engine.isReady && !_busy,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _ask(),
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'What is the maximum notional order limit?',
            ),
          ),
          const SizedBox(height: VaultSpace.sm),
          _generateToggle(),
          const SizedBox(height: VaultSpace.sm),
          FilledButton.icon(
            onPressed: widget.engine.isReady && !_busy ? _ask : null,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: VaultColors.muted),
                  )
                : const Icon(Icons.arrow_upward_rounded, size: 18),
            label: Text(_busy
                ? ((widget.reasoner.activeSlot?.isBusy ?? false)
                    ? 'Reasoning…'
                    : 'Retrieving…')
                : 'Ask on device'),
          ),
          if (_searchError != null) ...[
            const SizedBox(height: VaultSpace.md),
            Notice(
              tone: NoticeTone.danger,
              title: 'Query failed',
              message: _searchError!,
            ),
          ],
        ],
      ),
    );
  }

  /// Whether to run the reasoning model on this query.
  ///
  /// Shown even when no model is loaded, with the reason attached. A toggle
  /// that silently does nothing is worse than one that explains itself —
  /// otherwise "why is there no written answer" has no discoverable answer
  /// from this screen.
  Widget _generateToggle() {
    return ListenableBuilder(
      listenable: widget.reasoner,
      builder: (context, _) {
        final text = Theme.of(context).textTheme;
        final slot = widget.reasoner.activeSlot;
        final ready = slot?.isReady ?? false;
        return MergeSemantics(
          child: InkWell(
            onTap: ready ? () => setState(() => _generate = !_generate) : null,
            borderRadius: BorderRadius.circular(VaultSpace.radiusMd),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: VaultSpace.sm),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Reason over the results',
                          style: text.titleSmall!.copyWith(
                            color: ready
                                ? VaultColors.foreground
                                : VaultColors.faint,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          ready
                              ? '${slot!.modelLabel} · ${slot.kind.label} '
                                  'writes the answer'
                              : 'No model loaded. Load one on the Model tab; '
                                  'answers are quoted from retrieval until then.',
                          style: text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: VaultSpace.md),
                  Switch(
                    value: _generate && ready,
                    onChanged:
                        ready ? (v) => setState(() => _generate = v) : null,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _capsuleCard(ContextCapsule capsule) {
    final generation = capsule.generation;
    return SectionCard(
      icon: Icons.inventory_2_outlined,
      title: 'Context capsule',
      subtitle: generation.ran
          ? '${generation.backend} · ${_seconds(generation.elapsedMs ?? 0)}'
          : 'Retrieval only · ${capsule.retrieval['latency_ms']} ms',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: _showRawJson ? 'Show formatted' : 'Show raw JSON',
            isSelected: _showRawJson,
            onPressed: () => setState(() => _showRawJson = !_showRawJson),
            icon: const Icon(Icons.data_object_rounded),
            selectedIcon:
                const Icon(Icons.data_object_rounded, color: VaultColors.accent),
          ),
          IconButton(
            tooltip: 'Copy capsule (clears in ${kClipboardTtl.inSeconds}s)',
            onPressed: _copyResults,
            icon: const Icon(Icons.copy_rounded),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ephemeralBanner(),
          _provenanceRow(capsule),
          const SizedBox(height: VaultSpace.lg),
          _showRawJson
              ? CodeBlock(capsule.toPrettyJson())
              : _capsuleBody(capsule),
        ],
      ),
    );
  }

  static String _seconds(int ms) =>
      ms < 1000 ? '$ms ms' : '${(ms / 1000).toStringAsFixed(1)} s';

  /// Live countdown while a copied capsule is still on the clipboard, then a
  /// one-line outcome. Text carries the state; the bar only reinforces it.
  Widget _ephemeralBanner() {
    return ListenableBuilder(
      listenable: _clipboard,
      builder: (context, _) {
        final active = _clipboard.isActive;
        final outcome = _clipboard.lastOutcome;
        if (!active && outcome == null) return const SizedBox.shrink();

        final (IconData icon, NoticeTone tone, String text) = active
            ? (
                Icons.lock_clock_outlined,
                NoticeTone.success,
                'On the clipboard for ${_clipboard.secondsRemaining} more '
                    'seconds, then scrubbed.',
              )
            : switch (outcome!) {
                ScrubOutcome.cleared => (
                    Icons.check_circle_outline_rounded,
                    NoticeTone.neutral,
                    'Capsule removed from the clipboard.',
                  ),
                ScrubOutcome.replaced => (
                    Icons.info_outline_rounded,
                    NoticeTone.neutral,
                    'Clipboard changed since the copy, so it was left untouched.',
                  ),
                ScrubOutcome.unreadable => (
                    Icons.schedule_rounded,
                    NoticeTone.warn,
                    'Clipboard unreadable in the background; will scrub on '
                        'return if unchanged.',
                  ),
                ScrubOutcome.superseded => (
                    Icons.info_outline_rounded,
                    NoticeTone.neutral,
                    'Superseded by a newer copy.',
                  ),
              };
        final reduceMotion = MediaQuery.of(context).disableAnimations;

        return Semantics(
          liveRegion: true,
          label: text,
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.only(bottom: VaultSpace.md),
              child: Notice(
                tone: tone,
                icon: icon,
                title: active ? 'Ephemeral buffer active' : null,
                message: text,
                action: active
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(end: _clipboard.fractionRemaining),
                          duration: reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 250),
                          builder: (context, value, _) =>
                              LinearProgressIndicator(value: value),
                        ),
                      )
                    : null,
              ),
            ),
          ),
        );
      },
    );
  }

  /// Answer path and signature state, stated without overclaiming.
  Widget _provenanceRow(ContextCapsule capsule) {
    final p = capsule.provenance;
    final signed = p?.isSigned ?? false;
    final String signature;
    if (p == null) {
      signature = 'Not signed';
    } else if (signed) {
      signature = 'Signed · ${p.keySecurityLevel == 'strongbox' ? 'StrongBox' : p.enclave}';
    } else if (p.signatureAlgorithm == 'MOCK-UNSIGNED') {
      signature = 'Mock signature';
    } else {
      signature = 'Signing failed';
    }
    return Wrap(
      spacing: VaultSpace.sm,
      runSpacing: VaultSpace.sm,
      children: [
        VaultTag(
          switch (capsule.gatingPath) {
            GatingPath.llmSynthesized => 'Model answer',
            GatingPath.extractiveFallback => 'Retrieval only',
          },
          icon: capsule.gatingPath == GatingPath.llmSynthesized
              ? Icons.auto_awesome_rounded
              : Icons.format_quote_rounded,
          color: VaultColors.info,
        ),
        VaultTag(
          signature,
          icon: signed ? Icons.verified_user_rounded : Icons.gpp_maybe_outlined,
          color: signed ? VaultColors.accent : VaultColors.warn,
        ),
        if (p != null && !signed && p.signatureError != null)
          Text(p.signatureError!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall!
                  .copyWith(color: VaultColors.warn)),
      ],
    );
  }

  Widget _capsuleBody(ContextCapsule capsule) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _answerBlock(capsule),
        if (capsule.keyFacts.isNotEmpty) ...[
          const SizedBox(height: VaultSpace.xl),
          _label('Key facts'),
          for (final fact in capsule.keyFacts) _factTile(fact),
        ],
        if (capsule.caveats.isNotEmpty) ...[
          const SizedBox(height: VaultSpace.lg),
          _label('Caveats'),
          for (final caveat in capsule.caveats)
            Padding(
              padding: const EdgeInsets.only(bottom: VaultSpace.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.info_outline_rounded,
                        size: 16, color: VaultColors.muted),
                  ),
                  const SizedBox(width: VaultSpace.sm),
                  Expanded(
                    child: Text(caveat,
                        style: text.bodyMedium!
                            .copyWith(color: VaultColors.muted)),
                  ),
                ],
              ),
            ),
        ],
        if (capsule.generation.parseError != null) ...[
          const SizedBox(height: VaultSpace.md),
          Notice(
            tone: NoticeTone.warn,
            title: 'Model output was not valid JSON',
            message: capsule.generation.parseError!,
          ),
        ],
        const SizedBox(height: VaultSpace.xl),
        _label('Retrieved context · ${capsule.context.length}'),
        if (capsule.context.isEmpty)
          const EmptyState(
            icon: Icons.inbox_outlined,
            title: 'Nothing indexed yet',
            message: 'Add files in Corpus below, then ask again.',
          )
        else
          for (final chunk in capsule.context) _chunkTile(chunk),
      ],
    );
  }

  Widget _label(String label) => Padding(
        padding: const EdgeInsets.only(bottom: VaultSpace.sm),
        child: Semantics(
          header: true,
          child: Text(label, style: Theme.of(context).textTheme.titleSmall),
        ),
      );

  Widget _answerBlock(ContextCapsule capsule) {
    final text = Theme.of(context).textTheme;
    final generated =
        capsule.generation.ran && capsule.generation.parseError == null;
    final (Color color, String confidence) = switch (capsule.confidence) {
      CapsuleConfidence.high => (VaultColors.accent, 'High confidence'),
      CapsuleConfidence.medium => (VaultColors.info, 'Medium confidence'),
      CapsuleConfidence.low => (VaultColors.warn, 'Low confidence'),
      CapsuleConfidence.none => (VaultColors.faint, 'No confidence'),
    };

    return Container(
      padding: const EdgeInsets.all(VaultSpace.lg),
      decoration: BoxDecoration(
        color: VaultColors.surfaceHigh,
        borderRadius: BorderRadius.circular(VaultSpace.radiusMd),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                generated
                    ? Icons.auto_awesome_rounded
                    : Icons.format_quote_rounded,
                size: 18,
                color: color,
              ),
              const SizedBox(width: VaultSpace.sm),
              Text(generated ? 'Answer' : 'Extracted answer',
                  style: text.labelLarge!.copyWith(color: color)),
              const Spacer(),
              Text(confidence, style: text.labelMedium!.copyWith(
                  color: VaultColors.muted)),
            ],
          ),
          const SizedBox(height: VaultSpace.md),
          SelectableText(
            capsule.answer,
            style: generated
                ? text.bodyLarge
                : VaultText.mono.copyWith(
                    fontSize: 14, height: 1.5, color: VaultColors.foreground),
          ),
          // Both provenance lines matter, for opposite reasons: a generated
          // answer is prose a model wrote and needs the caveat, while an
          // extracted one is a verbatim quote and needs to say so to be
          // trusted at all.
          const SizedBox(height: VaultSpace.md),
          Text(
            generated
                ? 'Written by the on-device model from the context below. '
                    'Quoted facts are checked against that context.'
                : 'Quoted verbatim from the indexed file. No model wrote '
                    'this.',
            style: text.bodySmall!.copyWith(color: VaultColors.faint),
          ),
        ],
      ),
    );
  }

  Widget _factTile(CapsuleFact fact) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: VaultSpace.sm),
      child: Container(
        padding: const EdgeInsets.all(VaultSpace.md),
        decoration: BoxDecoration(
          color: VaultColors.surfaceHigh,
          borderRadius: BorderRadius.circular(VaultSpace.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Text(fact.fact, style: text.bodyMedium)),
                const SizedBox(width: VaultSpace.sm),
                // The quote either occurs in the retrieved text or it does
                // not. This badge is a substring check, not a judgement, so
                // "in source" means exactly one thing.
                _verifyBadge(fact.verified),
              ],
            ),
            if (fact.verbatim != null) ...[
              const SizedBox(height: VaultSpace.sm),
              Text(
                '“${fact.verbatim!}”',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: VaultText.mono.copyWith(
                    fontSize: 12.5, height: 1.5, color: VaultColors.muted),
              ),
            ],
            if (fact.source != null) ...[
              const SizedBox(height: VaultSpace.sm),
              Row(
                children: [
                  const Icon(Icons.description_outlined,
                      size: 14, color: VaultColors.faint),
                  const SizedBox(width: VaultSpace.xs),
                  Expanded(
                    child: Text(fact.source!,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall!
                            .copyWith(color: VaultColors.faint)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _verifyBadge(bool verified) => VaultTag(
        verified ? 'In source' : 'Not found',
        icon: verified ? Icons.check_rounded : Icons.help_outline_rounded,
        color: verified ? VaultColors.accent : VaultColors.warn,
      );

  Widget _chunkTile(RetrievedChunk chunk) {
    final text = Theme.of(context).textTheme;
    final preview = chunk.content.length > 260
        ? '${chunk.content.substring(0, 260)}…'
        : chunk.content;

    return Padding(
      padding: const EdgeInsets.only(bottom: VaultSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.description_outlined,
                  size: 16, color: VaultColors.muted),
              const SizedBox(width: VaultSpace.sm),
              Expanded(
                child: Text(
                  chunk.fileName,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelLarge,
                ),
              ),
              const SizedBox(width: VaultSpace.sm),
              Semantics(
                label: 'similarity ${chunk.score.toStringAsFixed(3)}',
                excludeSemantics: true,
                child: Text(
                  chunk.score.toStringAsFixed(3),
                  style: VaultText.mono
                      .copyWith(color: VaultColors.info, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: VaultSpace.sm),
          CodeBlock(preview, maxLines: 6),
        ],
      ),
    );
  }
}
