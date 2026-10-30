import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/core/utils/chatgpt_auth.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/guided_meal/data/guided_tool_client.dart';
import 'package:opennutritracker/features/guided_meal/data/guided_web_search_client.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_entities.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_schemas.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_service.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_review.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_web_research.dart';
import 'package:opennutritracker/features/guided_meal/presentation/guided_meal_cubit.dart';
import 'package:opennutritracker/features/guided_meal/presentation/guided_result_view.dart';
import 'package:opennutritracker/features/settings/presentation/widgets/web_lookup_selector.dart';
import 'package:opennutritracker/generated/l10n.dart';

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
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values.remove(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tokens implements ChatGptTokenSource {
  @override
  Future<String> accessToken({bool forceRefresh = false}) async => 'token';
}

final _photo = MealPhoto(
  bytes: Uint8List.fromList([1, 2, 3]),
  mediaType: 'image/webp',
);

Map<String, Object?> _item({
  String name = 'Big Mac',
  num grams = 215,
  num kcal = 230,
  String? lookup = 'McDonalds Big Mac Naehrwerte pro 100 g',
}) => {
  'name': name,
  'grams': grams,
  'confidence': 'medium',
  'kcal_per_100g': kcal,
  'protein_per_100g': 12,
  'carbs_per_100g': 20,
  'fat_per_100g': 12,
  'lookup_query': ?lookup,
};

String _chat(String tool, Object arguments) => jsonEncode({
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

String _sse(String tool, Object arguments) =>
    'data: ${jsonEncode({
      'type': 'response.output_item.done',
      'item': {'type': 'function_call', 'name': tool, 'arguments': jsonEncode(arguments)},
    })}\n\n'
    'data: ${jsonEncode({
      'type': 'response.completed',
      'response': {'output': []},
    })}\n\n';

const _findings =
    '1. Big Mac\n   per 100 g: 257 kcal, protein 13, carbohydrates 20, fat 14\n'
    '   source: mcdonalds.de';

/// What the ChatGPT plan streams back for a search: the search, then the
/// answer with the page it cited.
String _searchSse() {
  final output = [
    {
      'type': 'web_search_call',
      'action': {'type': 'search', 'query': 'Big Mac Naehrwerte'},
    },
    {
      'type': 'message',
      'content': [
        {
          'type': 'output_text',
          'text': _findings,
          'annotations': [
            {'type': 'url_citation', 'url': 'https://www.mcdonalds.de/big-mac'},
          ],
        },
      ],
    },
  ];
  return [
    for (final item in output)
      'data: ${jsonEncode({'type': 'response.output_item.done', 'item': item})}\n\n',
    'data: ${jsonEncode({
      'type': 'response.completed',
      'response': {'output': output},
    })}\n\n',
  ].join();
}

/// Gemini is in use and ChatGPT is signed in, which is what runs the web
/// search; with [withSecond] the plan is also asked for the second opinion.
/// [calls] records who got what.
class _Setup {
  final calls = <String>[];
  final bodies = <Map<String, dynamic>>[];
  late final GuidedMealService service;
  late final AiCredentialStorage storage;

  http.Response Function()? searchAnswer;
  http.Response Function()? decideAnswer;
  bool withQuery = true;

