import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/utils/chatgpt_auth.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_interpreter_exception.dart';
import 'package:opennutritracker/features/guided_meal/data/guided_tool_client.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_web_research.dart';

/// Looks foods up on the web through the person's ChatGPT plan.
///
/// A call of its own, not a tool call of [GuidedToolClient]: the guided flow's
/// own calls are forced function calls, and a search tool cannot be combined
/// with one on every provider. What it returns is plain text for the decision
/// step to weigh. Only the search queries leave the phone, never a photo.
///
/// It uses the Responses API's `web_search` tool, which counts against the
/// plan and costs nothing more. Gemini's Google Search tool was tried and
/// dropped: its free models, Gemini 2.5, answer 404 "no longer available to
/// new users" for new accounts, and Gemini 3 searches only on a paid plan.
class GuidedWebSearchClient {
  static final _log = Logger('GuidedWebSearchClient');

  /// A search reads pages first and answers after, so it gets longer than a
  /// lookup that is answered from an index.
  static const timeout = Duration(seconds: 90);

  static const _responsesEndpoint = 'https://api.openai.com/v1/responses';

  final http.Client _client;

  /// Where the bearer token comes from, refreshed behind it when the server
  /// calls it stale.
  final ChatGptTokenSource _tokens;

  GuidedWebSearchClient(this._client, this._tokens);

  /// Searches the web with [modelId] through the person's ChatGPT plan.
  ///
  /// Only `store` and `stream` besides the model, the instructions, the input
  /// and the search tool: that route is documented to need nothing more, and a
  /// field it does not know is a request refused for a reason nobody can act
  /// on.
  Future<GuidedWebResearch> search({
    required String modelId,
    required String system,
    required String text,
    Duration? timeoutOverride,
  }) async {
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
        token = await _tokens.accessToken(forceRefresh: attempt > 0);
      } on ChatGptAuthException {
        throw const MealInterpreterException(
          'ChatGPT sign-in is no longer valid',
          failure: MealInterpreterFailure.auth,
        );
      }
      try {
        return await _stream(token, body, timeoutOverride ?? timeout);
      } on MealInterpreterException catch (e) {
        // A token the server calls stale is replaced once and tried again.
        if (e.statusCode == 401 && attempt == 0) continue;
        rethrow;
      }
    }
  }

  Future<GuidedWebResearch> _stream(
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

    final research = await _readEvents(response.stream).timeout(
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
  static Future<GuidedWebResearch> _readEvents(Stream<List<int>> bytes) async {
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
}
