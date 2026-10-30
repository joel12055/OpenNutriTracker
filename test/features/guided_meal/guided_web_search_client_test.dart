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

String _event(Object payload) => 'data: ${jsonEncode(payload)}\n\n';

final _searchCall = {
  'type': 'web_search_call',
  'action': {'type': 'search', 'query': 'big mac naehrwerte'},
};

final _message = {
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

http.Response _stream(List<Object> events) => http.Response(
  events.map(_event).join(),
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

http.Response _completed([List<Object?>? output]) => _stream([
  {'type': 'response.output_item.done', 'item': _searchCall},
  {'type': 'response.output_item.done', 'item': _message},
  {
    'type': 'response.completed',
    'response': {
      'output': output ?? [_searchCall, _message],
    },
  },
]);

GuidedWebSearchClient _client(
  Future<http.Response> Function(http.Request request) handler, {
  ChatGptTokenSource? tokens,
}) => GuidedWebSearchClient(MockClient(handler), tokens ?? _Tokens());

Future<GuidedWebResearch> _search(GuidedWebSearchClient client) =>
    client.search(modelId: 'gpt-a', system: 'system prompt', text: 'user text');

void main() {
  test(
    'sends the search tool, the token and only the fields it needs',
    () async {
      late http.Request seen;
      final client = _client((request) async {
        seen = request;
        return _completed();
      });

      final research = await _search(client);

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
      final client = _client((_) async => _completed(<Object?>[]));

      final research = await _search(client);

      expect(research.text, 'per 100 g: 257 kcal');
      expect(research.queries, ['big mac naehrwerte']);
    },
  );

  test('a stale token is replaced once and the search is repeated', () async {
    final tokens = _Tokens();
    final seen = <String?>[];
    final client = _client((request) async {
      seen.add(request.headers['authorization']);
      return seen.length == 1 ? http.Response('{}', 401) : _completed();
    }, tokens: tokens);

    final research = await _search(client);

    expect(seen, ['Bearer token-0', 'Bearer token-1']);
    expect(tokens.refreshes, 1);
    expect(research.text, isNotEmpty);
  });

  test('a token that is refused twice is a rejected credential', () async {
    var calls = 0;
    final client = _client((_) async {
      calls++;
      return http.Response('{}', 401);
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
    expect(calls, 2);
  });

  test('a sign-in that is no longer valid is a rejected credential', () async {
    final client = _client(
      (_) async => _completed(),
      tokens: _Tokens(fails: true),
    );

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
  });

  test('a failed response is raised, a rate limit as such', () async {
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
  });

  test(
    'a stream that fails, is cut short or says nothing is refused',
    () async {
      for (final answer in <http.Response>[
        _stream([
          {
            'type': 'response.failed',
            'response': {
              'error': {'message': 'boom'},
            },
          },
        ]),
        _stream([
          {'type': 'response.incomplete'},
        ]),
        _stream([
          {'type': 'response.output_item.done', 'item': _message},
        ]),
        http.Response('', 200),
        _stream([
          {
            'type': 'response.completed',
            'response': {'output': <Object?>[]},
          },
        ]),
      ]) {
        final client = _client((_) async => answer);

        await expectLater(
          _search(client),
          throwsA(isA<MealInterpreterException>()),
        );
      }
    },
  );
}
