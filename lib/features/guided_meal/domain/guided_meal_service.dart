import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/core/utils/ai_model_catalogue.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/guided_meal/data/guided_tool_client.dart';
import 'package:opennutritracker/features/guided_meal/data/guided_web_search_client.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_entities.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_prompts.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_schemas.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_review.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_second_provider.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_web_research.dart';

/// No provider is configured, or the feature is switched off.
class GuidedUnavailableException implements Exception {
  const GuidedUnavailableException();

  @override
  String toString() => 'GuidedUnavailableException';
}

/// Who is at the far end of a photo: the provider, and the name the screen
/// gives it — a company for the hosted ones, the address for a server the user
/// runs.
class GuidedDestination {
  final AiProvider provider;
  final String name;

  const GuidedDestination(this.provider, this.name);
}

/// What one model answered to the connection test.
enum GuidedProbeOutcome {
  ok,
  auth,
  billing,
  missing,
  overloaded,
  timeout,
  other,
}

class GuidedProbeResult {
  final String model;
  final GuidedProbeOutcome outcome;
  final int millis;
  final int? statusCode;

  const GuidedProbeResult({
    required this.model,
    required this.outcome,
    required this.millis,
    this.statusCode,
  });
}

/// The model calls of the guided flow.
///
/// All are stateless: the estimate call sends the photo again together with
/// the questions and the answers, so no conversation is kept anywhere and the
/// photo is still never written to disk.
///
/// Every failure surfaces as `MealInterpreterException`, the vocabulary the
/// app's other AI screens already turn into user-facing advice.
class GuidedMealService {
  final AiCredentialStorage _credentials;
  final GuidedToolClient _client;

  /// Null where the web search does not exist at all, as in the tests that
  /// are not about it.
  final GuidedWebSearchClient? _web;

  GuidedMealService(this._credentials, this._client, [this._web]);

  /// The model that would run the web search: the one the person picked for
  /// their ChatGPT plan, whichever provider is in use for the rest. The plan
  /// costs nothing more. Null without a sign-in and a model.
  Future<String?> _webModel() async {
    if (_web == null) return null;
    final model = (await _credentials.selectionFor(
      AiProvider.chatgpt,
    ))?.modelId;
    return model != null && model.isNotEmpty ? model : null;
  }

  /// Whether the person switched the web search on and there is a way to run
  /// it.
  Future<bool> webLookupAvailable() async =>
      await _credentials.readWebLookup() == 'on' && await _webModel() != null;

  /// The company that would get the search queries, or null when the web
  /// search is off or cannot be run. For the screen that has to say where the
  /// queries go.
  Future<String?> webLookupDestination() async =>
      await webLookupAvailable() ? 'OpenAI' : null;

  /// The foods of [estimate] to look up: none unless the web search is
  /// available.
  Future<List<GuidedWebLookup>> webLookupsFor(GuidedEstimate estimate) async {
    final lookups = guidedWebLookups(estimate);
    if (lookups.isEmpty || !await webLookupAvailable()) return const [];
    return lookups;
  }

  /// Searches the web for [lookups]. Only their names and the model's search
  /// queries leave the phone, never the photo.
  Future<GuidedWebResearch> research(List<GuidedWebLookup> lookups) async {
    final web = _web;
    final model = await _webModel();
    if (web == null || model == null) throw const GuidedUnavailableException();
    return web.search(
      modelId: model,
      system: guidedWebSearchSystemPrompt,
      text: guidedWebSearchUserText(lookups),
    );
  }

  /// Where a photo would go, and the name to call it — the same answer the
  /// single-photo reader gives, because both must name the same destination.
  ///
  /// Null when nothing usable is configured. For a server the user runs that
  /// also means no passed photo check, since a model that cannot see would
  /// otherwise be offered a dead end.
  Future<GuidedDestination?> destination() async {
    final provider = await _credentials.activeProvider();
    if (provider == null) return null;
    if (provider == AiProvider.ownServer) {
      final probe = await _credentials.readProbe(provider: provider);
      if (probe.photo != AiCapability.passed) return null;
      final endpoint = await _credentials.readEndpoint(provider: provider);
      final host = endpoint == null
          ? null
          : AiCredentialStorage.displayHost(endpoint);
      return host == null ? null : GuidedDestination(provider, host);
    }
    // No curated list to take a vendor from: a ChatGPT plan is OpenAI.
    if (provider == AiProvider.chatgpt) {
      return GuidedDestination(provider, 'OpenAI');
    }
    final model = AiModelCatalogue.resolve(
      provider,
      await _credentials.readModel(provider: provider),
    );
    return model == null ? null : GuidedDestination(provider, model.servedBy);
  }

  /// The level to ask for: the person's own choice if they made one,
  /// otherwise [automatic], which the step itself decides.
  Future<({String effort, bool chosen})> _reasoning(String automatic) async {
    final level = await _credentials.readReasoningLevel();
    return level == null
        ? (effort: automatic, chosen: false)
        : (effort: level, chosen: true);
  }

