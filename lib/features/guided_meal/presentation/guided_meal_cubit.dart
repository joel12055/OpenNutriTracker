import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/presentation/bloc/bulk_add_bloc.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_entities.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_service.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_review.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_second_provider.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_second_opinion_prompt.dart';

/// Which of the two model calls a busy or failed state is about.
enum GuidedStep { analyzing, estimating, reviewing, deciding }

sealed class GuidedMealState extends Equatable {
  const GuidedMealState();

  @override
  List<Object?> get props => [];
}

/// Picking a photo and writing the optional note.
class GuidedInputState extends GuidedMealState {
  final MealPhoto? photo;
  final String note;

  const GuidedInputState({this.photo, this.note = ''});

  @override
  List<Object?> get props => [photo, note];
}

/// A model call is in flight.
class GuidedBusyState extends GuidedMealState {
  final GuidedStep step;

  /// Who is being asked, for the step that asks someone else.
  final String? detail;

  const GuidedBusyState(this.step, {this.detail});

  @override
  List<Object?> get props => [step, detail];
}

/// The model's questions, with what the user has answered so far.
class GuidedQuestionsState extends GuidedMealState {
  final GuidedAnalysis analysis;
  final Map<String, GuidedAnswer> answers;

  const GuidedQuestionsState(this.analysis, this.answers);

  bool get allAnswered => analysis.questions.every(
    (question) => answers[question.id]?.isAnswered ?? false,
  );

  @override
  List<Object?> get props => [analysis, answers];
}

/// A model call failed. [error] reuses the photo reader's vocabulary, so the
/// screen can show the sentences the app already has for each failure.
class GuidedFailedState extends GuidedMealState {
  final BulkAddPhotoError error;
  final GuidedStep step;

  /// The provider did not answer in time. Folded into
  /// [BulkAddPhotoError.transient] for retrying, but worth its own sentence:
  /// "check your connection" is wrong advice for a model that is merely slow.
  final bool timedOut;

  /// The provider answered with an overload or a rate limit, after every model
  /// it could try. Also folded into [BulkAddPhotoError.transient], and also
  /// not a connection problem: the request got there and was turned away.
  final bool overloaded;

  const GuidedFailedState(
    this.error,
    this.step, {
    this.timedOut = false,
    this.overloaded = false,
  });

  @override
  List<Object?> get props => [error, step, timedOut, overloaded];
}

/// Finished: the foods and weights the answers add up to.
class GuidedDoneState extends GuidedMealState {
  final GuidedEstimate estimate;

  /// What the model said it decided after a second opinion, or null while the
  /// estimate is still the first one.
  final String? verdict;

  /// The assistant whose second opinion was fetched automatically and
  /// weighed into [estimate], if one was.
  final String? secondOpinionBy;

  /// A second opinion was due and did not come; [estimate] is the first one.
  final bool secondOpinionFailed;

  const GuidedDoneState(
    this.estimate, {
    this.verdict,
    this.secondOpinionBy,
    this.secondOpinionFailed = false,
  });

  @override
  List<Object?> get props => [
    estimate,
    verdict,
    secondOpinionBy,
    secondOpinionFailed,
  ];
}

/// Drives the guided flow: photo and note, then the model's questions, then
/// the estimate.
///
/// The photo lives here, in memory, for as long as the screen does. It is
/// sent twice — once to ask, once to estimate — because neither call keeps a
/// conversation, and it is never written anywhere.
class GuidedMealCubit extends Cubit<GuidedMealState> {
  static final _log = Logger('GuidedMealCubit');

  final GuidedMealService _service;

  MealPhoto? _photo;
  String _note = '';
  GuidedAnalysis? _analysis;
  Map<String, GuidedAnswer> _answers = const {};

  /// The estimate on screen and the verdict that came with it, kept so a
  /// failed decision can go back to them.
  GuidedEstimate? _estimate;
  String? _verdict;

  /// The pasted text of the last decision, for trying it again.
  String _secondOpinion = '';

  /// Bumped by every call and by leaving a state, so a reply that lands after
  /// the user went back is dropped instead of overwriting where they are.
  int _attempt = 0;

  GuidedMealCubit(this._service) : super(const GuidedInputState());

  /// The photo, for sharing it with a second opinion. Held in memory only.
  MealPhoto? get photo => _photo;

  /// The text to paste into Claude, ChatGPT or Gemini for a second opinion on
  /// the estimate on screen, with everything the flow learned.
  String secondOpinionPrompt({
    required String languageCode,
    required String unknownLabel,
  }) {
    final current = state;
    final analysis = _analysis;
    if (current is! GuidedDoneState || analysis == null) return '';
    return guidedSecondOpinionPrompt(
      languageCode: languageCode,
      note: _note,
      analysis: analysis,
      answers: _answers,
      estimate: current.estimate,
      unknownLabel: unknownLabel,
    );
  }

