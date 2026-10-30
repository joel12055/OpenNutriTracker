import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_entities.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_schemas.dart';
import 'package:opennutritracker/generated/l10n.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// What the model made of the meal, before it goes to the review screen: the
/// foods with weights, how sure it was about each, and a way to have the
/// doubtful ones checked in an assistant the person already pays for.
///
/// Nothing is sent from here. [buildPrompt] returns text and the person
/// carries it to Claude, ChatGPT or Gemini themselves.
class GuidedResultView extends StatefulWidget {
  final GuidedEstimate estimate;
  final MealPhoto? photo;

  /// The second-opinion prompt for the current estimate.
  final String Function() buildPrompt;
  final VoidCallback onContinue;

  /// Hands the text of a second opinion, pasted in by the person, to the flow
  /// for the final decision.
  final void Function(String secondOpinion) onSubmitSecondOpinion;

  /// What the model said it decided, once a second opinion was weighed.
  final String? verdict;

  /// The assistant whose automatic second opinion went into this result.
  final String? secondOpinionBy;

  /// A second opinion was due and did not come.
  final bool secondOpinionFailed;

  const GuidedResultView({
    super.key,
    required this.estimate,
    required this.photo,
    required this.buildPrompt,
    required this.onContinue,
    required this.onSubmitSecondOpinion,
    this.verdict,
    this.secondOpinionBy,
    this.secondOpinionFailed = false,
  });

  @override
  State<GuidedResultView> createState() => _GuidedResultViewState();
}

class _GuidedResultViewState extends State<GuidedResultView> {
  static final _log = Logger('GuidedResultView');

  /// The one place a copy of the photo reaches disk, and only because the
  /// person asked to share it. Removed when this screen goes away.
  File? _sharedPhoto;

  @override
  void dispose() {
    try {
      _sharedPhoto?.deleteSync();
    } catch (_) {
      // Best effort: the OS clears the cache directory in the end.
    }
    super.dispose();
  }

