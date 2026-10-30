import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/core/utils/chatgpt_auth.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/guided_meal/data/guided_tool_client.dart';
import 'package:opennutritracker/features/guided_meal/data/guided_tool_meal_items_api.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_schemas.dart';

class _Tokens implements ChatGptTokenSource {
  final calls = <bool>[];
  var _n = 0;
  Object? failWith;

  @override
  Future<String> accessToken({bool forceRefresh = false}) async {
    calls.add(forceRefresh);
    final failure = failWith;
    if (failure != null) throw failure;
    return 'token-${++_n}';
  }
}

const _selection = AiSelection(
  provider: AiProvider.chatgpt,
  apiKey: AiCredentialStorage.chatGptSessionMarker,
  modelId: 'gpt-test',
);

GuidedToolRequest _request({Duration? timeout}) => GuidedToolRequest(
  system: 'system',
  text: 'user',
  photo: MealPhoto(
    bytes: Uint8List.fromList([1, 2, 3]),
    mediaType: 'image/webp',
  ),
  toolName: askQuestionsToolName,
  toolDescription: 'd',
  schema: askQuestionsSchema,
  timeout: timeout,
);

String _sse(List<Map<String, Object?>> events) =>
    events.map((e) => 'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n').join();

Map<String, Object?> _item(Object arguments) => {
  'type': 'response.output_item.done',
  'item': {
    'type': 'function_call',
    'name': askQuestionsToolName,
    'arguments': jsonEncode(arguments),
  },
};

const _completed = {
  'type': 'response.completed',
  'response': {'output': []},
};

GuidedToolClient _client(
  Future<http.Response> Function(http.Request) handler,
  _Tokens tokens,
) => GuidedToolClient(MockClient(handler), chatGpt: tokens);

http.Response _stream(String body, [int status = 200]) =>
    http.Response(body, status, headers: {'content-type': 'text/event-stream'});

