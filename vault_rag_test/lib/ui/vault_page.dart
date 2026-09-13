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

  const VaultPage({
    super.key,
    required this.engine,
    required this.reasoner,
    this.clipboard,
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
              size: 18, color: VaultColors.accent),
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
        VaultSpace.md,
        VaultSpace.lg,
        VaultSpace.xxl,
      ),
      children: [
        _ingestCard(canIngest),
        const SizedBox(height: VaultSpace.md),
        _queryCard(),
        if (_capsule != null) ...[
          const SizedBox(height: VaultSpace.md),
          _capsuleCard(_capsule!),
        ],
      ],
    );
  }

  Widget _ingestCard(bool canIngest) {
    return ListenableBuilder(
      listenable: widget.engine,
      builder: (context, _) => SectionCard(
        title: 'Corpus',
        subtitle: '${widget.engine.chunkCount} chunks indexed on this device',
        trailing: IconButton(
          tooltip: 'Clear the vault',
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          onPressed: widget.engine.isReady && !_busy ? _confirmClear : null,
          icon: const Icon(Icons.delete_outline, color: VaultColors.muted),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton.icon(
              onPressed: widget.engine.isReady && !_busy ? _pickFiles : null,
              icon: const Icon(Icons.upload_file_rounded, size: 19),
              label: const Text('Choose files'),
            ),
            if (_picked.isNotEmpty) ...[
              const SizedBox(height: VaultSpace.md),
              for (final f in _picked)
                Padding(
                  padding: const EdgeInsets.only(bottom: VaultSpace.xs),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          f.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: VaultColors.foreground,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: VaultSpace.sm),
                      Text(
                        _fileStatus[f.name] ?? 'pending',
                        style: TextStyle(
                          color: (_fileStatus[f.name] ?? '').startsWith('Skip')
                              ? VaultColors.warn
                              : VaultColors.faint,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: VaultSpace.md),
              FilledButton.icon(
                onPressed: canIngest ? _ingest : null,
                icon: const Icon(Icons.storage_rounded, size: 19),
                label: const Text('Embed into vault'),
              ),
            ],
            if (_progress.isNotEmpty) ...[
              const SizedBox(height: VaultSpace.md),
              const LinearProgressIndicator(
                backgroundColor: VaultColors.surfaceHigh,
                color: VaultColors.accent,
              ),
              const SizedBox(height: VaultSpace.sm),
              Text(
                _progress,
                style: const TextStyle(
                  color: VaultColors.muted,
                  fontSize: 11.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClear() async {
    // Destructive and irreversible — re-embedding a corpus is minutes of
    // work, so this one gets a confirmation even though nothing else does.
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VaultColors.surface,
        title: const Text('Clear the vault?'),
        content: Text(
          'Deletes all ${widget.engine.chunkCount} chunks. The source files '
          'are untouched, but re-embedding them takes as long as it did the '
          'first time.',
          style: const TextStyle(color: VaultColors.muted, height: 1.5),
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
      title: 'Query',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _queryController,
            enabled: widget.engine.isReady && !_busy,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _ask(),
            style: const TextStyle(color: VaultColors.foreground),
            decoration: const InputDecoration(
              hintText: 'What is the maximum notional order limit?',
              prefixIcon: Icon(Icons.search, color: VaultColors.faint),
            ),
          ),
          const SizedBox(height: VaultSpace.md),
          _generateToggle(),
          const SizedBox(height: VaultSpace.md),
          FilledButton.icon(
            onPressed: widget.engine.isReady && !_busy ? _ask : null,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.bolt_rounded, size: 19),
            label: Text(_busy
                ? ((widget.reasoner.activeSlot?.isBusy ?? false)
                    ? 'Reasoning…'
                    : 'Retrieving…')
                : 'Ask on device'),
          ),
          if (_searchError != null) ...[
            const SizedBox(height: VaultSpace.md),
            Text(
              _searchError!,
              style: const TextStyle(color: VaultColors.danger, fontSize: 12),
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
        final slot = widget.reasoner.activeSlot;
        final ready = slot?.isReady ?? false;
        return InkWell(
          onTap: ready ? () => setState(() => _generate = !_generate) : null,
          borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: VaultSpace.xs),
            child: Row(
              children: [
                Switch(
                  value: _generate && ready,
                  onChanged:
                      ready ? (v) => setState(() => _generate = v) : null,
                ),
                const SizedBox(width: VaultSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Reason over the results',
                        style: TextStyle(
                          color: ready
                              ? VaultColors.foreground
                              : VaultColors.faint,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        ready
                            ? '${slot!.modelLabel} (${slot.kind.label}) '
                                'writes the capsule. '
                                'Adds a few seconds.'
                            : 'No model loaded — load one on the Model tab. '
                                'Queries still return a capsule built from '
                                'retrieval alone.',
                        style: const TextStyle(
                          color: VaultColors.faint,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _capsuleCard(ContextCapsule capsule) {
    final generation = capsule.generation;
    return SectionCard(
      title: 'Context capsule',
      subtitle: generation.ran
          ? '${generation.model} · ${generation.backend} · '
              '${generation.elapsedMs ?? 0} ms'
          : 'Retrieval only · ${capsule.retrieval['latency_ms']} ms',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: _showRawJson ? 'Show formatted' : 'Show raw JSON',
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            onPressed: () => setState(() => _showRawJson = !_showRawJson),
            icon: Icon(
              _showRawJson ? Icons.view_agenda_outlined : Icons.data_object,
              color: _showRawJson ? VaultColors.accent : VaultColors.muted,
              size: 20,
            ),
          ),
          IconButton(
            tooltip: 'Copy capsule JSON',
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            onPressed: _copyResults,
            icon: const Icon(Icons.copy_rounded,
                color: VaultColors.muted, size: 20),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ephemeralBanner(),
          _provenanceRow(capsule),
          const SizedBox(height: VaultSpace.md),
          _showRawJson
              ? CodeBlock(capsule.toPrettyJson())
              : _capsuleBody(capsule),
        ],
      ),
    );
  }

  /// Live countdown while a copied capsule is still on the clipboard, then a
  /// one-line outcome. Text carries the state; the bar only reinforces it.
  Widget _ephemeralBanner() {
    return ListenableBuilder(
      listenable: _clipboard,
      builder: (context, _) {
        final active = _clipboard.isActive;
        final outcome = _clipboard.lastOutcome;
        if (!active && outcome == null) return const SizedBox.shrink();

        final (IconData icon, Color color, String text) = active
            ? (
                Icons.lock_clock_outlined,
                VaultColors.accent,
                'Ephemeral buffer active: auto-destructs in '
                    '${_clipboard.secondsRemaining}s',
              )
            : switch (outcome!) {
                ScrubOutcome.cleared => (
                    Icons.check_circle_outline,
                    VaultColors.muted,
                    'Capsule removed from the clipboard.',
                  ),
                ScrubOutcome.replaced => (
                    Icons.info_outline,
                    VaultColors.muted,
                    'Clipboard changed since the copy, so it was left untouched.',
                  ),
                ScrubOutcome.unreadable => (
                    Icons.schedule_rounded,
                    VaultColors.warn,
                    'Clipboard unreadable in the background; will scrub on '
                        'return if unchanged.',
                  ),
                ScrubOutcome.superseded => (
                    Icons.info_outline,
                    VaultColors.muted,
                    'Superseded by a newer copy.',
                  ),
              };
        final reduceMotion = MediaQuery.of(context).disableAnimations;

        return Semantics(
          liveRegion: true,
          label: text,
          child: ExcludeSemantics(
            child: Container(
              margin: const EdgeInsets.only(bottom: VaultSpace.md),
              padding: const EdgeInsets.all(VaultSpace.md),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
                border: Border.all(color: color.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 16, color: color),
                      const SizedBox(width: VaultSpace.sm),
                      Expanded(
                        child: Text(
                          text,
                          style: TextStyle(
                            color: active ? VaultColors.foreground : color,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (active) ...[
                    const SizedBox(height: VaultSpace.sm),
                    TweenAnimationBuilder<double>(
                      tween: Tween(end: _clipboard.fractionRemaining),
                      duration: reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 250),
                      builder: (context, value, _) => LinearProgressIndicator(
                        value: value,
                        minHeight: 3,
                        backgroundColor: VaultColors.surfaceHigh,
                        color: VaultColors.accent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Gate taken and signature state, stated without overclaiming.
  Widget _provenanceRow(ContextCapsule capsule) {
    final p = capsule.provenance;
    final signed = p?.isSigned ?? false;
    final String signature;
    if (p == null) {
      signature = 'Not signed';
    } else if (signed) {
      signature = 'Signed · ${p.enclave}';
    } else if (p.signatureAlgorithm == 'MOCK-UNSIGNED') {
      signature = 'Mock signature (no keystore)';
    } else {
      signature = 'Signing failed · ${p.signatureError ?? "unknown"}';
    }
    return Wrap(
      spacing: VaultSpace.sm,
      runSpacing: VaultSpace.xs,
      children: [
        StatusPill(
          label: switch (capsule.gatingPath) {
            GatingPath.extractiveEarlyExit => 'TIER 1 · EARLY EXIT',
            GatingPath.llmSynthesized => 'TIER 2 · LLM',
            GatingPath.extractiveFallback => 'TIER 2 · EXTRACTIVE',
            GatingPath.belowRelevanceThreshold => 'TIER 3 · NO MATCH',
          },
          color: VaultColors.info,
        ),
        StatusPill(
          label: signature.toUpperCase(),
          color: signed ? VaultColors.accent : VaultColors.warn,
        ),
      ],
    );
  }

  Widget _capsuleBody(ContextCapsule capsule) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _answerBlock(capsule),
        if (capsule.keyFacts.isNotEmpty) ...[
          const SizedBox(height: VaultSpace.lg),
          _label('KEY FACTS'),
          const SizedBox(height: VaultSpace.sm),
          for (final fact in capsule.keyFacts) _factTile(fact),
        ],
        if (capsule.caveats.isNotEmpty) ...[
          const SizedBox(height: VaultSpace.lg),
          _label('CAVEATS'),
          const SizedBox(height: VaultSpace.sm),
          for (final caveat in capsule.caveats)
            Padding(
              padding: const EdgeInsets.only(bottom: VaultSpace.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Icon(Icons.info_outline,
                        size: 12, color: VaultColors.faint),
                  ),
                  const SizedBox(width: VaultSpace.sm),
                  Expanded(
                    child: Text(
                      caveat,
                      style: const TextStyle(
                        color: VaultColors.faint,
                        fontSize: 11.5,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
        if (capsule.generation.parseError != null) ...[
          const SizedBox(height: VaultSpace.md),
          Container(
            padding: const EdgeInsets.all(VaultSpace.md),
            decoration: BoxDecoration(
              color: VaultColors.warn.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
              border:
                  Border.all(color: VaultColors.warn.withValues(alpha: 0.3)),
            ),
            child: Text(
              capsule.generation.parseError!,
              style: const TextStyle(
                color: VaultColors.muted,
                fontSize: 11,
                height: 1.45,
              ),
            ),
          ),
        ],
        const SizedBox(height: VaultSpace.lg),
        _label('RETRIEVED CONTEXT'),
        const SizedBox(height: VaultSpace.sm),
        if (capsule.context.isEmpty &&
            capsule.gatingPath == GatingPath.belowRelevanceThreshold)
          const EmptyState(
            icon: Icons.search_off_rounded,
            title: 'Below the relevance threshold',
            message: 'No chunk scored high enough to quote. Low-scoring text '
                'is left out of the capsule on purpose.',
          )
        else if (capsule.context.isEmpty)
          const EmptyState(
            icon: Icons.inbox_outlined,
            title: 'Nothing indexed yet',
            message: 'Add files above, then ask again.',
          )
        else
          for (final chunk in capsule.context) _chunkTile(chunk),
      ],
    );
  }

  Widget _label(String text) => Text(
        text,
        style: const TextStyle(
          color: VaultColors.muted,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      );

  Widget _answerBlock(ContextCapsule capsule) {
    final generated =
        capsule.generation.ran && capsule.generation.parseError == null;
    final color = switch (capsule.confidence) {
      CapsuleConfidence.high => VaultColors.accent,
      CapsuleConfidence.medium => VaultColors.info,
      CapsuleConfidence.low => VaultColors.warn,
      CapsuleConfidence.none => VaultColors.faint,
    };

    return Container(
      padding: const EdgeInsets.all(VaultSpace.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                generated ? Icons.auto_awesome : Icons.format_quote_rounded,
                size: 14,
                color: color,
              ),
              const SizedBox(width: VaultSpace.sm),
              Text(
                generated ? 'GENERATED' : 'EXTRACTED',
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const Spacer(),
              Text(
                'confidence ${capsule.confidence.name}',
                style: const TextStyle(
                  color: VaultColors.faint,
                  fontSize: 10,
                ),
              ),
            ],
          ),
          const SizedBox(height: VaultSpace.sm),
          SelectableText(
            capsule.answer,
            style: TextStyle(
              color: VaultColors.foreground,
              fontSize: 13.5,
              height: 1.55,
              fontFamily: generated ? null : 'monospace',
            ),
          ),
          // Both provenance lines matter, for opposite reasons: a generated
          // answer is prose a model wrote and needs the caveat, while an
          // extracted one is a verbatim quote and needs to say so to be
          // trusted at all.
          const SizedBox(height: VaultSpace.sm),
          Text(
            generated
                ? 'Written by the on-device model from the context below. '
                    'Facts it quotes are checked against that context — see '
                    'the badges underneath.'
                : 'Quoted verbatim from the indexed file. No model wrote '
                    'this.',
            style: const TextStyle(
              color: VaultColors.faint,
              fontSize: 10.5,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _factTile(CapsuleFact fact) {
    return Padding(
      padding: const EdgeInsets.only(bottom: VaultSpace.sm),
      child: Container(
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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    fact.fact,
                    style: const TextStyle(
                      color: VaultColors.foreground,
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                  ),
                ),
                const SizedBox(width: VaultSpace.sm),
                // The quote either occurs in the retrieved text or it does
                // not. This badge is a substring check, not a judgement, so
                // "in source" means exactly one thing.
                _verifyBadge(fact.verified),
              ],
            ),
            if (fact.verbatim != null) ...[
              const SizedBox(height: VaultSpace.sm),
              CodeBlock(fact.verbatim!, maxLines: 3),
            ],
            if (fact.source != null) ...[
              const SizedBox(height: VaultSpace.xs),
              Text(
                fact.source!,
                style: const TextStyle(
                  color: VaultColors.faint,
                  fontSize: 10,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _verifyBadge(bool verified) {
    final color = verified ? VaultColors.accent : VaultColors.warn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            verified ? Icons.verified_outlined : Icons.help_outline,
            size: 11,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            verified ? 'in source' : 'not found',
            style: TextStyle(
              color: color,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chunkTile(RetrievedChunk chunk) {
    final preview = chunk.content.length > 260
        ? '${chunk.content.substring(0, 260)}…'
        : chunk.content;

    return Padding(
      padding: const EdgeInsets.only(bottom: VaultSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  chunk.fileName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: VaultColors.foreground,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: VaultSpace.sm),
              Text(
                chunk.score.toStringAsFixed(3),
                style: VaultText.mono.copyWith(
                  color: VaultColors.info,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
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