  _Setup({bool web = true, bool withSecond = false}) {
    storage = AiCredentialStorage(
      _MapStorage({
        'AiProviderTag': 'gemini',
        'AiApiKeyTag.gemini': 'k',
        'AiApiKeyTag.chatgpt': AiCredentialStorage.chatGptSessionMarker,
        'AiAssistEnabledTag': 'true',
        if (web) 'AiWebLookupTag': 'on',
        if (withSecond) 'AiAutoSecondOpinionTag': 'always',
      }),
    );
    service = GuidedMealService(
      storage,
      GuidedToolClient(
        MockClient((request) async {
          final isStream = request.url.host == 'api.openai.com';
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final tool = isStream
              ? (body['tools'] as List).single['name'] as String
              : ((body['tools'] as List).single as Map)['function']['name']
                    as String;
          calls.add('${isStream ? 'chatgpt' : 'gemini'}:$tool');
          bodies.add(body);

          http.Response answer(Object arguments) => isStream
              ? http.Response(
                  _sse(tool, arguments),
                  200,
                  headers: {'content-type': 'text/event-stream; charset=utf-8'},
                )
              : http.Response(_chat(tool, arguments), 200);

          switch (tool) {
            case askQuestionsToolName:
              return answer({
                'summary': 'Burger',
                'questions': [
                  {
                    'id': 'q1',
                    'text': 'Wie gross?',
                    'options': [
                      {'id': 'a', 'label': 'Klein'},
                      {'id': 'b', 'label': 'Normal'},
                    ],
                  },
                ],
              });
            case estimateMealToolName:
              return answer({
                'items': [if (withQuery) _item() else _item(lookup: null)],
              });
            case reviewMealToolName:
              return answer({
                'items': [_item(kcal: 240)],
                'remarks': 'Eher 240 kcal.',
              });
            case 'ping':
              return answer({'ok': true});
            default:
              return decideAnswer?.call() ??
                  answer({
                    'items': [_item(kcal: 257, lookup: null)],
                    'verdict': 'Herstellerwert uebernommen.',
                  });
          }
        }),
        retryDelay: Duration.zero,
        chatGpt: _Tokens(),
      ),
      GuidedWebSearchClient(
        MockClient((request) async {
          calls.add('web:chatgpt');
          return searchAnswer?.call() ??
              http.Response(
                _searchSse(),
                200,
                headers: {'content-type': 'text/event-stream; charset=utf-8'},
              );
        }),
        _Tokens(),
      ),
    );
  }

  Future<GuidedMealCubit> reachEstimate() async {
    await storage.writeModel('gpt-a', provider: AiProvider.chatgpt);
    final cubit = GuidedMealCubit(service);
    cubit.setPhoto(_photo);
    await cubit.analyze();
    final analysis = (cubit.state as GuidedQuestionsState).analysis;
    cubit.selectOption(analysis.questions.single, 'b');
    await cubit.estimate(unknownLabel: 'Weiss ich nicht');
    return cubit;
  }