  void setPhoto(MealPhoto? photo) {
    _photo = photo;
    emit(GuidedInputState(photo: _photo, note: _note));
  }

  void setNote(String note) {
    _note = note;
    // No emit: the field owns its text, and rebuilding the screen on every
    // keystroke would only fight the keyboard.
  }

  void reportPhotoFailure(BulkAddPhotoError error) =>
      emit(GuidedFailedState(error, GuidedStep.analyzing));

  Future<void> analyze({String? localeCode}) async {
    final photo = _photo;
    if (photo == null) return;
    final attempt = ++_attempt;
    emit(const GuidedBusyState(GuidedStep.analyzing));
    try {
      final analysis = await _service.analyze(
        photo: photo,
        note: _note,
        localeCode: localeCode,
      );
      if (isClosed || attempt != _attempt) return;
      _analysis = analysis;
      _answers = const {};
      _estimate = null;
      _verdict = null;
      emit(GuidedQuestionsState(analysis, _answers));
    } catch (e, stackTrace) {
      _fail(e, stackTrace, GuidedStep.analyzing, attempt);
    }
  }

  void selectOption(GuidedQuestion question, String optionId) {
    final current = _answers[question.id];
    final Set<String> picked;
    if (question.multiSelect) {
      picked = {...?current?.optionIds};
      if (!picked.add(optionId)) picked.remove(optionId);
    } else {
      picked = {optionId};
    }
    _setAnswer(GuidedAnswer(questionId: question.id, optionIds: picked));
  }

  void selectUnknown(GuidedQuestion question) =>
      _setAnswer(GuidedAnswer(questionId: question.id, unknown: true));

  void _setAnswer(GuidedAnswer answer) {
    final analysis = _analysis;
    if (analysis == null) return;
    _answers = {..._answers, answer.questionId: answer};
    emit(GuidedQuestionsState(analysis, _answers));
  }

  Future<void> estimate({
    required String unknownLabel,
    String? localeCode,
  }) async {
    final photo = _photo;
    final analysis = _analysis;
    if (photo == null || analysis == null) return;
    final attempt = ++_attempt;
    emit(const GuidedBusyState(GuidedStep.estimating));
    final GuidedEstimate estimate;
    try {
      estimate = await _service.estimate(
        photo: photo,
        analysis: analysis,
        answers: _answers,
        unknownLabel: unknownLabel,
        note: _note,
        localeCode: localeCode,
      );
    } catch (e, stackTrace) {
      _fail(e, stackTrace, GuidedStep.estimating, attempt);
      return;
    }
    if (isClosed || attempt != _attempt) return;
    _estimate = estimate;
    _verdict = null;
    await _afterEstimate(
      estimate,
      attempt,
      photo: photo,
      analysis: analysis,
      unknownLabel: unknownLabel,
      localeCode: localeCode,
    );
  }

  /// Ends the estimate step: either the result as it is, or — when the person
  /// turned the automatic second opinion on and this estimate calls for one —
  /// a second assistant checks it and the first weighs the two.
  ///
  /// Never fails the flow. The estimate the person already has is worth more
  /// than a second opinion that did not come, so any trouble here ends in that
  /// estimate with a note, not in an error screen.
  Future<void> _afterEstimate(
    GuidedEstimate estimate,
    int attempt, {
    required MealPhoto photo,
    required GuidedAnalysis analysis,
    required String unknownLabel,
    String? localeCode,
  }) async {
    GuidedSecondary? secondary;
    try {
      final mode = await _service.autoSecondOpinion();
      final wanted =
          mode == AutoSecondOpinion.always ||
          (mode == AutoSecondOpinion.uncertain && estimate.isUncertain);
      if (wanted) secondary = await _service.secondary();
    } catch (e) {
      _log.info(
        'Could not look up the second opinion setting: ${e.runtimeType}',
      );
    }
    if (isClosed || attempt != _attempt) return;
    if (secondary == null) {
      emit(GuidedDoneState(estimate));
      return;
    }

    emit(GuidedBusyState(GuidedStep.reviewing, detail: secondary.name));
    try {
      final review = await _service.review(
        secondary: secondary,
        photo: photo,
        analysis: analysis,
        answers: _answers,
        estimate: estimate,
        unknownLabel: unknownLabel,
        note: _note,
        localeCode: localeCode,
      );
      if (isClosed || attempt != _attempt) return;
      final decision = await _service.decide(
        photo: photo,
        analysis: analysis,
        answers: _answers,
        estimate: estimate,
        secondOpinion: guidedReviewAsSecondOpinion(
          providerName: secondary.name,
          review: review,
        ),
        unknownLabel: unknownLabel,
        note: _note,
        localeCode: localeCode,
      );
      if (isClosed || attempt != _attempt) return;
      _estimate = decision.estimate;
      _verdict = decision.verdict.isEmpty ? null : decision.verdict;
      emit(
        GuidedDoneState(
          decision.estimate,
          verdict: _verdict,
          secondOpinionBy: secondary.name,
        ),
      );
    } catch (e) {
      if (isClosed || attempt != _attempt) return;
      _log.info('Automatic second opinion failed: ${e.runtimeType}');
      emit(GuidedDoneState(estimate, secondOpinionFailed: true));
    }
  }

