import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/core/utils/ai_model_catalogue.dart';
import 'package:opennutritracker/core/utils/ai_provider_endpoints.dart';
import 'package:opennutritracker/core/utils/plaintext_destination_guard.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';

/// One forced tool call: a system prompt, a user turn (note and optional
/// photo), and the single tool the model has to answer with.
class GuidedToolRequest {
  final String system;
  final String text;
  final MealPhoto? photo;
  final String toolName;
  final String toolDescription;
  final Map<String, Object?> schema;
  final int maxTokens;

  /// Replaces the provider's usual wait, for a quick check that should not
  /// sit through the two minutes a photo is allowed.
  final Duration? timeout;

  /// How much a thinking model may deliberate before answering: `low`,
  /// `medium` or `high`. Sent where the provider takes it (Gemini today).
  /// More thinking is slower and, for reading a plate, only sometimes better,
  /// so the default is the cheapest and the caller asks for more where the
  /// answer is worth the wait.
  final String reasoningEffort;

  const GuidedToolRequest({
    required this.system,
    required this.text,
    required this.toolName,
    required this.toolDescription,
    required this.schema,
    this.photo,
    this.maxTokens = 2048,
    this.timeout,
    this.reasoningEffort = 'low',
  });
}

/// Sends a [GuidedToolRequest] to whichever provider the user configured and
/// returns the tool's arguments as a map.
///
/// The existing `MealItemsApi` clients are shaped around one fixed schema and
/// one result type. The guided flow needs two different tools, so it carries
/// its own thin client instead of changing theirs; it reuses everything that
/// is not wire format — the stored selection, the model catalogue, the
/// plaintext guard and the failure vocabulary.
///
/// Nothing here validates the content. That is the job of the parsers in
/// `guided_meal_schemas.dart`, which run against whatever came back.
class GuidedToolClient {
  static final _log = Logger('GuidedToolClient');

  /// Longer than the 20 s of the single-shot reader: these replies are larger
  /// and the question step has to look at a photo and think.
  static const hostedTimeout = Duration(seconds: 60);

  /// Per model, not in total: a Gemini model that answers at all does so in
  /// seconds, and one that stays silent for 30 s is better skipped for the next
  /// than waited on.
  static const geminiTimeout = Duration(seconds: 60);
  static const ownServerTimeout = Duration(seconds: 180);

  static const _anthropicEndpoint = 'https://api.anthropic.com/v1/messages';
  static const _anthropicVersion = '2023-06-01';
  static const _openAiEndpoint = 'https://api.openai.com/v1/responses';
  static const _openRouterEndpoint =
      'https://openrouter.ai/api/v1/chat/completions';

  /// Models tried, in order, after the selected one answers with an overload.
  ///
  /// Only Gemini has any: its newest models are served on a shared free tier
  /// and answered 503 on a phone, while an older sibling of the same family
  /// would have answered. Same company, same endpoint and the same data
  /// terms, so nothing about where the photo goes changes; the one thing that
  /// does is which model reads it, and the log says which one did.
  static const _fallbackModels = <AiProvider, List<String>>{
    AiProvider.gemini: ['gemini-3.5-flash-lite'],
  };

  final http.Client _client;

  /// The model that last answered for a provider, asked first from then on, so
  /// one that is down costs its wait once and not on every request.
  final _lastGood = <AiProvider, String>{};

  /// Pause before the next model after an overload. Injectable so the tests
  /// do not wait for it.
  final Duration _retryDelay;

  GuidedToolClient(
    this._client, {
    Duration retryDelay = const Duration(seconds: 2),
  }) : _retryDelay = retryDelay;

  /// The models this provider would be asked, in the order they are tried.
  List<String> modelsFor(AiSelection selection) {
    final model = AiModelCatalogue.resolve(
      selection.provider,
      selection.modelId,
    );
    final modelId = model?.id ?? selection.modelId;
    if (modelId == null) {
      throw StateError('no model for ${selection.provider.name}');
    }
    final models = <String>[
      modelId,
      for (final fallback in _fallbackModels[selection.provider] ?? const [])
        if (fallback != modelId) fallback,
    ];
    final good = _lastGood[selection.provider];
    if (good != null && models.remove(good)) models.insert(0, good);
    return models;
  }