  Future<AiSelection> _selection() async {
    final selection = await _credentials.readSelection();
    if (selection == null) throw const GuidedUnavailableException();
    return selection;
  }

  /// Step 1: look at the photo and the note, return what the model wants to
  /// ask.
  Future<GuidedAnalysis> analyze({
    required MealPhoto photo,
    String? note,
    String? localeCode,
  }) async {
    final selection = await _selection();
    final reasoning = await _reasoning('medium');
    final reply = await _client.call(
      selection,
      GuidedToolRequest(
        system: guidedQuestionsPrompt(localeCode: localeCode),
        text: guidedQuestionsUserText(note),
        photo: photo,
        toolName: askQuestionsToolName,
        toolDescription: askQuestionsToolDescription,
        schema: askQuestionsSchema,
        // Choosing the right questions is where a careless read costs most.
        reasoningEffort: reasoning.effort,
        reasoningChosen: reasoning.chosen,
      ),
    );
    return guidedAnalysisFromJson(reply);
  }

  /// Step 2: turn the answers into foods with weights.
  Future<GuidedEstimate> estimate({
    required MealPhoto photo,
    required GuidedAnalysis analysis,
    required Map<String, GuidedAnswer> answers,
    required String unknownLabel,
    String? note,
    String? localeCode,
  }) async {
    final selection = await _selection();
    final reasoning = await _reasoning('high');
    final webLookup = await webLookupAvailable();
    final reply = await _client.call(
      selection,
      GuidedToolRequest(
        system: guidedEstimatePrompt(
          localeCode: localeCode,
          webLookup: webLookup,
        ),
        text: guidedEstimateUserText(
          note: note,
          summary: analysis.summary,
          questions: analysis.questions,
          answers: answers,
          unknownLabel: unknownLabel,
        ),
        photo: photo,
        toolName: estimateMealToolName,
        toolDescription: estimateMealToolDescription,
        schema: estimateMealSchema,
        // Turning answers into weights and energy is the step whose result
        // is logged, so it gets the most thinking.
        reasoningEffort: reasoning.effort,
        reasoningChosen: reasoning.chosen,
      ),
    );
    return guidedEstimateFromJson(reply);
  }

  /// Step 3, after a second opinion: the model weighs its first estimate
  /// against what another assistant said and decides the final result.
  ///
  /// Sends the photo and the answers again, like the estimate, because no
  /// call keeps a conversation. The pasted text is capped and sanitised in
  /// the prompt builder, and the reply is read by the same parser rules as
  /// any estimate plus a verdict.
  ///
  /// [secondOpinion] may be empty when [webResearch], what a web search found,
  /// is what the decision weighs.
  Future<GuidedDecision> decide({
    required MealPhoto photo,
    required GuidedAnalysis analysis,
    required Map<String, GuidedAnswer> answers,
    required GuidedEstimate estimate,
    required String secondOpinion,
    required String unknownLabel,
    String webResearch = '',
    String? note,
    String? localeCode,
  }) async {
    final selection = await _selection();
    final reasoning = await _reasoning('high');
    final reply = await _client.call(
      selection,
      GuidedToolRequest(
        system: guidedDecisionPrompt(
          localeCode: localeCode,
          secondOpinion: secondOpinion.trim().isNotEmpty,
          webResearch: webResearch.trim().isNotEmpty,
        ),
        text: guidedDecisionUserText(
          note: note,
          summary: analysis.summary,
          questions: analysis.questions,
          answers: answers,
          unknownLabel: unknownLabel,
          estimate: estimate,
          secondOpinion: secondOpinion,
          webResearch: webResearch,
        ),
        photo: photo,
        toolName: decideMealToolName,
        toolDescription: decideMealToolDescription,
        schema: decideMealSchema,
        // The last word on what gets logged, so the most thinking.
        reasoningEffort: reasoning.effort,
        reasoningChosen: reasoning.chosen,
      ),
    );
    return guidedDecisionFromJson(reply);
  }

  /// What the person set for the automatic second opinion.
  Future<AutoSecondOpinion> autoSecondOpinion() async =>
      AutoSecondOpinion.fromTag(await _credentials.readAutoSecondOpinion());

  /// The assistant that would give it, or null when no other is usable.
  Future<GuidedSecondary?> secondary() => findSecondaryProvider(_credentials);

  /// The setting and the assistant it would use, for the screen that has to
  /// say where the photo goes. The assistant is only looked up when the
  /// setting is on.
  Future<({AutoSecondOpinion mode, String? name})> secondOpinionPlan() async {
    final mode = await autoSecondOpinion();
    if (mode == AutoSecondOpinion.off) return (mode: mode, name: null);
    return (mode: mode, name: (await secondary())?.name);
  }

