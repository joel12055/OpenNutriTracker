import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/core/utils/ai_model_catalogue.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/guided_meal/data/guided_tool_client.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_entities.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_prompts.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_schemas.dart';

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

/// The two model calls of the guided flow.
///
/// Both are stateless: the estimate call sends the photo again together with
/// the questions and the answers, so no conversation is kept anywhere and the
/// photo is still never written to disk.
///
/// Every failure surfaces as `MealInterpreterException`, the vocabulary the
/// app's other AI screens already turn into user-facing advice.
class GuidedMealService {
  final AiCredentialStorage _credentials;
  final GuidedToolClient _client;

  GuidedMealService(this._credentials, this._client);

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
    final model = AiModelCatalogue.resolve(
      provider,
      await _credentials.readModel(provider: provider),
    );
    return model == null ? null : GuidedDestination(provider, model.servedBy);
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
        reasoningEffort: 'medium',
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
    final reply = await _client.call(
      selection,
      GuidedToolRequest(
        system: guidedEstimatePrompt(localeCode: localeCode),
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
        reasoningEffort: 'high',
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
  Future<GuidedDecision> decide({
    required MealPhoto photo,
    required GuidedAnalysis analysis,
    required Map<String, GuidedAnswer> answers,
    required GuidedEstimate estimate,
    required String secondOpinion,
    required String unknownLabel,
    String? note,
    String? localeCode,
  }) async {
    final selection = await _selection();
    final reply = await _client.call(
      selection,
      GuidedToolRequest(
        system: guidedDecisionPrompt(localeCode: localeCode),
        text: guidedDecisionUserText(
          note: note,
          summary: analysis.summary,
          questions: analysis.questions,
          answers: answers,
          unknownLabel: unknownLabel,
          estimate: estimate,
          secondOpinion: secondOpinion,
        ),
        photo: photo,
        toolName: decideMealToolName,
        toolDescription: decideMealToolDescription,
        schema: decideMealSchema,
        // The last word on what gets logged, so the most thinking.
        reasoningEffort: 'high',
      ),
    );
    return guidedDecisionFromJson(reply);
  }

  /// Asks every model this provider would be tried with one tiny question, no
  /// photo, and reports how each answered and how fast.
  ///
  /// For telling a dead connection from a bad key from a model that is down
  /// or silent, without anyone reading logs. Runs the models side by side, so
  /// the test lasts as long as the slowest wait rather than their sum.
  Future<List<GuidedProbeResult>> testConnection() async {
    final selection = await _selection();
    final models = _client.modelsFor(selection);
    return Future.wait(models.map((model) => _probe(selection, model)));
  }

  static const _probeTimeout = Duration(seconds: 20);

  Future<GuidedProbeResult> _probe(AiSelection selection, String model) async {
    final stopwatch = Stopwatch()..start();
    GuidedProbeResult result(GuidedProbeOutcome outcome, {int? status}) =>
        GuidedProbeResult(
          model: model,
          outcome: outcome,
          millis: stopwatch.elapsedMilliseconds,
          statusCode: status,
        );
    try {
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
      return result(GuidedProbeOutcome.ok);
    } on MealInterpreterException catch (e) {
      final status = e.statusCode;
      // A reply with no tool call in it still came from the model: the
      // connection, the key and the model all work.
      if (status == null && e.failure == MealInterpreterFailure.unsupported) {
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