  /// Sends [request], falling back to the provider's other models when one is
  /// overloaded or silent. [onlyModel] asks exactly that model and nothing
  /// else, for the connection test.
  Future<Map<String, dynamic>> call(
    AiSelection selection,
    GuidedToolRequest request, {
    String? onlyModel,
  }) async {
    final model = AiModelCatalogue.resolve(
      selection.provider,
      selection.modelId,
    );
    final candidates = onlyModel != null ? [onlyModel] : modelsFor(selection);
    for (var i = 0; i < candidates.length; i++) {
      try {
        final reply = await _callOnce(selection, request, candidates[i], model);
        if (onlyModel == null) {
          if (i > 0) _log.info('Answered by fallback model ${candidates[i]}');
          _lastGood[selection.provider] = candidates[i];
        }
        return reply;
      } on MealInterpreterException catch (e) {
        final last = i == candidates.length - 1;
        if (last || !_isOverload(e)) rethrow;
        _log.info(
          '${candidates[i]} unavailable (${e.statusCode ?? e.failure.name}), '
          'trying ${candidates[i + 1]}',
        );
        await Future<void>.delayed(_retryDelay);
      }
    }
    throw StateError('unreachable');
  }

  /// A server-side hiccup, a spent quota or silence on this model, which
  /// another model of the same provider may well not share.
  static bool _isOverload(MealInterpreterException e) =>
      e.failure == MealInterpreterFailure.timeout ||
      switch (e.statusCode) {
        429 || 500 || 502 || 503 || 504 => true,
        _ => false,
      };

  Future<Map<String, dynamic>> _callOnce(
    AiSelection selection,
    GuidedToolRequest request,
    String modelId,
    AiModel? model,
  ) async {
    final wire = switch (selection.provider) {
      AiProvider.anthropic => _anthropic(selection, modelId, request),
      AiProvider.openai => _openAi(selection, modelId, request),
      AiProvider.openrouter => _chat(
        client: _client,
        uri: Uri.parse(_openRouterEndpoint),
        apiKey: selection.apiKey,
        modelId: modelId,
        request: request,
        toolChoice: _namedTool(request),
        routing: {
          'require_parameters': true,
          'data_collection': 'deny',
          if (model != null && model.providers.isNotEmpty) ...{
            'only': model.providers,
            'allow_fallbacks': false,
          },
        },
        timeout: request.timeout ?? hostedTimeout,
      ),
      AiProvider.gemini => _chat(
        client: _client,
        uri: geminiChatEndpoint,
        apiKey: selection.apiKey,
        modelId: modelId,
        request: request,
        toolChoice: 'required',
        // Gemini 3 models think before they answer, and at their default
        // level a photo plus a forced tool call ran past 60 s on a phone.
        // `low` is the lowest level every Gemini model accepts here; the
        // task is reading a plate, not solving a proof.
        extraBody: {'reasoning_effort': request.reasoningEffort},
        timeout: request.timeout ?? geminiTimeout,
      ),
      AiProvider.ownServer => _chat(
        client: GuardedPlaintextClient(_client),
        uri: Uri.parse(selection.endpoint!),
        apiKey: selection.apiKey,
        modelId: modelId,
        request: request,
        toolChoice: 'required',
        timeout: request.timeout ?? ownServerTimeout,
        timeoutFailure: MealInterpreterFailure.timeout,
      ),
    };
    return wire;
  }

  Object _namedTool(GuidedToolRequest request) => {
    'type': 'function',
    'function': {'name': request.toolName},
  };