void main() {
  test(
    'streams the Responses API with the plan token and reads the call',
    () async {
      final tokens = _Tokens();
      late http.Request seen;
      final client = _client((request) async {
        seen = request;
        return _stream(
          _sse([
            {'type': 'response.created'},
            _item({'summary': 'Schnitzel', 'questions': []}),
            _completed,
          ]),
        );
      }, tokens);

      final reply = await client.call(_selection, _request());

      expect(reply['summary'], 'Schnitzel');
      expect(seen.url.toString(), 'https://api.openai.com/v1/responses');
      expect(seen.headers['authorization'], 'Bearer token-1');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['stream'], true);
      expect(body['store'], false);
      expect(body['model'], 'gpt-test');
      // Fields the plan route is not documented to take are left out.
      expect(body.containsKey('max_output_tokens'), isFalse);
      expect(body.containsKey('reasoning'), isFalse);
      final content =
          ((body['input'] as List).single as Map)['content'] as List;
      expect((content.first as Map)['type'], 'input_image');
    },
  );

  test(
    'falls back to the completed response when no item event came',
    () async {
      final client = _client(
        (_) async => _stream(
          _sse([
            {
              'type': 'response.completed',
              'response': {
                'output': [
                  {
                    'type': 'function_call',
                    'name': askQuestionsToolName,
                    'arguments': jsonEncode({'summary': 'x', 'questions': []}),
                  },
                ],
              },
            },
          ]),
        ),
        _Tokens(),
      );

      expect((await client.call(_selection, _request()))['summary'], 'x');
    },
  );

  test('a stream that stops before completing is not a success', () async {
    final client = _client(
      (_) async => _stream(
        _sse([
          _item({'summary': 'x', 'questions': []}),
        ]),
      ),
      _Tokens(),
    );

    await expectLater(
      client.call(_selection, _request()),
      throwsA(isA<MealInterpreterException>()),
    );
  });

  test('a completed response without the tool call is unsupported', () async {
    final client = _client((_) async => _stream(_sse([_completed])), _Tokens());

    await expectLater(
      client.call(_selection, _request()),
      throwsA(
        isA<MealInterpreterException>().having(
          (e) => e.failure,
          'failure',
          MealInterpreterFailure.unsupported,
        ),
      ),
    );
  });

  group('errors', () {
    Future<MealInterpreterException> failure(http.Response response) async {
      final client = _client((_) async => response, _Tokens());
      try {
        await client.call(_selection, _request());
      } on MealInterpreterException catch (e) {
        return e;
      }
      fail('expected a failure');
    }

    test('a spent plan allowance arriving in the stream is billing', () async {
      final e = await failure(
        _stream(
          _sse([
            {
              'type': 'response.failed',
              'response': {
                'error': {'code': 'subscription_sharing_usage_limit_exceeded'},
              },
            },
          ]),
        ),
      );

      expect(e.failure, MealInterpreterFailure.billing);
    });

    test('any other failure in the stream is transient', () async {
      final e = await failure(
        _stream(
          _sse([
            {
              'type': 'response.failed',
              'response': {
                'error': {'code': 'subscription_sharing_usage_unavailable'},
              },
            },
          ]),
        ),
      );

      expect(e.failure, MealInterpreterFailure.transient);
    });

    test('an error event is read like a failed response', () async {
      final e = await failure(
        _stream(
          _sse([
            {
              'type': 'error',
              'error': {'code': 'subscription_sharing_usage_limit_exceeded'},
            },
          ]),
        ),
      );

      expect(e.failure, MealInterpreterFailure.billing);
    });

    test('an HTTP error keeps its status', () async {
      final e = await failure(http.Response('{"error":{}}', 403));

      expect(e.failure, MealInterpreterFailure.auth);
      expect(e.statusCode, 403);
    });
  });

  group('the token', () {
    test('a 401 is retried once with a refreshed token', () async {
      final tokens = _Tokens();
      final bearers = <String?>[];
      final client = _client((request) async {
        bearers.add(request.headers['authorization']);
        return bearers.length == 1
            ? http.Response('{}', 401)
            : _stream(
                _sse([
                  _item({'summary': 'ok', 'questions': []}),
                  _completed,
                ]),
              );
      }, tokens);

      final reply = await client.call(_selection, _request());

      expect(reply['summary'], 'ok');
      expect(bearers, ['Bearer token-1', 'Bearer token-2']);
      expect(tokens.calls, [false, true]);
    });

    test('a second 401 is a rejected credential', () async {
      final tokens = _Tokens();
      var calls = 0;
      final client = _client((_) async {
        calls++;
        return http.Response('{}', 401);
      }, tokens);

      await expectLater(
        client.call(_selection, _request()),
        throwsA(
          isA<MealInterpreterException>().having(
            (e) => e.failure,
            'failure',
            MealInterpreterFailure.auth,
          ),
        ),
      );
      expect(calls, 2);
    });

    test(
      'a lost sign-in is a rejected credential, not a network error',
      () async {
        final tokens = _Tokens()
          ..failWith = const ChatGptAuthException(
            ChatGptAuthProblem.notSignedIn,
          );
        var calls = 0;
        final client = _client((_) async {
          calls++;
          return http.Response('{}', 200);
        }, tokens);

        await expectLater(
          client.call(_selection, _request()),
          throwsA(
            isA<MealInterpreterException>().having(
              (e) => e.failure,
              'failure',
              MealInterpreterFailure.auth,
            ),
          ),
        );
        expect(calls, 0);
      },
    );

    test('without a token source the provider is unavailable', () async {
      final client = GuidedToolClient(
        MockClient((_) async => http.Response('{}', 200)),
      );

      await expectLater(
        client.call(_selection, _request()),
        throwsA(
          isA<MealInterpreterException>().having(
            (e) => e.failure,
            'failure',
            MealInterpreterFailure.auth,
          ),
        ),
      );
    });
  });

  group('the single-shot reader on the same client', () {
    test(
      'reads typed lines through the plan route and keeps its checks',
      () async {
        final client = _client((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final tool = ((body['tools'] as List).single as Map)['name'];
          expect(tool, mealItemsToolName);
          return _stream(
            _sse([
              {
                'type': 'response.output_item.done',
                'item': {
                  'type': 'function_call',
                  'name': mealItemsToolName,
                  'arguments': jsonEncode({
                    'items': [
                      {'query': 'Ei', 'quantity': 2},
                      // Carries a field the schema forbids; it is dropped.
                      {'query': 'Toast', 'calories': 999},
                    ],
                  }),
                },
              },
              _completed,
            ]),
          );
        }, _Tokens());
        final api = GuidedToolMealItemsApi(client, _selection);

        final result = await api.requestItems(
          content: const MealTextContent('2 Eier und Toast'),
          system: 'system',
        );

        expect(result.items.map((i) => i.query), ['Ei', 'Toast']);
        expect(result.items.first.quantity, 2);
      },
    );

    test('sends a photo as an image part', () async {
      late Map<String, dynamic> body;
      final client = _client((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return _stream(
          _sse([
            {
              'type': 'response.output_item.done',
              'item': {
                'type': 'function_call',
                'name': mealItemsToolName,
                'arguments': jsonEncode({'items': <Object?>[]}),
              },
            },
            _completed,
          ]),
        );
      }, _Tokens());
      final api = GuidedToolMealItemsApi(client, _selection);

      await api.requestItems(
        content: MealPhotoContent(
          mediaType: 'image/webp',
          base64Data: base64Encode([9, 9, 9]),
        ),
        system: 'system',
      );

      final content =
          ((body['input'] as List).single as Map)['content'] as List;
      expect((content.first as Map)['type'], 'input_image');
      expect((content.last as Map)['text'], mealPhotoContentPrompt);
    });
  });
}