  /// A second opinion from [secondary]: it is shown the photo, the answers
  /// and the first estimate and returns its own corrected list.
  Future<GuidedReview> review({
    required GuidedSecondary secondary,
    required MealPhoto photo,
    required GuidedAnalysis analysis,
    required Map<String, GuidedAnswer> answers,
    required GuidedEstimate estimate,
    required String unknownLabel,
    String? note,
    String? localeCode,
  }) async {
    final reasoning = await _reasoning('high');
    final reply = await _client.call(
      secondary.selection,
      GuidedToolRequest(
        system: guidedReviewPrompt(localeCode: localeCode),
        text: guidedReviewUserText(
          note: note,
          summary: analysis.summary,
          questions: analysis.questions,
          answers: answers,
          unknownLabel: unknownLabel,
          estimate: estimate,
        ),
        photo: photo,
        toolName: reviewMealToolName,
        toolDescription: reviewMealToolDescription,
        schema: reviewMealSchema,
        reasoningEffort: reasoning.effort,
        reasoningChosen: reasoning.chosen,
      ),
    );
    return guidedReviewFromJson(reply);
  }

  /// Asks every model this provider would be tried with one tiny question, no
  /// photo, and reports how each answered and how fast.
  ///
  /// For telling a dead connection from a bad key from a model that is down
  /// or silent, without anyone reading logs. Runs the models side by side, so
  /// the test lasts as long as the slowest wait rather than their sum.
  ///
  /// With the web search on, the model that searches is asked too, with the
  /// search tool: a working connection says nothing about the tool.
  Future<List<GuidedProbeResult>> testConnection() async {
    final selection = await _selection();
    final models = _client.modelsFor(selection);
    final web = _web;
    final webModel = web != null && await webLookupAvailable()
        ? await _webModel()
        : null;
    return Future.wait([
      ...models.map((model) => _probe(selection, model)),
      if (web != null && webModel != null)
        _probeCall(
          '$webModel + web',
          () => web.search(
            modelId: webModel,
            system: 'Answer in one short sentence. Use web search.',
            text: 'How many kcal per 100 g does a raw banana have?',
            timeoutOverride: _webProbeTimeout,
          ),
        ),
    ]);
  }

  static const _probeTimeout = Duration(seconds: 20);

  /// A search reads pages before it answers, so it is given longer than a
  /// question that is answered from the model alone.
  static const _webProbeTimeout = Duration(seconds: 60);

  Future<GuidedProbeResult> _probe(AiSelection selection, String model) =>
      _probeCall(model, () async {
        await _client.call(
          selection,
          const GuidedToolRequest(
            system: 'Answer by calling the tool.',
            text: 'ping',
            toolName: 'ping',
            toolDescription: 'Confirm that you are reachable.',
            schema: {
              'type': 'object',
              'properties': {
                'ok': {'type': 'boolean'},
              },
              'required': ['ok'],
            },
            maxTokens: 256,
            timeout: _probeTimeout,
          ),
          onlyModel: model,
        );
      }, replyWithoutToolIsFine: true);

  /// Runs [call] and says how it ended. A reply with no tool call in it still
  /// came from a model, so for the tool probe ([replyWithoutToolIsFine]) it
  /// counts as a working connection; for the search, a reply with no text does
  /// not.
  Future<GuidedProbeResult> _probeCall(
    String model,
    Future<void> Function() call, {
    bool replyWithoutToolIsFine = false,
  }) async {
    final stopwatch = Stopwatch()..start();
    GuidedProbeResult result(GuidedProbeOutcome outcome, {int? status}) =>
        GuidedProbeResult(
          model: model,
          outcome: outcome,
          millis: stopwatch.elapsedMilliseconds,
          statusCode: status,
        );
    try {
      await call();
      return result(GuidedProbeOutcome.ok);
    } on MealInterpreterException catch (e) {
      final status = e.statusCode;
      // A reply with no tool call in it still came from the model: the
      // connection, the key and the model all work.
      if (replyWithoutToolIsFine &&
          status == null &&
          e.failure == MealInterpreterFailure.unsupported) {
        return result(GuidedProbeOutcome.ok);
      }
      final outcome = switch (e.failure) {
        MealInterpreterFailure.auth => GuidedProbeOutcome.auth,
        MealInterpreterFailure.billing => GuidedProbeOutcome.billing,
        MealInterpreterFailure.timeout => GuidedProbeOutcome.timeout,
        MealInterpreterFailure.unsupported when status == 404 =>
          GuidedProbeOutcome.missing,
        _ => switch (status) {
          429 || 500 || 502 || 503 || 504 => GuidedProbeOutcome.overloaded,
          _ => GuidedProbeOutcome.other,
        },
      };
      return result(outcome, status: status);
    } catch (_) {
      return result(GuidedProbeOutcome.other);
    }
  }
}
