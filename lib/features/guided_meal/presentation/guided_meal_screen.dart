import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/presentation/bloc/bulk_add_bloc.dart';
import 'package:opennutritracker/features/add_meal/util/meal_photo_encoder.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_entities.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_service.dart';
import 'package:opennutritracker/features/guided_meal/presentation/guided_connection_test_dialog.dart';
import 'package:opennutritracker/features/guided_meal/presentation/guided_meal_cubit.dart';
import 'package:opennutritracker/features/guided_meal/presentation/guided_result_view.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// What the guided flow hands back to the screen that opened it.
class GuidedMealResult {
  final GuidedEstimate estimate;

  const GuidedMealResult(this.estimate);
}

/// Photo and note in, a few multiple-choice questions, foods with weights out.
///
/// It never logs anything itself. The estimate goes back to the multi-item
/// add screen, which resolves it against the food databases and shows the
/// same review step every other way of adding a meal ends in.
class GuidedMealScreen extends StatelessWidget {
  const GuidedMealScreen({super.key});

  static Future<GuidedMealResult?> open(BuildContext context) =>
      Navigator.of(context).push<GuidedMealResult>(
        MaterialPageRoute(builder: (_) => const GuidedMealScreen()),
      );

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => GuidedMealCubit(locator<GuidedMealService>()),
    child: const _GuidedMealView(),
  );
}

class _GuidedMealView extends StatefulWidget {
  const _GuidedMealView();

  @override
  State<_GuidedMealView> createState() => _GuidedMealViewState();
}

class _GuidedMealViewState extends State<_GuidedMealView> {
  static final _log = Logger('GuidedMealScreen');

  final _noteController = TextEditingController();
  late final Future<GuidedDestination?> _destination =
      locator<GuidedMealService>().destination();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  String get _localeCode => Localizations.localeOf(context).languageCode;

  void _testConnection() =>
      showGuidedConnectionTest(context, locator<GuidedMealService>());

