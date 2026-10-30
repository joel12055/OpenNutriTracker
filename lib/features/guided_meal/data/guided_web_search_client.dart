import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/utils/chatgpt_auth.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_interpreter_exception.dart';
import 'package:opennutritracker/features/guided_meal/data/guided_tool_client.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_web_research.dart';

/// Looks foods up on the web, through the person's ChatGPT plan or a Gemini
/// key.
///
/// A call of its own, not a tool call of [GuidedToolClient]: the guided flow's
/// own calls are forced function calls, and a search tool cannot be combined
/// with one on every provider. What it returns is plain text for the decision
/// step to weigh. Only the search queries leave the phone, never a photo.
///
/// Two routes, because neither is certain for every person:
/// - [searchWithChatGpt]: the Responses API's `web_search` tool, which counts
///   against the ChatGPT plan and costs nothing more.
/// - [search]: Gemini's Google Search tool through the native
///   `generateContent`, which keeps nothing on Google's side. Its free models,
///   Gemini 2.5, are closed to new accounts (a 404 "no longer available to new
///   users" on a phone), and Gemini 3 searches only on a paid plan.
///
/// A Gemini key travels in a header, never in the address, so it cannot end up
/// in a log of requested URLs.
class GuidedWebSearchClient {
  static final _log = Logger('GuidedWebSearchClient');

  /// The Gemini models tried, in this order. Kept here and nowhere else:
  /// models come and go, and the connection test names these.
  static const models = ['gemini-2.5-flash', 'gemini-2.5-flash-lite'];

  static const timeout = Duration(seconds: 45);

  /// A search through the plan reads pages first and answers after, so it gets
  /// longer than a lookup that is answered from an index.
  static const chatGptTimeout = Duration(seconds: 90);

  static const _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';
  static const _responsesEndpoint = 'https://api.openai.com/v1/responses';

  final http.Client _client;
  final Duration _retryDelay;

  /// Where the ChatGPT route gets its bearer token. Null where nobody can be
  /// signed in, which makes that route fail as a rejected credential.
  final ChatGptTokenSource? _chatGptTokens;

  /// The model that last answered, asked first from then on.
  String? _lastGood;

  GuidedWebSearchClient(
    this._client, {
    Duration retryDelay = const Duration(seconds: 2),
    ChatGptTokenSource? chatGpt,
  }) : _retryDelay = retryDelay,
       _chatGptTokens = chatGpt;

  /// Searches the web with [modelId] through the person's ChatGPT plan.
  ///
  /// Only `store` and `stream` besides the model, the instructions, the input
  /// and the search tool: that route is documented to need nothing more, and a
  /// field it does not know is a request refused for a reason nobody can act
  /// on.
  Future<GuidedWebResearch> searchWithChatGpt({
    required String modelId,
    required String system,
    required String text,
    Duration? timeoutOverride,
  }) async {
    final tokens = _chatGptTokens;
    if (tokens == null) {
      throw const MealInterpreterException(
        'no ChatGPT sign-in available',
        failure: MealInterpreterFailure.auth,
      );
    }
    final body = jsonEncode({
      'model': modelId,
      'instructions': system,
      'input': [
        {
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': text},
          ],
        },
      ],
      'tools': [
        {'type': 'web_search'},
      ],
      'store': false,
      'stream': true,
    });