  String _confidenceLabel(S s, GuidedConfidence confidence) =>
      switch (confidence) {
        GuidedConfidence.high => s.guidedMealConfidenceSure,
        GuidedConfidence.medium => s.guidedMealConfidenceRoughly,
        GuidedConfidence.low => s.guidedMealConfidenceUnsure,
      };

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final estimate = widget.estimate;
    final total = estimate.totalKcal;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                s.guidedMealResultHeading,
                style: theme.textTheme.titleMedium,
              ),
              if (total != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    s.guidedMealTotalLine(total.round().toString()),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              const SizedBox(height: 12),
              if (widget.secondOpinionFailed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    s.guidedMealSecondFailed,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              if (widget.verdict != null || widget.secondOpinionBy != null)
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  color: theme.colorScheme.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.guidedMealVerdictHeading,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (widget.verdict != null)
                          Text(
                            widget.verdict!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSecondaryContainer,
                            ),
                          ),
                        if (widget.secondOpinionBy != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              s.guidedMealSecondBy(widget.secondOpinionBy!),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              // After a decision the banner would invite a second opinion the
              // person has just had.
              if (estimate.isUncertain && widget.verdict == null)
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  color: theme.colorScheme.tertiaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.help_outline_rounded,
                          color: theme.colorScheme.onTertiaryContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            s.guidedMealUncertainBanner,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onTertiaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              for (final item in estimate.items) _buildItem(context, item),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                identifier: 'guided-meal-continue',
                child: FilledButton(
                  onPressed: widget.onContinue,
                  child: Text(s.guidedMealContinueAction),
                ),
              ),
              const SizedBox(height: 8),
              Semantics(
                identifier: 'guided-meal-second-opinion',
                // Stronger when the model itself said it was unsure.
                child: estimate.isUncertain
                    ? FilledButton.tonalIcon(
                        onPressed: _openSecondOpinion,
                        icon: const Icon(Icons.fact_check_rounded),
                        label: Text(s.guidedMealSecondOpinionAction),
                      )
                    : TextButton.icon(
                        onPressed: _openSecondOpinion,
                        icon: const Icon(Icons.fact_check_outlined),
                        label: Text(s.guidedMealSecondOpinionAction),
                      ),
              ),
              Semantics(
                identifier: 'guided-meal-paste-opinion',
                child: TextButton.icon(
                  onPressed: _openPaste,
                  icon: const Icon(Icons.content_paste_go_rounded),
                  label: Text(s.guidedMealPasteAction),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildItem(BuildContext context, GuidedEstimateItem item) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final unsure = item.confidence == GuidedConfidence.low;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(item.name, style: theme.textTheme.titleSmall),
                ),
                const SizedBox(width: 8),
                Text(
                  '${item.grams.round()} g',
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _confidenceLabel(s, item.confidence),
              style: theme.textTheme.labelMedium?.copyWith(
                color: unsure
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (item.basis != null)
              Text(item.basis!, style: theme.textTheme.bodySmall),
            if (item.doubt != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  item.doubt!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- Second opinion ------------------------------------------------------

  Future<void> _openSecondOpinion() async {
    final prompt = widget.buildPrompt();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _SecondOpinionSheet(
        prompt: prompt,
        hasPhoto: widget.photo != null,
        onCopy: () async {
          final messenger = ScaffoldMessenger.of(context);
          final message = S.of(context).guidedMealPromptCopied;
          await Clipboard.setData(ClipboardData(text: prompt));
          if (sheetContext.mounted) Navigator.of(sheetContext).pop();
          messenger.showSnackBar(SnackBar(content: Text(message)));
        },
        onShare: () => _share(prompt),
      ),
    );
  }

  /// Opens the sheet where the answer of another assistant is pasted in.
  Future<void> _openPaste() async {
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _PasteSheet(),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    widget.onSubmitSecondOpinion(text);
  }

  /// Hands prompt and photo to the system share sheet, so the person can
  /// pick Claude, ChatGPT or Gemini and land in a new chat with both attached.
  Future<void> _share(String prompt) async {
    final photo = widget.photo;
    File? file;
    if (photo != null) {
      try {
        final directory = await getTemporaryDirectory();
        final extension = photo.mediaType == 'image/jpeg' ? 'jpg' : 'webp';
        file = File(
          '${directory.path}/meal_photo_for_second_opinion.$extension',
        );
        await file.writeAsBytes(photo.bytes, flush: true);
        _sharedPhoto = file;
      } catch (e, stackTrace) {
        _log.warning('Could not write the photo for sharing', e, stackTrace);
        file = null;
      }
    }
    await SharePlus.instance.share(
      ShareParams(
        text: prompt,
        files: file == null ? null : [XFile(file.path)],
      ),
    );
  }
}

class _SecondOpinionSheet extends StatelessWidget {
  final String prompt;
  final bool hasPhoto;
  final Future<void> Function() onCopy;
  final Future<void> Function() onShare;

  const _SecondOpinionSheet({
    required this.prompt,
    required this.hasPhoto,
    required this.onCopy,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                s.guidedMealSecondOpinionTitle,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                s.guidedMealSecondOpinionIntro,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              // The person sees exactly what would be pasted, so nothing
              // leaves their hands unread.
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(s.guidedMealPromptPreview),
                children: [
                  Container(
                    constraints: const BoxConstraints(maxHeight: 280),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        prompt,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Semantics(
                identifier: 'guided-meal-copy-prompt',
                child: FilledButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy_rounded),
                  label: Text(s.guidedMealCopyPromptAction),
                ),
              ),
              const SizedBox(height: 8),
              Semantics(
                identifier: 'guided-meal-share-prompt',
                child: FilledButton.tonalIcon(
                  onPressed: onShare,
                  icon: const Icon(Icons.ios_share_rounded),
                  label: Text(
                    hasPhoto
                        ? s.guidedMealSharePromptAction
                        : s.guidedMealShareTextAction,
                  ),
                ),
              ),
              if (hasPhoto)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    s.guidedMealSharePhotoNote,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The place a second opinion is pasted into, and the one button that sends
/// it on for the final decision.
class _PasteSheet extends StatefulWidget {
  const _PasteSheet();

  @override
  State<_PasteSheet> createState() => _PasteSheetState();
}

class _PasteSheetState extends State<_PasteSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;
    setState(() {
      _controller.text = text.length > maxSecondOpinionChars
          ? text.substring(0, maxSecondOpinionChars)
          : text;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        // Keeps the sheet above the keyboard.
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(s.guidedMealPasteTitle, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(s.guidedMealPasteIntro, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
              Semantics(
                identifier: 'guided-meal-paste-field',
                child: TextField(
                  controller: _controller,
                  minLines: 5,
                  maxLines: 9,
                  maxLength: maxSecondOpinionChars,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: s.guidedMealPasteHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _pasteFromClipboard,
                  icon: const Icon(Icons.content_paste_rounded),
                  label: Text(s.guidedMealPasteFromClipboard),
                ),
              ),
              Text(
                s.guidedMealDecideNote,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                identifier: 'guided-meal-decide',
                child: FilledButton(
                  onPressed: _controller.text.trim().isEmpty
                      ? null
                      : () => Navigator.of(context).pop(_controller.text),
                  child: Text(s.guidedMealDecideAction),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