  Future<void> _pick(ImageSource source, GuidedDestination destination) async {
    final cubit = context.read<GuidedMealCubit>();
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: source);
    } catch (e, stackTrace) {
      _log.warning('Opening the photo picker failed', e, stackTrace);
      if (mounted) cubit.reportPhotoFailure(BulkAddPhotoError.camera);
      return;
    }
    // A cancelled picker is not a failure.
    if (picked == null || !mounted) return;

    final MealPhoto? photo;
    try {
      // Discards the picker's cache copy once encoded, so the app leaves no
      // copy of the photo on disk.
      photo = await MealPhotoEncoder.encodeAndDiscardSource(
        picked.path,
        format: MealPhotoFormat.forProvider(destination.provider),
      );
    } catch (e, stackTrace) {
      // Never logged with the path: it can carry the original file name.
      _log.warning('Encoding the meal photo failed', e, stackTrace);
      if (mounted) cubit.reportPhotoFailure(BulkAddPhotoError.unreadable);
      return;
    }
    if (!mounted) return;
    if (photo == null) {
      cubit.reportPhotoFailure(BulkAddPhotoError.unreadable);
      return;
    }
    cubit.setPhoto(photo);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.guidedMealTitle)),
      body: SafeArea(
        child: BlocBuilder<GuidedMealCubit, GuidedMealState>(
          builder: (context, state) => switch (state) {
            GuidedInputState() => _buildInput(context, state),
            GuidedBusyState() => _buildBusy(context, state),
            GuidedQuestionsState() => _buildQuestions(context, state),
            GuidedFailedState() => _buildFailed(context, state),
            GuidedDoneState() => _buildDone(context, state),
          },
        ),
      ),
    );
  }

  // ---- Done ----------------------------------------------------------------

  Widget _buildDone(BuildContext context, GuidedDoneState state) {
    final cubit = context.read<GuidedMealCubit>();
    return GuidedResultView(
      estimate: state.estimate,
      verdict: state.verdict,
      photo: cubit.photo,
      onSubmitSecondOpinion: (text) => cubit.decide(
        secondOpinion: text,
        unknownLabel: S.of(context).guidedMealUnknownOption,
        localeCode: _localeCode,
      ),
      buildPrompt: () => cubit.secondOpinionPrompt(
        languageCode: _localeCode,
        unknownLabel: S.of(context).guidedMealUnknownOption,
      ),
      onContinue: () =>
          Navigator.of(context).pop(GuidedMealResult(state.estimate)),
    );
  }

  // ---- Input ---------------------------------------------------------------

  Widget _buildInput(BuildContext context, GuidedInputState state) {
    final s = S.of(context);
    final theme = Theme.of(context);
    return FutureBuilder<GuidedDestination?>(
      future: _destination,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final destination = snapshot.data;
        if (destination == null) {
          return _message(context, s.bulkAddPhotoUnavailableLabel);
        }
        final photo = state.photo;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(s.guidedMealIntro, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            if (photo != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Image.memory(photo.bytes, fit: BoxFit.cover),
                ),
              ),
            if (photo != null) const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    identifier: 'guided-meal-camera',
                    child: FilledButton.tonalIcon(
                      onPressed: () => _pick(ImageSource.camera, destination),
                      icon: const Icon(Icons.photo_camera_rounded),
                      label: Text(s.guidedMealTakePhoto),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    identifier: 'guided-meal-gallery',
                    child: OutlinedButton.icon(
                      onPressed: () => _pick(ImageSource.gallery, destination),
                      icon: const Icon(Icons.photo_library_rounded),
                      label: Text(s.guidedMealPickPhoto),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Semantics(
              identifier: 'guided-meal-note',
              child: TextField(
                controller: _noteController,
                minLines: 2,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                onChanged: context.read<GuidedMealCubit>().setNote,
                decoration: InputDecoration(
                  labelText: s.guidedMealNoteLabel,
                  hintText: s.guidedMealNoteHint,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '${_disclosure(s, destination)} '
              '${s.bulkAddPhotoDisclosureCommon}\n'
              '${s.guidedMealDisclosureTwice}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Semantics(
              identifier: 'guided-meal-start',
              child: FilledButton(
                onPressed: photo == null
                    ? null
                    : () => context.read<GuidedMealCubit>().analyze(
                        localeCode: _localeCode,
                      ),
                child: Text(s.guidedMealStartAction),
              ),
            ),
            TextButton(
              onPressed: _testConnection,
              child: Text(s.guidedMealTestConnection),
            ),
          ],
        );
      },
    );
  }

  /// Names where the photo goes. One exhaustive site, like the settings
  /// disclosure, so a new provider cannot silently inherit another's text.
  String _disclosure(S s, GuidedDestination destination) =>
      switch (destination.provider) {
        AiProvider.anthropic => s.bulkAddPhotoDisclosureAnthropic,
        AiProvider.openrouter => s.bulkAddPhotoDisclosureOpenRouter(
          destination.name,
        ),
        AiProvider.openai => s.bulkAddPhotoDisclosureOpenAI,
        AiProvider.gemini => s.bulkAddPhotoDisclosureGemini,
        AiProvider.chatgpt => s.bulkAddPhotoDisclosureChatGpt,
        AiProvider.ownServer => s.bulkAddPhotoDisclosureOwnServer(
          destination.name,
        ),
      };

  // ---- Busy ----------------------------------------------------------------

  Widget _buildBusy(BuildContext context, GuidedBusyState state) {
    final s = S.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(switch (state.step) {
              GuidedStep.analyzing => s.guidedMealAnalyzing,
              GuidedStep.estimating => s.guidedMealEstimating,
              GuidedStep.deciding => s.guidedMealDeciding,
            }, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            TextButton(
              onPressed: context.read<GuidedMealCubit>().cancel,
              child: Text(s.guidedMealCancelAction),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Questions -----------------------------------------------------------

  Widget _buildQuestions(BuildContext context, GuidedQuestionsState state) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final cubit = context.read<GuidedMealCubit>();
    final analysis = state.analysis;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (analysis.summary.isNotEmpty) ...[
                Text(
                  s.guidedMealSummaryLabel,
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Text(analysis.summary, style: theme.textTheme.titleMedium),
                const SizedBox(height: 16),
              ],
              if (analysis.questions.isEmpty)
                Text(
                  s.guidedMealNoQuestions,
                  style: theme.textTheme.bodyMedium,
                ),
              for (final question in analysis.questions)
                _buildQuestion(context, cubit, question, state),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!state.allAnswered)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    s.guidedMealAnswerAll,
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
              Semantics(
                identifier: 'guided-meal-estimate',
                child: FilledButton(
                  onPressed: state.allAnswered
                      ? () => cubit.estimate(
                          unknownLabel: s.guidedMealUnknownOption,
                          localeCode: _localeCode,
                        )
                      : null,
                  child: Text(s.guidedMealEstimateAction),
                ),
              ),
              TextButton(
                onPressed: cubit.restart,
                child: Text(s.guidedMealRestartAction),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildQuestion(
    BuildContext context,
    GuidedMealCubit cubit,
    GuidedQuestion question,
    GuidedQuestionsState state,
  ) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final answer = state.answers[question.id];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(question.text, style: theme.textTheme.titleSmall),
              if (question.multiSelect)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    s.guidedMealMultiHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in question.options)
                    if (question.multiSelect)
                      FilterChip(
                        label: Text(option.label),
                        selected:
                            answer?.optionIds.contains(option.id) ?? false,
                        onSelected: (_) =>
                            cubit.selectOption(question, option.id),
                      )
                    else
                      ChoiceChip(
                        label: Text(option.label),
                        selected:
                            answer?.optionIds.contains(option.id) ?? false,
                        onSelected: (_) =>
                            cubit.selectOption(question, option.id),
                      ),
                  // The app's own choice on every question, so no model has
                  // to offer one and none can leave it out.
                  ChoiceChip(
                    label: Text(s.guidedMealUnknownOption),
                    selected: answer?.unknown ?? false,
                    onSelected: (_) => cubit.selectUnknown(question),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Failed --------------------------------------------------------------

  Widget _buildFailed(BuildContext context, GuidedFailedState state) {
    final s = S.of(context);
    final cubit = context.read<GuidedMealCubit>();
    final text = switch (state.error) {
      BulkAddPhotoError.unavailable => s.bulkAddPhotoUnavailableLabel,
      BulkAddPhotoError.auth => s.bulkAddPhotoKeyRejectedLabel,
      BulkAddPhotoError.transient =>
        state.overloaded
            ? s.guidedMealOverloaded
            : state.timedOut
            ? s.guidedMealTimedOut
            : s.bulkAddPhotoFailedLabel,
      BulkAddPhotoError.camera => s.bulkAddPhotoCameraFailedLabel,
      BulkAddPhotoError.unreadable => s.bulkAddPhotoUnreadableLabel,
      BulkAddPhotoError.unsupported => s.bulkAddPhotoUnsupportedLabel,
      BulkAddPhotoError.insecureDestination =>
        s.bulkAddModelInsecureServerLabel,
      BulkAddPhotoError.billing => s.bulkAddPhotoNoCreditLabel,
    };
    // Worth another try only where the failure can clear on its own.
    final retryable = state.error == BulkAddPhotoError.transient;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            if (retryable)
              FilledButton(
                onPressed: () => switch (state.step) {
                  GuidedStep.analyzing => cubit.analyze(
                    localeCode: _localeCode,
                  ),
                  GuidedStep.estimating => cubit.estimate(
                    unknownLabel: s.guidedMealUnknownOption,
                    localeCode: _localeCode,
                  ),
                  GuidedStep.deciding => cubit.retryDecision(
                    unknownLabel: s.guidedMealUnknownOption,
                    localeCode: _localeCode,
                  ),
                },
                child: Text(s.guidedMealRetryAction),
              ),
            TextButton(
              onPressed: cubit.dismissFailure,
              child: Text(s.guidedMealBackAction),
            ),
            TextButton(
              onPressed: _testConnection,
              child: Text(s.guidedMealTestConnection),
            ),
          ],
        ),
      ),
    );
  }

  Widget _message(BuildContext context, String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}