  String decisionText() {
    final body = bodies.last;
    return (((body['messages'] as List).last as Map)['content'] as List)
            .first['text']
        as String;
  }
}

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('de'),
  localizationsDelegates: const [
    S.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: S.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  group('availability', () {
    test('needs the switch on and a ChatGPT sign-in with a model', () async {
      final on = _Setup();
      expect(await on.service.webLookupAvailable(), isFalse);
      await on.storage.writeModel('gpt-a', provider: AiProvider.chatgpt);
      expect(await on.service.webLookupAvailable(), isTrue);

      final off = _Setup(web: false);
      await off.storage.writeModel('gpt-a', provider: AiProvider.chatgpt);
      expect(await off.service.webLookupAvailable(), isFalse);
    });

    test('the plan is enough, whichever provider is in use', () async {
      final storage = AiCredentialStorage(
        _MapStorage({
          'AiProviderTag': 'anthropic',
          'AiApiKeyTag.anthropic': 'sk',
          'AiApiKeyTag.chatgpt': AiCredentialStorage.chatGptSessionMarker,
          'AiAssistEnabledTag': 'true',
          'AiWebLookupTag': 'on',
        }),
      );
      await storage.writeModel('gpt-a', provider: AiProvider.chatgpt);
      final client = http.Client();
      addTearDown(client.close);
      final service = GuidedMealService(
        storage,
        GuidedToolClient(client),
        GuidedWebSearchClient(client, _Tokens()),
      );

      expect(await service.webLookupAvailable(), isTrue);
      expect(await service.webLookupDestination(), 'OpenAI');
    });

    test(
      'the queries go to OpenAI, and nowhere when the switch is off',
      () async {
        final on = _Setup();
        await on.storage.writeModel('gpt-a', provider: AiProvider.chatgpt);
        expect(await on.service.webLookupDestination(), 'OpenAI');

        final off = _Setup(web: false);
        await off.storage.writeModel('gpt-a', provider: AiProvider.chatgpt);
        expect(await off.service.webLookupDestination(), isNull);
      },
    );

    test('a Gemini key alone changes nothing', () async {
      final storage = AiCredentialStorage(
        _MapStorage({
          'AiProviderTag': 'gemini',
          'AiApiKeyTag.gemini': 'k',
          'AiAssistEnabledTag': 'true',
          'AiWebLookupTag': 'on',
        }),
      );
      final client = http.Client();
      addTearDown(client.close);
      final service = GuidedMealService(
        storage,
        GuidedToolClient(client),
        GuidedWebSearchClient(client, _Tokens()),
      );

      expect(await service.webLookupAvailable(), isFalse);
      expect(await service.webLookupDestination(), isNull);
    });

    test(
      'the setting reads as off, is stored, and deleting all data resets it',
      () async {
        final storage = AiCredentialStorage(_MapStorage({}));
        expect(await storage.readWebLookup(), 'off');

        await storage.writeWebLookup(true);
        expect(await storage.readWebLookup(), 'on');

        await storage.clearAll();
        expect(await storage.readWebLookup(), 'off');
      },
    );
  });

  group('the flow', () {
    test(
      'off: nothing is searched and the estimate is not asked for queries',
      () async {
        final setup = _Setup(web: false);

        final cubit = await setup.reachEstimate();

        expect(setup.calls, [
          'gemini:$askQuestionsToolName',
          'gemini:$estimateMealToolName',
        ]);
        final estimateSystem =
            ((setup.bodies[1]['messages'] as List).first as Map)['content']
                as String;
        expect(estimateSystem, isNot(contains('lookup_query')));
        final done = cubit.state as GuidedDoneState;
        expect(done.web, isNull);
        expect(done.webFailed, isFalse);
      },
    );

    test(
      'on: the model is asked for queries, the search runs, the decision weighs it',
      () async {
        final setup = _Setup();

        final cubit = await setup.reachEstimate();

        expect(setup.calls, [
          'gemini:$askQuestionsToolName',
          'gemini:$estimateMealToolName',
          'web:chatgpt',
          'gemini:$decideMealToolName',
        ]);
        final estimateSystem =
            ((setup.bodies[1]['messages'] as List).first as Map)['content']
                as String;
        expect(estimateSystem, contains('"lookup_query"'));

        final text = setup.decisionText();
        expect(text, contains('<web_research>'));
        expect(text, contains('257 kcal'));
        expect(text, isNot(contains('<second_opinion>')));

        final done = cubit.state as GuidedDoneState;
        expect(done.web?.sources.single.title, 'mcdonalds.de');
        expect(done.verdict, 'Herstellerwert uebernommen.');
        expect(done.estimate.items.single.fallbackNutrition?.kcal, 257);
        expect(done.secondOpinionBy, isNull);
        expect(done.webFailed, isFalse);
      },
    );

    test('the screen goes through searching and deciding', () async {
      final setup = _Setup();
      await setup.storage.writeModel('gpt-a', provider: AiProvider.chatgpt);
      final cubit = GuidedMealCubit(setup.service);
      final steps = <GuidedStep>[];
      cubit.stream.listen((state) {
        if (state is GuidedBusyState) steps.add(state.step);
      });
      cubit.setPhoto(_photo);
      await cubit.analyze();
      cubit.selectOption(
        (cubit.state as GuidedQuestionsState).analysis.questions.single,
        'b',
      );
      await cubit.estimate(unknownLabel: '?');
      await Future<void>.delayed(Duration.zero);

      expect(steps, [
        GuidedStep.analyzing,
        GuidedStep.estimating,
        GuidedStep.searching,
        GuidedStep.deciding,
      ]);
    });

    test(
      'a model that asked for no search costs no search and no extra decision',
      () async {
        final setup = _Setup()..withQuery = false;

        final cubit = await setup.reachEstimate();

        expect(setup.calls, [
          'gemini:$askQuestionsToolName',
          'gemini:$estimateMealToolName',
        ]);
        expect((cubit.state as GuidedDoneState).web, isNull);
      },
    );

    test('a search that fails ends in the estimate, with a note', () async {
      final setup = _Setup();
      setup.searchAnswer = () => http.Response('{}', 500);

      final cubit = await setup.reachEstimate();

      final done = cubit.state as GuidedDoneState;
      expect(done.webFailed, isTrue);
      expect(done.web, isNull);
      expect(done.estimate.items.single.fallbackNutrition?.kcal, 230);
      expect(setup.calls.where((c) => c.startsWith('gemini:decide')), isEmpty);
    });

    test(
      'a decision that fails after a good search keeps the estimate',
      () async {
        final setup = _Setup();
        setup.decideAnswer = () => http.Response('{}', 500);

        final cubit = await setup.reachEstimate();

        final done = cubit.state as GuidedDoneState;
        expect(done.webFailed, isTrue);
        expect(done.estimate.items.single.fallbackNutrition?.kcal, 230);
      },
    );

    test('with a second opinion as well, one decision gets both', () async {
      final setup = _Setup(withSecond: true);

      final cubit = await setup.reachEstimate();

      expect(setup.calls, [
        'gemini:$askQuestionsToolName',
        'gemini:$estimateMealToolName',
        'web:chatgpt',
        'chatgpt:$reviewMealToolName',
        'gemini:$decideMealToolName',
      ]);
      final text = setup.decisionText();
      expect(text, contains('<second_opinion>'));
      expect(text, contains('<web_research>'));
      expect(text, contains('257 kcal'));
      final done = cubit.state as GuidedDoneState;
      expect(done.secondOpinionBy, 'ChatGPT');
      expect(done.web?.sources.single.title, 'mcdonalds.de');
    });

    test(
      'a second opinion pasted in later is weighed together with the web findings',
      () async {
        final setup = _Setup();
        final cubit = await setup.reachEstimate();

        await cubit.decide(secondOpinion: 'Mehr Sosse.', unknownLabel: '?');

        final text = setup.decisionText();
        expect(text, contains('Mehr Sosse.'));
        expect(text, contains('<web_research>'));
        expect((cubit.state as GuidedDoneState).web, isNotNull);
      },
    );

    test('starting over forgets what was found', () async {
      final setup = _Setup();
      final cubit = await setup.reachEstimate();

      cubit.restart();
      await cubit.analyze();
      cubit.selectOption(
        (cubit.state as GuidedQuestionsState).analysis.questions.single,
        'b',
      );
      setup.withQuery = false;
      await cubit.estimate(unknownLabel: '?');

      expect((cubit.state as GuidedDoneState).web, isNull);
    });
  });

  group('the connection test', () {
    test('also asks the model of the plan with the search tool', () async {
      final setup = _Setup();
      await setup.storage.writeModel('gpt-a', provider: AiProvider.chatgpt);

      final results = await setup.service.testConnection();

      expect(
        results.where((r) => r.model.endsWith('+ web')).map((r) => r.model),
        ['gpt-a + web'],
      );
      expect(setup.calls.where((c) => c.startsWith('web:')), ['web:chatgpt']);
      expect(
        results.singleWhere((r) => r.model == 'gpt-a + web').outcome,
        GuidedProbeOutcome.ok,
      );
    });

    test(
      'a search that answers with nothing is not a working search',
      () async {
        final setup = _Setup();
        await setup.storage.writeModel('gpt-a', provider: AiProvider.chatgpt);
        setup.searchAnswer = () => http.Response(
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {'output': <Object?>[]},
          })}\n\n',
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        );

        final results = await setup.service.testConnection();

        expect(
          results.singleWhere((r) => r.model == 'gpt-a + web').outcome,
          isNot(GuidedProbeOutcome.ok),
        );
      },
    );

    test('says so when the plan cannot search', () async {
      final setup = _Setup();
      await setup.storage.writeModel('gpt-a', provider: AiProvider.chatgpt);
      setup.searchAnswer = () => http.Response('{}', 401);

      final results = await setup.service.testConnection();

      expect(
        results.singleWhere((r) => r.model == 'gpt-a + web').outcome,
        GuidedProbeOutcome.auth,
      );
    });

    test('leaves the search out when it is off', () async {
      final setup = _Setup(web: false);
      await setup.storage.writeModel('gpt-a', provider: AiProvider.chatgpt);

      final results = await setup.service.testConnection();

      expect(results.where((r) => r.model.endsWith('+ web')), isEmpty);
      expect(setup.calls.where((c) => c.startsWith('web:')), isEmpty);
    });
  });

  group('the settings switch', () {
    testWidgets('stores the choice', (tester) async {
      final setup = _Setup(web: false);
      await setup.storage.writeModel('gpt-a', provider: AiProvider.chatgpt);
      await tester.pumpWidget(_app(WebLookupSelector(storage: setup.storage)));
      await tester.pumpAndSettle();

      expect(find.text('Websuche für unbekannte Lebensmittel'), findsOneWidget);
      expect(find.textContaining('nie das Foto'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(await setup.storage.readWebLookup(), 'on');

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(await setup.storage.readWebLookup(), 'off');
    });

    testWidgets(
      'is disabled and says what is missing without a ChatGPT sign-in',
      (tester) async {
        final storage = AiCredentialStorage(
          _MapStorage({
            'AiProviderTag': 'anthropic',
            'AiApiKeyTag.anthropic': 'sk',
            'AiApiKeyTag.gemini': 'k',
            'AiAssistEnabledTag': 'true',
            'AiWebLookupTag': 'on',
          }),
        );
        await tester.pumpWidget(_app(WebLookupSelector(storage: storage)));
        await tester.pumpAndSettle();

        expect(find.textContaining('ChatGPT-Anmeldung'), findsOneWidget);
        final switchWidget = tester.widget<Switch>(find.byType(Switch));
        expect(switchWidget.onChanged, isNull);
        expect(switchWidget.value, isFalse);
      },
    );
  });

  group('the result', () {
    GuidedResultView view({GuidedWebResearch? web, bool webFailed = false}) =>
        GuidedResultView(
          estimate: const GuidedEstimate(
            items: [GuidedEstimateItem(name: 'Big Mac', grams: 215)],
          ),
          photo: null,
          buildPrompt: () => '',
          onContinue: () {},
          onSubmitSecondOpinion: (_) {},
          web: web,
          webFailed: webFailed,
        );

    testWidgets('says what was searched for and which sites were used', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          view(
            web: const GuidedWebResearch(
              text: 'x',
              queries: ['Big Mac Naehrwerte'],
              sources: [
                GuidedWebSource(
                  title: 'mcdonalds.de',
                  url: 'https://g.example/1',
                ),
                GuidedWebSource(title: 'fddb.net', url: 'https://g.example/2'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Im Web nachgeschlagen'), findsOneWidget);
      expect(find.text('Gesucht nach: Big Mac Naehrwerte'), findsOneWidget);
      expect(find.text('Quellen: mcdonalds.de, fddb.net'), findsOneWidget);
    });

    testWidgets('says so when the search did not come', (tester) async {
      await tester.pumpWidget(_app(view(webFailed: true)));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Websuche hat nicht geklappt'),
        findsOneWidget,
      );
      expect(find.text('Im Web nachgeschlagen'), findsNothing);
    });

    testWidgets('shows nothing about the web when there was none', (
      tester,
    ) async {
      await tester.pumpWidget(_app(view()));
      await tester.pumpAndSettle();

      expect(find.text('Im Web nachgeschlagen'), findsNothing);
      expect(find.textContaining('Websuche'), findsNothing);
    });
  });
}