  /// Weighs the estimate on screen against [secondOpinion], text the person
  /// pasted in from another assistant, and replaces it with the final result.
  Future<void> decide({
    required String secondOpinion,
    required String unknownLabel,
    String? localeCode,
  }) async {
    final photo = _photo;
    final analysis = _analysis;
    final estimate = _estimate;
    if (photo == null || analysis == null || estimate == null) return;
    _secondOpinion = secondOpinion;
    final attempt = ++_attempt;
    emit(const GuidedBusyState(GuidedStep.deciding));
    try {
      final decision = await _service.decide(
        photo: photo,
        analysis: analysis,
        answers: _answers,
        estimate: estimate,
        secondOpinion: secondOpinion,
        unknownLabel: unknownLabel,
        note: _note,
        localeCode: localeCode,
      );
      if (isClosed || attempt != _attempt) return;
      _estimate = decision.estimate;
      _verdict = decision.verdict.isEmpty ? null : decision.verdict;
      emit(GuidedDoneState(decision.estimate, verdict: _verdict));
    } catch (e, stackTrace) {
      _fail(e, stackTrace, GuidedStep.deciding, attempt);
    }
  }

  /// Tries the last decision again with the same pasted text.
  Future<void> retryDecision({
    required String unknownLabel,
    String? localeCode,
  }) => decide(
    secondOpinion: _secondOpinion,
    unknownLabel: unknownLabel,
    localeCode: localeCode,
  );

  /// Leaves a failure for the state it came from: the result the person was
  /// looking at, the questions they had already answered, or the photo and
  /// note they had entered.
  void dismissFailure() {
    _attempt++;
    final analysis = _analysis;
    final estimate = _estimate;
    if (estimate != null) {
      emit(GuidedDoneState(estimate, verdict: _verdict));
    } else if (analysis != null) {
      emit(GuidedQuestionsState(analysis, _answers));
    } else {
      emit(GuidedInputState(photo: _photo, note: _note));
    }
  }

  /// Abandons a call in flight and returns to where it started.
  void cancel() => dismissFailure();

  /// Throws the questions away and goes back to the photo and the note, which
  /// are kept so a different note can be tried on the same picture.
  void restart() {
    _attempt++;
    _analysis = null;
    _answers = const {};
    _estimate = null;
    _verdict = null;
    emit(GuidedInputState(photo: _photo, note: _note));
  }

  void _fail(
    Object error,
    StackTrace stackTrace,
    GuidedStep step,
    int attempt,
  ) {
    if (isClosed || attempt != _attempt) return;
    final BulkAddPhotoError kind;
    var timedOut = false;
    var overloaded = false;
    switch (error) {
      case GuidedUnavailableException():
        kind = BulkAddPhotoError.unavailable;
      case MealInterpreterException(
        :final failure,
        :final reason,
        :final statusCode,
      ):
        _log.info('Guided $step failed: $reason');
        timedOut = failure == MealInterpreterFailure.timeout;
        overloaded = switch (statusCode) {
          429 || 500 || 502 || 503 || 504 => true,
          _ => false,
        };
        kind = switch (failure) {
          MealInterpreterFailure.auth => BulkAddPhotoError.auth,
          MealInterpreterFailure.rejected => BulkAddPhotoError.unreadable,
          MealInterpreterFailure.unsupported => BulkAddPhotoError.unsupported,
          MealInterpreterFailure.billing => BulkAddPhotoError.billing,
          MealInterpreterFailure.insecureDestination =>
            BulkAddPhotoError.insecureDestination,
          MealInterpreterFailure.timeout ||
          MealInterpreterFailure.transient => BulkAddPhotoError.transient,
        };
      default:
        _log.severe('Guided $step failed unexpectedly', error, stackTrace);
        kind = BulkAddPhotoError.transient;
    }
    emit(
      GuidedFailedState(
        kind,
        step,
        timedOut: timedOut,
        overloaded: overloaded && kind == BulkAddPhotoError.transient,
      ),
    );
  }
}
