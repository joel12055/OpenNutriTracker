import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opennutritracker/core/utils/chatgpt_auth.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_interpreter_exception.dart';
import 'package:opennutritracker/features/guided_meal/data/guided_web_search_client.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_web_research.dart';

/// Hands out `token-0`, then a new one for each refresh.
class _Tokens implements ChatGptTokenSource {
  final bool fails;
  int refreshes = 0;

  _Tokens({this.fails = false});

  @override
  Future<String> accessToken({bool forceRefresh = false}) async {
    if (fails) {
      throw const ChatGptAuthException(ChatGptAuthProblem.notSignedIn);
    }
    if (forceRefresh) refreshes++;
    return 'token-$refreshes';
  }
}

String _answer([String text = 'per 100 g: 250 kcal']) => jsonEncode({
  'candidates': [
    {
      'content': {
        'parts': [
          {'text': text},
        ],
      },
      'groundingMetadata': {
        'webSearchQueries': ['big mac'],
        'groundingChunks': [
          {
            'web': {'uri': 'https://g.example/1', 'title': 'mcdonalds.de'},
          },
        ],
      },
    },
  ],
});

GuidedWebSearchClient _client(
  Future<http.Response> Function(http.Request request) handler,
) => GuidedWebSearchClient(MockClient(handler), retryDelay: Duration.zero);

Future<void> _search(GuidedWebSearchClient client, {String? onlyModel}) =>
    client.search(
      apiKey: 'secret-key',
      system: 'system prompt',
      text: 'user text',
      onlyModel: onlyModel,
    );