    for (var attempt = 0; ; attempt++) {
      final String token;
      try {
        token = await tokens.accessToken(forceRefresh: attempt > 0);
      } on ChatGptAuthException {
        throw const MealInterpreterException(
          'ChatGPT sign-in is no longer valid',
          failure: MealInterpreterFailure.auth,
        );
      }
      try {
        return await _streamSearch(token, body, timeoutOverride ?? chatGptTimeout);
      } on MealInterpreterException catch (e) {
        // A token the server calls stale is replaced once and tried again.
        if (e.statusCode == 401 && attempt == 0) continue;
        rethrow;
      }
    }
  }

  Future<GuidedWebResearch> _streamSearch(
    String token,
    String body,
    Duration timeout,
  ) async {
    final stopwatch = Stopwatch()..start();
    final http.StreamedResponse response;
    try {
      final request = http.Request('POST', Uri.parse(_responsesEndpoint))
        ..headers.addAll({
          'content-type': 'application/json',
          'accept': 'text/event-stream',
          'authorization': 'Bearer $token',
        })
        ..body = body;
      response = await _client.send(request).timeout(timeout);
    } on TimeoutException {
      throw const MealInterpreterException(
        'request timed out',
        failure: MealInterpreterFailure.timeout,
      );
    } catch (_) {
      // Not logged: the error can carry the request.
      throw const MealInterpreterException('request failed');
    }

    if (response.statusCode != 200) {
      final text = await response.stream.bytesToString().timeout(
        const Duration(seconds: 10),
        onTimeout: () => '',
      );
      _log.warning(
        'Web search failed with ${response.statusCode}'
        '${GuidedToolClient.providerMessage(text)}',
      );
      throw MealInterpreterException(
        'provider returned ${response.statusCode}',
        failure: GuidedToolClient.failureFor(response.statusCode, text),
        statusCode: response.statusCode,
      );
    }

    final research = await _readSearchEvents(response.stream).timeout(
      timeout,
      onTimeout: () => throw const MealInterpreterException(
        'request timed out',
        failure: MealInterpreterFailure.timeout,
      ),
    );
    // Counts only: the answer is web text and the queries are what was eaten.
    _log.info(
      'Web search through the ChatGPT plan finished in '
      '${stopwatch.elapsedMilliseconds} ms: ${research.queries.length} '
      'searches, ${research.sources.length} sources',
    );
    return research;
  }

  /// Reads server-sent events until the response completes. The items are
  /// collected as they finish as well, because the completed event of this
  /// route may carry an empty output.
  static Future<GuidedWebResearch> _readSearchEvents(
    Stream<List<int>> bytes,
  ) async {
    final items = <Object?>[];
    await for (final line
        in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      final Object? event;
      try {
        event = jsonDecode(payload);
      } catch (_) {
        continue;
      }
      if (event is! Map) continue;

      switch (event['type']) {
        case 'response.output_item.done':
          items.add(event['item']);
        case 'response.completed':
          final response = event['response'];
          final output = response is Map ? response['output'] : null;
          return guidedWebResearchFromResponses(
            output is List && output.isNotEmpty ? response : {'output': items},
          );
        case 'response.failed' || 'error':
          throw GuidedToolClient.streamFailure(event);
        case 'response.incomplete':
          throw const MealInterpreterException('response incomplete');
      }
    }
    throw const MealInterpreterException('stream ended before completion');
  }

  List<String> get _order {
    final order = [...models];
    final good = _lastGood;
    if (good != null && order.remove(good)) order.insert(0, good);
    return order;
  }

  /// Searches for [text], answering as [system] instructs. [onlyModel] asks
  /// exactly that model and nothing else, for the connection test.
  Future<GuidedWebResearch> search({
    required String apiKey,
    required String system,
    required String text,
    String? onlyModel,
    Duration? timeoutOverride,
  }) async {
    final candidates = onlyModel != null ? [onlyModel] : _order;
    for (var i = 0; i < candidates.length; i++) {
      try {
        final research = await _searchOnce(
          apiKey: apiKey,
          model: candidates[i],
          system: system,
          text: text,
          timeout: timeoutOverride ?? timeout,
        );
        if (onlyModel == null) {
          if (i > 0) _log.info('Answered by fallback model ${candidates[i]}');
          _lastGood = candidates[i];
        }
        return research;
      } on MealInterpreterException catch (e) {
        final last = i == candidates.length - 1;
        if (last || !GuidedToolClient.isOverload(e)) rethrow;
        _log.info(
          '${candidates[i]} unavailable (${e.statusCode ?? e.failure.name}), '
          'trying ${candidates[i + 1]}',
        );
        await Future<void>.delayed(_retryDelay);
      }
    }
    throw StateError('unreachable');
  }

  Future<GuidedWebResearch> _searchOnce({
    required String apiKey,
    required String model,
    required String system,
    required String text,
    required Duration timeout,
  }) async {
    final body = jsonEncode({
      'systemInstruction': {
        'parts': [
          {'text': system},
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': text},
          ],
        },
      ],
      'tools': [
        {'google_search': <String, Object?>{}},
      ],
      'generationConfig': {
        // Figures to be read off a page, not written freely.
        'temperature': 0.2,
        'maxOutputTokens': 3072,
        // The answer is a lookup, and thinking at length first only adds wait.
        'thinkingConfig': {'thinkingBudget': 0},
      },
    });
    final decoded = await GuidedToolClient.post(
      client: _client,
      uri: Uri.parse('$_baseUrl/$model:generateContent'),
      headers: {'x-goog-api-key': apiKey},
      body: body,
      timeout: timeout,
    );
    final research = guidedWebResearchFromJson(decoded);
    // Counts only: the answer is web text and the queries are what the person
    // ate, neither belongs in a log.
    _log.info(
      'Web search by $model: ${research.queries.length} searches, '
      '${research.sources.length} sources',
    );
    return research;
  }
}
