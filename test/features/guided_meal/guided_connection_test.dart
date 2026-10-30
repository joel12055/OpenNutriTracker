import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/guided_meal/data/guided_tool_client.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_schemas.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_service.dart';

class _MapStorage implements FlutterSecureStorage {
  final Map<String, String> values;

  _MapStorage(Map<String, String> values)
    : values = {'AiTermsAcceptedTag': 'true', ...values};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _gemini = AiSelection(provider: AiProvider.gemini, apiKey: 'k');

GuidedToolRequest _request({Duration? timeout}) => GuidedToolRequest(
  system: 's',
  text: 't',
  toolName: 'ask_meal_questions',
  toolDescription: 'd',
  schema: askQuestionsSchema,
  timeout: timeout,
);

String _ok() => jsonEncode({
  'choices': [
    {
      'message': {
        'tool_calls': [
          {
            'function': {
              'name': 'ask_meal_questions',
              'arguments': jsonEncode({'summary': 'x', 'questions': []}),
            },
          },
        ],
      },
    },
  ],
});

String _model(http.Request request) =>
    (jsonDecode(request.body) as Map)['model'] as String;

void main() {
  group('silence', () {
    test('a model that never answers is skipped for the next', () async {
      final asked = <String>[];
      final client = GuidedToolClient(
        MockClient((request) async {
          final model = _model(request);
          asked.add(model);
          if (model == 'gemini-3.6-flash') {
            // Never completes within the request's wait.
            return Completer<http.Response>().future;
          }
          return http.Response(_ok(), 200);
        }),
        retryDelay: Duration.zero,
      );

      await client.call(
        _gemini,
        _request(timeout: const Duration(milliseconds: 50)),
      );

      expect(asked, ['gemini-3.6-flash', 'gemini-3.5-flash-lite']);
    });

    test('the model that answered is asked first next time', () async {
      final asked = <String>[];
      final client = GuidedToolClient(
        MockClient((request) async {
          final model = _model(request);
          asked.add(model);
          return model == 'gemini-3.6-flash'
              ? http.Response('{}', 503)
              : http.Response(_ok(), 200);
        }),
        retryDelay: Duration.zero,
      );

      await client.call(_gemini, _request());
      asked.clear();
      await client.call(_gemini, _request());

      expect(asked, ['gemini-3.5-flash-lite']);
    });

    test(
      'onlyModel asks that model and nothing else, and remembers nothing',
      () async {
        final asked = <String>[];
        final client = GuidedToolClient(
          MockClient((request) async {
            asked.add(_model(request));
            return http.Response('{}', 503);
          }),
          retryDelay: Duration.zero,
        );

        await expectLater(
          client.call(_gemini, _request(), onlyModel: 'gemini-3.5-flash-lite'),
          throwsA(anything),
        );

        expect(asked, ['gemini-3.5-flash-lite']);
        expect(client.modelsFor(_gemini).first, 'gemini-3.6-flash');
      },
    );
  });

  group('testConnection', () {
    GuidedMealService service(
      Future<http.Response> Function(http.Request) handler,
    ) => GuidedMealService(
      AiCredentialStorage(
        _MapStorage({
          'AiProviderTag': 'gemini',
          'AiApiKeyTag.gemini': 'k',
          'AiAssistEnabledTag': 'true',
        }),
      ),
      GuidedToolClient(MockClient(handler), retryDelay: Duration.zero),
    );

    test('reports each model on its own, without falling back', () async {
      final results = await service((request) async {
        switch (_model(request)) {
          case 'gemini-3.6-flash':
            return http.Response('{"error":{"message":"overloaded"}}', 503);
          default:
            return http.Response(_ok(), 200);
        }
      }).testConnection();

      final byModel = {for (final r in results) r.model: r};
      expect(
        byModel['gemini-3.6-flash']!.outcome,
        GuidedProbeOutcome.overloaded,
      );
      expect(byModel['gemini-3.6-flash']!.statusCode, 503);
      expect(byModel['gemini-3.5-flash-lite']!.outcome, GuidedProbeOutcome.ok);
    });

    test('a missing model is reported as such', () async {
      final results = await service(
        (_) async => http.Response('{}', 404),
      ).testConnection();

      expect(
        results.map((r) => r.outcome),
        everyElement(GuidedProbeOutcome.missing),
      );
    });

    test('a rejected key is told apart from an overload', () async {
      final results = await service(
        (_) async =>
            http.Response('{"error":{"message":"API key not valid."}}', 400),
      ).testConnection();

      expect(
        results.map((r) => r.outcome),
        everyElement(GuidedProbeOutcome.auth),
      );
    });

    test('a reply without a tool call still counts as an answer', () async {
      final results = await service(
        (_) async => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'pong'},
              },
            ],
          }),
          200,
        ),
      ).testConnection();

      expect(
        results.map((r) => r.outcome),
        everyElement(GuidedProbeOutcome.ok),
      );
    });
  });

  group('reasoning effort', () {
    String reply(String tool, Object arguments) => jsonEncode({
      'choices': [
        {
          'message': {
            'tool_calls': [
              {
                'function': {'name': tool, 'arguments': jsonEncode(arguments)},
              },
            ],
          },
        },
      ],
    });

    GuidedMealService service(List<String> efforts) => GuidedMealService(
      AiCredentialStorage(
        _MapStorage({
          'AiProviderTag': 'gemini',
          'AiApiKeyTag.gemini': 'k',
          'AiAssistEnabledTag': 'true',
        }),
      ),
      GuidedToolClient(
        MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          efforts.add(body['reasoning_effort'] as String);
          final tool =
              ((body['tools'] as List).single as Map)['function']['name'];
          return http.Response(
            tool == 'ask_meal_questions'
                ? reply(tool as String, {'summary': 'x', 'questions': []})
                : reply(tool as String, {
                    'items': [
                      {'name': 'Erbsen', 'grams': 60},
                    ],
                  }),
            200,
          );
        }),
        retryDelay: Duration.zero,
      ),
    );

    final photo = MealPhoto(
      bytes: Uint8List.fromList([1, 2, 3]),
      mediaType: 'image/webp',
    );

    test('the questions get medium and the estimate gets high', () async {
      final efforts = <String>[];
      final guided = service(efforts);

      final analysis = await guided.analyze(photo: photo);
      await guided.estimate(
        photo: photo,
        analysis: analysis,
        answers: const {},
        unknownLabel: 'Weiß ich nicht',
      );

      expect(efforts, ['medium', 'high']);
    });

    test('the connection test stays at the lowest level', () async {
      final efforts = <String>[];

      await service(efforts).testConnection();

      expect(efforts, everyElement('low'));
    });
  });
}
