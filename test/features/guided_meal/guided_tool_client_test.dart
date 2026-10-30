import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/core/utils/ai_provider_endpoints.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/guided_meal/data/guided_tool_client.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_schemas.dart';

const _tool = 'ask_meal_questions';

GuidedToolRequest _request({MealPhoto? photo}) => GuidedToolRequest(
  system: 'system prompt',
  text: 'user text',
  photo: photo,
  toolName: _tool,
  toolDescription: 'describe',
  schema: askQuestionsSchema,
);

final _photo = MealPhoto(
  bytes: Uint8List.fromList([1, 2, 3]),
  mediaType: 'image/webp',
);

final _questions = {'summary': 'Schnitzel', 'questions': <Object?>[]};

void main() {
  group('Anthropic', () {
    test('sends the tool, the image first, and reads tool_use', () async {
      late http.Request seen;
      final client = GuidedToolClient(
        MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'content': [
                {'type': 'text', 'text': 'ignored'},
                {'type': 'tool_use', 'name': _tool, 'input': _questions},
              ],
            }),
            200,
          );
        }),
      );

      final reply = await client.call(
        const AiSelection(provider: AiProvider.anthropic, apiKey: 'sk-ant'),
        _request(photo: _photo),
      );

      expect(reply['summary'], 'Schnitzel');
      expect(seen.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(seen.headers['x-api-key'], 'sk-ant');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['tool_choice'], {'type': 'tool', 'name': _tool});
      final content =
          ((body['messages'] as List).single as Map)['content'] as List;
      expect((content.first as Map)['type'], 'image');
      expect((content.last as Map)['text'], 'user text');
    });

    test('a reply without the tool call is an unsupported failure', () async {
      final client = GuidedToolClient(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'content': [
                {'type': 'text', 'text': 'prose'},
              ],
            }),
            200,
          ),
        ),
      );

      expect(
        client.call(
          const AiSelection(provider: AiProvider.anthropic, apiKey: 'k'),
          _request(),
        ),
        throwsA(
          isA<MealInterpreterException>().having(
            (e) => e.failure,
            'failure',
            MealInterpreterFailure.unsupported,
          ),
        ),
      );
    });
  });

  group('OpenAI', () {
    test('uses the Responses API and parses string arguments', () async {
      late http.Request seen;
      final client = GuidedToolClient(
        MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'output': [
                {
                  'type': 'function_call',
                  'name': _tool,
                  'arguments': jsonEncode(_questions),
                },
              ],
            }),
            200,
          );
        }),
      );

      final reply = await client.call(
        const AiSelection(provider: AiProvider.openai, apiKey: 'sk-oa'),
        _request(photo: _photo),
      );

      expect(reply['summary'], 'Schnitzel');
      expect(seen.url.toString(), 'https://api.openai.com/v1/responses');
      expect(seen.headers['authorization'], 'Bearer sk-oa');
      expect((jsonDecode(seen.body) as Map)['store'], false);
    });
  });

  group('Gemini', () {
    test('goes to the OpenAI-compatible route with a bearer key', () async {
      late http.Request seen;
      final client = GuidedToolClient(
        MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'tool_calls': [
                      {
                        'function': {
                          'name': _tool,
                          'arguments': jsonEncode(_questions),
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }),
      );

      final reply = await client.call(
        const AiSelection(provider: AiProvider.gemini, apiKey: 'AIza-test'),
        _request(photo: _photo),
      );

      expect(reply['summary'], 'Schnitzel');
      expect(seen.url, geminiChatEndpoint);
      expect(seen.headers['authorization'], 'Bearer AIza-test');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      // The catalogue default, since no model was stored.
      expect(body['model'], 'gemini-3.6-flash');
      expect(body['tool_choice'], 'required');
      // Gemini thinks before answering; a request asks for the level it needs
      // and defaults to the lowest.
      expect(body['reasoning_effort'], 'low');
      expect(body.containsKey('provider'), isFalse);
      final user = (body['messages'] as List).last as Map;
      final parts = user['content'] as List;
      expect(
        ((parts.last as Map)['image_url'] as Map)['url'],
        startsWith('data:image/webp;base64,'),
      );
    });
  });

  group('failures', () {
    Future<Object?> failureFor(int status, String body) async {
      final client = GuidedToolClient(
        MockClient((_) async => http.Response(body, status)),
        retryDelay: Duration.zero,
      );
      try {
        await client.call(
          const AiSelection(provider: AiProvider.gemini, apiKey: 'k'),
          _request(),
        );
      } on MealInterpreterException catch (e) {
        return e.failure;
      }
      return null;
    }

    test('a 401 is a rejected key', () async {
      expect(await failureFor(401, '{}'), MealInterpreterFailure.auth);
    });

    test(
      "Google's 400 for a bad key is a rejected key, not a bad image",
      () async {
        expect(
          await failureFor(400, '{"error":{"message":"API key not valid."}}'),
          MealInterpreterFailure.auth,
        );
      },
    );

    test('any other 400 is a rejected request', () async {
      expect(await failureFor(400, '{}'), MealInterpreterFailure.rejected);
    });

    test('an exhausted quota is billing, a plain 429 is transient', () async {
      expect(
        await failureFor(429, '{"error":{"code":"insufficient_quota"}}'),
        MealInterpreterFailure.billing,
      );
      expect(await failureFor(429, '{}'), MealInterpreterFailure.transient);
    });

    test('a malformed body is a failure, not a crash', () async {
      final client = GuidedToolClient(
        MockClient((_) async => http.Response('not json', 200)),
      );
      expect(
        client.call(
          const AiSelection(provider: AiProvider.gemini, apiKey: 'k'),
          _request(),
        ),
        throwsA(isA<MealInterpreterException>()),
      );
    });
  });

  group('overload', () {
    String ok() => jsonEncode({
      'choices': [
        {
          'message': {
            'tool_calls': [
              {
                'function': {
                  'name': _tool,
                  'arguments': jsonEncode(_questions),
                },
              },
            ],
          },
        },
      ],
    });

    const gemini = AiSelection(provider: AiProvider.gemini, apiKey: 'k');

    test('a 503 on the first Gemini model falls back to the next', () async {
      final asked = <String>[];
      final client = GuidedToolClient(
        MockClient((request) async {
          final model = (jsonDecode(request.body) as Map)['model'] as String;
          asked.add(model);
          return model == 'gemini-3.6-flash'
              ? http.Response('{"error":{"message":"overloaded"}}', 503)
              : http.Response(ok(), 200);
        }),
        retryDelay: Duration.zero,
      );

      final reply = await client.call(gemini, _request());

      expect(reply['summary'], 'Schnitzel');
      expect(asked, ['gemini-3.6-flash', 'gemini-3.5-flash-lite']);
    });

    test(
      'tries every model, then reports the overload with its status',
      () async {
        final asked = <String>[];
        final client = GuidedToolClient(
          MockClient((request) async {
            asked.add((jsonDecode(request.body) as Map)['model'] as String);
            return http.Response('[{"error":{"message":"overloaded"}}]', 503);
          }),
          retryDelay: Duration.zero,
        );

        await expectLater(
          client.call(gemini, _request()),
          throwsA(
            isA<MealInterpreterException>().having(
              (e) => e.statusCode,
              'statusCode',
              503,
            ),
          ),
        );
        expect(asked, ['gemini-3.6-flash', 'gemini-3.5-flash-lite']);
      },
    );

    test('a rejected key does not try another model', () async {
      var calls = 0;
      final client = GuidedToolClient(
        MockClient((_) async {
          calls++;
          return http.Response('{}', 401);
        }),
        retryDelay: Duration.zero,
      );

      await expectLater(
        client.call(gemini, _request()),
        throwsA(isA<MealInterpreterException>()),
      );
      expect(calls, 1);
    });

    test('a provider with no fallback models fails at once', () async {
      var calls = 0;
      final client = GuidedToolClient(
        MockClient((_) async {
          calls++;
          return http.Response('{}', 503);
        }),
        retryDelay: Duration.zero,
      );

      await expectLater(
        client.call(
          const AiSelection(provider: AiProvider.anthropic, apiKey: 'k'),
          _request(),
        ),
        throwsA(isA<MealInterpreterException>()),
      );
      expect(calls, 1);
    });

    test(
      'the model chosen in settings is asked first, without a repeat',
      () async {
        final asked = <String>[];
        final client = GuidedToolClient(
          MockClient((request) async {
            asked.add((jsonDecode(request.body) as Map)['model'] as String);
            return http.Response('{}', 503);
          }),
          retryDelay: Duration.zero,
        );

        await expectLater(
          client.call(
            const AiSelection(
              provider: AiProvider.gemini,
              apiKey: 'k',
              modelId: 'gemini-3.5-flash-lite',
            ),
            _request(),
          ),
          throwsA(isA<MealInterpreterException>()),
        );
        // The catalogue only knows 3.8, so a stored 3.6 falls back to it as the
        // default; the fallback list then skips nothing that was already asked.
        expect(asked.first, 'gemini-3.6-flash');
        expect(asked.toSet().length, asked.length);
      },
    );
  });
}