void main() {
  test(
    'sends the search tool, the key in a header and nothing in the URL',
    () async {
      late http.Request seen;
      final client = _client((request) async {
        seen = request;
        return http.Response(_answer(), 200);
      });

      final research = await client.search(
        apiKey: 'secret-key',
        system: 'system prompt',
        text: 'user text',
      );

      expect(
        seen.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-2.5-flash:generateContent',
      );
      expect(seen.headers['x-goog-api-key'], 'secret-key');
      expect(seen.url.toString(), isNot(contains('secret-key')));
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['tools'], [
        {'google_search': <String, Object?>{}},
      ]);
      expect(
        (((body['systemInstruction'] as Map)['parts'] as List).single
            as Map)['text'],
        'system prompt',
      );
      expect(
        ((((body['contents'] as List).single as Map)['parts'] as List).single
            as Map)['text'],
        'user text',
      );
      expect(research.text, 'per 100 g: 250 kcal');
      expect(research.sources.single.title, 'mcdonalds.de');
    },
  );

  test(
    'an overloaded model hands over to the next, which is then asked first',
    () async {
      final asked = <String>[];
      final client = _client((request) async {
        final model = request.url.pathSegments.last.split(':').first;
        asked.add(model);
        return model == 'gemini-2.5-flash'
            ? http.Response('{}', 503)
            : http.Response(_answer(), 200);
      });

      await _search(client);
      await _search(client);

      expect(asked, [
        'gemini-2.5-flash',
        'gemini-2.5-flash-lite',
        'gemini-2.5-flash-lite',
      ]);
    },
  );

  test(
    'when every model is overloaded the last failure is the one raised',
    () async {
      final client = _client((_) async => http.Response('{}', 429));

      await expectLater(
        _search(client),
        throwsA(
          isA<MealInterpreterException>().having(
            (e) => e.statusCode,
            'status',
            429,
          ),
        ),
      );
    },
  );

  test('a rejected key is not retried on another model', () async {
    var calls = 0;
    final client = _client((_) async {
      calls++;
      return http.Response(
        jsonEncode({
          'error': {
            'message': 'API key not valid. Please pass a valid API key.',
          },
        }),
        400,
      );
    });

    await expectLater(
      _search(client),
      throwsA(
        isA<MealInterpreterException>().having(
          (e) => e.failure,
          'failure',
          MealInterpreterFailure.auth,
        ),
      ),
    );
    expect(calls, 1);
  });

  test('onlyModel asks that model and no other', () async {
    final asked = <String>[];
    final client = _client((request) async {
      asked.add(request.url.pathSegments.last);
      return http.Response('{}', 503);
    });

    await expectLater(
      _search(client, onlyModel: 'gemini-2.5-flash-lite'),
      throwsA(isA<MealInterpreterException>()),
    );
    expect(asked, ['gemini-2.5-flash-lite:generateContent']);
  });

  group('through the ChatGPT plan', () {
    String event(Object payload) => 'data: ${jsonEncode(payload)}\n\n';

    final searchCall = {
      'type': 'web_search_call',
      'action': {'type': 'search', 'query': 'big mac naehrwerte'},
    };
    final message = {
      'type': 'message',
      'content': [
        {
          'type': 'output_text',
          'text': 'per 100 g: 257 kcal',
          'annotations': [
            {'type': 'url_citation', 'url': 'https://www.mcdonalds.de/x'},
          ],
        },
      ],
    };

    http.Response stream(List<Object> events) => http.Response(
      events.map(event).join(),
      200,
      headers: {'content-type': 'text/event-stream; charset=utf-8'},
    );

    http.Response completed([List<Object?>? output]) => stream([
      {'type': 'response.output_item.done', 'item': searchCall},
      {'type': 'response.output_item.done', 'item': message},
      {
        'type': 'response.completed',
        'response': {
          'output': output ?? [searchCall, message],
        },
      },
    ]);

    GuidedWebSearchClient chatGptClient(
      Future<http.Response> Function(http.Request request) handler, {
      ChatGptTokenSource? tokens,
    }) => GuidedWebSearchClient(
      MockClient(handler),
      retryDelay: Duration.zero,
      chatGpt: tokens ?? _Tokens(),
    );

    Future<GuidedWebResearch> run(GuidedWebSearchClient client) =>
        client.searchWithChatGpt(
          modelId: 'gpt-a',
          system: 'system prompt',
          text: 'user text',
        );

    test(
      'sends the search tool, the token and only the fields it needs',
      () async {
        late http.Request seen;
        final client = chatGptClient((request) async {
          seen = request;
          return completed();
        });

        final research = await run(client);

        expect(seen.url.toString(), 'https://api.openai.com/v1/responses');
        expect(seen.headers['authorization'], 'Bearer token-0');
        final body = jsonDecode(seen.body) as Map<String, dynamic>;
        expect(body.keys.toSet(), {
          'model',
          'instructions',
          'input',
          'tools',
          'store',
          'stream',
        });
        expect(body['model'], 'gpt-a');
        expect(body['instructions'], 'system prompt');
        expect(body['tools'], [
          {'type': 'web_search'},
        ]);
        expect(body['store'], isFalse);
        expect(body['stream'], isTrue);
        expect(
          ((((body['input'] as List).single as Map)['content'] as List).single
              as Map)['text'],
          'user text',
        );
        expect(research.text, 'per 100 g: 257 kcal');
        expect(research.queries, ['big mac naehrwerte']);
        expect(research.sources.single.title, 'mcdonalds.de');
      },
    );

    test(
      'a completed event with an empty output falls back to the finished items',
      () async {
        final client = chatGptClient((_) async => completed(<Object?>[]));

        final research = await run(client);

        expect(research.text, 'per 100 g: 257 kcal');
        expect(research.queries, ['big mac naehrwerte']);
      },
    );

    test('a stale token is replaced once and the search is repeated', () async {
      final tokens = _Tokens();
      final seen = <String?>[];
      final client = chatGptClient((request) async {
        seen.add(request.headers['authorization']);
        return seen.length == 1 ? http.Response('{}', 401) : completed();
      }, tokens: tokens);

      final research = await run(client);

      expect(seen, ['Bearer token-0', 'Bearer token-1']);
      expect(tokens.refreshes, 1);
      expect(research.text, isNotEmpty);
    });

    test('a token that is refused twice is a rejected credential', () async {
      var calls = 0;
      final client = chatGptClient((_) async {
        calls++;
        return http.Response('{}', 401);
      });

      await expectLater(
        run(client),
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
      'a sign-in that is no longer valid is a rejected credential',
      () async {
        final client = chatGptClient(
          (_) async => completed(),
          tokens: _Tokens(fails: true),
        );

        await expectLater(
          run(client),
          throwsA(
            isA<MealInterpreterException>().having(
              (e) => e.failure,
              'failure',
              MealInterpreterFailure.auth,
            ),
          ),
        );
      },
    );

    test('without any sign-in source the route is closed', () async {
      final client = GuidedWebSearchClient(
        MockClient((_) async => completed()),
      );

      await expectLater(
        run(client),
        throwsA(
          isA<MealInterpreterException>().having(
            (e) => e.failure,
            'failure',
            MealInterpreterFailure.auth,
          ),
        ),
      );
    });

    test('a failed response is raised, a rate limit as such', () async {
      final client = chatGptClient((_) async => http.Response('{}', 429));

      await expectLater(
        run(client),
        throwsA(
          isA<MealInterpreterException>().having(
            (e) => e.statusCode,
            'status',
            429,
          ),
        ),
      );
    });

    test(
      'a stream that fails, is cut short or says nothing is refused',
      () async {
        for (final answer in <http.Response>[
          stream([
            {
              'type': 'response.failed',
              'response': {
                'error': {'message': 'boom'},
              },
            },
          ]),
          stream([
            {'type': 'response.incomplete'},
          ]),
          stream([
            {'type': 'response.output_item.done', 'item': message},
          ]),
          http.Response('', 200),
          stream([
            {
              'type': 'response.completed',
              'response': {'output': <Object?>[]},
            },
          ]),
        ]) {
          final client = chatGptClient((_) async => answer);

          await expectLater(
            run(client),
            throwsA(isA<MealInterpreterException>()),
          );
        }
      },
    );
  });

  test('a reply without any text is refused', () async {
    final client = _client(
      (_) async => http.Response(jsonEncode({'candidates': <Object?>[]}), 200),
    );

    await expectLater(
      _search(client, onlyModel: 'gemini-2.5-flash'),
      throwsA(
        isA<MealInterpreterException>().having(
          (e) => e.failure,
          'failure',
          MealInterpreterFailure.unsupported,
        ),
      ),
    );
  });
}