  Future<Map<String, dynamic>> _anthropic(
    AiSelection selection,
    String modelId,
    GuidedToolRequest request,
  ) async {
    final photo = request.photo;
    final body = jsonEncode({
      'model': modelId,
      'max_tokens': request.maxTokens,
      'system': request.system,
      'tools': [
        {
          'name': request.toolName,
          'description': request.toolDescription,
          'input_schema': request.schema,
        },
      ],
      'tool_choice': {'type': 'tool', 'name': request.toolName},
      'messages': [
        {
          'role': 'user',
          'content': [
            // Image first, as Anthropic's vision guidance recommends.
            if (photo != null)
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': photo.mediaType,
                  'data': base64Encode(photo.bytes),
                },
              },
            {'type': 'text', 'text': request.text},
          ],
        },
      ],
    });
    final decoded = await _post(
      client: _client,
      uri: Uri.parse(_anthropicEndpoint),
      headers: {
        'x-api-key': selection.apiKey ?? '',
        'anthropic-version': _anthropicVersion,
      },
      body: body,
      timeout: request.timeout ?? hostedTimeout,
    );

    final content = decoded['content'];
    if (content is List) {
      for (final block in content) {
        if (block is Map &&
            block['type'] == 'tool_use' &&
            block['name'] == request.toolName &&
            block['input'] is Map) {
          return Map<String, dynamic>.from(block['input'] as Map);
        }
      }
    }
    throw _noToolCall();
  }

  Future<Map<String, dynamic>> _openAi(
    AiSelection selection,
    String modelId,
    GuidedToolRequest request,
  ) async {
    final photo = request.photo;
    final body = jsonEncode({
      'model': modelId,
      'instructions': request.system,
      'input': [
        {
          'role': 'user',
          'content': [
            if (photo != null)
              {
                'type': 'input_image',
                'image_url':
                    'data:${photo.mediaType};base64,${base64Encode(photo.bytes)}',
              },
            {'type': 'input_text', 'text': request.text},
          ],
        },
      ],
      'tools': [
        {
          'type': 'function',
          'name': request.toolName,
          'description': request.toolDescription,
          'parameters': request.schema,
          // Not strict: strict mode demands every property be required, and
          // the app checks the reply itself.
          'strict': false,
        },
      ],
      'tool_choice': {'type': 'function', 'name': request.toolName},
      'store': false,
      'max_output_tokens': request.maxTokens,
    });
    final decoded = await _post(
      client: _client,
      uri: Uri.parse(_openAiEndpoint),
      headers: {'authorization': 'Bearer ${selection.apiKey ?? ''}'},
      body: body,
      timeout: request.timeout ?? hostedTimeout,
    );

    final output = decoded['output'];
    if (output is List) {
      for (final entry in output) {
        if (entry is Map &&
            entry['type'] == 'function_call' &&
            entry['name'] == request.toolName) {
          return _decodeArguments(entry['arguments']);
        }
      }
    }
    throw _noToolCall();
  }

  /// OpenRouter and servers the user runs: the OpenAI chat-completions shape.
  Future<Map<String, dynamic>> _chat({
    required http.Client client,
    required Uri uri,
    required String? apiKey,
    required String modelId,
    required GuidedToolRequest request,
    required Object toolChoice,
    required Duration timeout,
    Map<String, Object?>? routing,
    Map<String, Object?>? extraBody,
    MealInterpreterFailure timeoutFailure = MealInterpreterFailure.timeout,
  }) async {
    final photo = request.photo;
    final body = jsonEncode({
      'model': modelId,
      'max_tokens': request.maxTokens,
      ...?extraBody,
      'messages': [
        {'role': 'system', 'content': request.system},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': request.text},
            if (photo != null)
              {
                'type': 'image_url',
                'image_url': {
                  'url':
                      'data:${photo.mediaType};base64,${base64Encode(photo.bytes)}',
                },
              },
          ],
        },
      ],
      'tools': [
        {
          'type': 'function',
          'function': {
            'name': request.toolName,
            'description': request.toolDescription,
            'parameters': request.schema,
          },
        },
      ],
      'tool_choice': toolChoice,
      'provider': ?routing,
    });
    final decoded = await _post(
      client: client,
      uri: uri,
      headers: {
        if (apiKey != null && apiKey.isNotEmpty)
          'authorization': 'Bearer $apiKey',
      },
      body: body,
      timeout: timeout,
      timeoutFailure: timeoutFailure,
    );

    final choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final message = (choices.first as Map)['message'];
      final calls = message is Map ? message['tool_calls'] : null;
      if (calls is List) {
        for (final call in calls) {
          final function = call is Map ? call['function'] : null;
          if (function is Map && function['name'] == request.toolName) {
            return _decodeArguments(function['arguments']);
          }
        }
      }
    }
    throw _noToolCall();
  }

  static Future<Map<String, dynamic>> _post({
    required http.Client client,
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
    MealInterpreterFailure timeoutFailure = MealInterpreterFailure.timeout,
  }) async {
    final http.Response response;
    final stopwatch = Stopwatch()..start();
    try {
      response = await client
          .post(
            uri,
            headers: {'content-type': 'application/json', ...headers},
            body: body,
          )
          .timeout(timeout);
      // Host and timing only, so a slow provider can be told from a dead
      // connection without the request, key or photo ever reaching a log.
      _log.info(
        'Guided call to ${uri.host} answered ${response.statusCode} '
        'in ${stopwatch.elapsedMilliseconds} ms',
      );
    } on InsecureDestinationException {
      throw const MealInterpreterException(
        'plaintext to a public address',
        failure: MealInterpreterFailure.insecureDestination,
      );
    } on TimeoutException {
      _log.info(
        'Guided call to ${uri.host} gave no answer in '
        '${stopwatch.elapsedMilliseconds} ms',
      );
      throw MealInterpreterException(
        'request timed out',
        failure: timeoutFailure,
      );
    } catch (_) {
      // Deliberately not logging the error: it can carry the request, and the
      // request carries the photograph.
      throw const MealInterpreterException('request failed');
    }

    if (response.statusCode != 200) {
      // The provider's own words for what went wrong, never the request.
      _log.warning(
        'Guided call failed with ${response.statusCode}'
        '${_providerMessage(response.body)}',
      );
      throw MealInterpreterException(
        'provider returned ${response.statusCode}',
        failure: _failureFor(response.statusCode, response.body),
        statusCode: response.statusCode,
      );
    }

    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw const MealInterpreterException('malformed response');
    }
  }

  /// `": message"` from an error body shaped `{"error": {"message": …}}`, or
  /// the same inside a one-element list as Google sometimes sends it. Empty
  /// when there is none, and cut short: it goes to a log.
  static String _providerMessage(String body) {
    try {
      var decoded = jsonDecode(body);
      if (decoded is List && decoded.isNotEmpty) decoded = decoded.first;
      final error = decoded is Map ? decoded['error'] : null;
      final message = error is Map ? error['message'] : null;
      if (message is! String || message.isEmpty) return '';
      return ': ${message.length > 200 ? message.substring(0, 200) : message}';
    } catch (_) {
      return '';
    }
  }

  static MealInterpreterFailure _failureFor(int statusCode, String body) =>
      switch (statusCode) {
        401 || 403 => MealInterpreterFailure.auth,
        // Google answers a wrong key with 400, not 401.
        400
            when body.contains('API key not valid') ||
                body.contains('API_KEY_INVALID') =>
          MealInterpreterFailure.auth,
        402 => MealInterpreterFailure.billing,
        429 when body.contains('insufficient_quota') =>
          MealInterpreterFailure.billing,
        400 || 422 => MealInterpreterFailure.rejected,
        404 => MealInterpreterFailure.unsupported,
        _ => MealInterpreterFailure.transient,
      };

  static Map<String, dynamic> _decodeArguments(Object? arguments) {
    if (arguments is Map) return Map<String, dynamic>.from(arguments);
    if (arguments is! String) {
      throw const MealInterpreterException('tool call has no arguments');
    }
    try {
      final parsed = jsonDecode(arguments);
      if (parsed is Map) return Map<String, dynamic>.from(parsed);
    } catch (_) {
      // Falls through to the exception below.
    }
    throw const MealInterpreterException('tool call arguments malformed');
  }

  static MealInterpreterException _noToolCall() =>
      const MealInterpreterException(
        'response carried no tool call',
        failure: MealInterpreterFailure.unsupported,
      );
}
