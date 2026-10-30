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
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_schemas.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_service.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_review.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_second_provider.dart';
import 'package:opennutritracker/features/guided_meal/presentation/guided_meal_cubit.dart';
import 'package:opennutritracker/features/settings/presentation/widgets/auto_second_opinion_selector.dart';
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
  String name = 'Spaghetti Carbonara',
  num grams = 350,
  String confidence = 'medium',
  num kcal = 215,
}) => {
  'name': name,
  'grams': grams,
  'confidence': confidence,
  'kcal_per_100g': kcal,
  'protein_per_100g': 9,
  'carbs_per_100g': 24,
  'fat_per_100g': 9,
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

/// Gemini is in use and ChatGPT is signed in, so ChatGPT is the second one.
/// [calls] records which provider got which tool.
class _Setup {
  final calls = <String>[];
  final bodies = <Map<String, dynamic>>[];
  late final GuidedMealService service;
  late final AiCredentialStorage storage;

  /// What the second assistant answers; null for the default review.
  http.Response Function()? reviewAnswer;
  http.Response Function()? decideAnswer;
  bool firstUncertain = true;

  _Setup({String mode = 'always', bool withSecond = true}) {
    storage = AiCredentialStorage(
      _MapStorage({
        'AiProviderTag': 'gemini',
        'AiApiKeyTag.gemini': 'k',
        'AiAssistEnabledTag': 'true',
        if (withSecond)
          'AiApiKeyTag.chatgpt': AiCredentialStorage.chatGptSessionMarker,
        'AiAutoSecondOpinionTag': mode,
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
                'summary': 'Carbonara',
                'questions': [
                  {
                    'id': 'q1',
                    'text': 'Wie viel Speck?',
                    'options': [
                      {'id': 'a', 'label': 'Wenig'},
                      {'id': 'b', 'label': 'Viel'},
                    ],
                  },
                ],
              });
            case estimateMealToolName:
              return answer({
                'items': [_item(confidence: firstUncertain ? 'low' : 'high')],
              });
            case reviewMealToolName:
              return reviewAnswer?.call() ??
                  answer({
                    'items': [_item(grams: 400, kcal: 190)],
                    'remarks': 'Portion eher größer, BLS nennt 190 kcal.',
                  });
            default:
              return decideAnswer?.call() ??
                  answer({
                    'items': [_item(grams: 390, kcal: 200)],
                    'verdict': 'Beide Werte gemittelt.',
                  });
          }
        }),
        retryDelay: Duration.zero,
        chatGpt: _Tokens(),
      ),
    );
  }

  Future<void> prepare() async {
    await storage.writeModel('gpt-a', provider: AiProvider.chatgpt);
  }

  Future<GuidedMealCubit> reachEstimate() async {
    await prepare();
    final cubit = GuidedMealCubit(service);
    cubit.setPhoto(_photo);
    await cubit.analyze();
    final analysis = (cubit.state as GuidedQuestionsState).analysis;
    cubit.selectOption(analysis.questions.single, 'b');
    await cubit.estimate(unknownLabel: 'Weiß ich nicht');
    return cubit;
  }
}

void main() {
  group('who is asked', () {
    test('the first usable provider other than the one in use', () async {
      final setup = _Setup();
      await setup.prepare();

      final second = await findSecondaryProvider(setup.storage);

      expect(second?.provider, AiProvider.chatgpt);
      expect(second?.name, 'ChatGPT');
    });

    test('nobody when only one provider is set up', () async {
      final setup = _Setup(withSecond: false);
      await setup.prepare();

      expect(await findSecondaryProvider(setup.storage), isNull);
    });

    test('a ChatGPT sign-in without a chosen model does not count', () async {
      final setup = _Setup();
      // The model is what makes the provider usable; without it, no second.
      expect(await findSecondaryProvider(setup.storage), isNull);
    });

    test(
      'the setting reads as off unless it names one of the two modes',
      () async {
        final storage = AiCredentialStorage(_MapStorage({}));
        expect(await storage.readAutoSecondOpinion(), 'off');

        await storage.writeAutoSecondOpinion('uncertain');
        expect(await storage.readAutoSecondOpinion(), 'uncertain');

        await storage.writeAutoSecondOpinion('nonsense');
        expect(await storage.readAutoSecondOpinion(), 'off');
      },
    );

    test('deleting all data turns it off again', () async {
      final storage = AiCredentialStorage(_MapStorage({}));
      await storage.writeAutoSecondOpinion('always');

      await storage.clearAll();

      expect(await storage.readAutoSecondOpinion(), 'off');
    });
  });

  group('the flow', () {
    test('off: the first estimate stands and nobody else is asked', () async {
      final setup = _Setup(mode: 'off');

      final cubit = await setup.reachEstimate();

      final done = cubit.state as GuidedDoneState;
      expect(done.secondOpinionBy, isNull);
      expect(done.estimate.items.single.grams, 350);
      expect(setup.calls.where((c) => c.startsWith('chatgpt')), isEmpty);
    });

    test(
      'always: the other provider reviews and the first one decides',
      () async {
        final setup = _Setup(mode: 'always');
        setup.firstUncertain = false;

        final cubit = await setup.reachEstimate();

        expect(setup.calls, [
          'gemini:$askQuestionsToolName',
          'gemini:$estimateMealToolName',
          'chatgpt:$reviewMealToolName',
          'gemini:$decideMealToolName',
        ]);
        final done = cubit.state as GuidedDoneState;
        expect(done.secondOpinionBy, 'ChatGPT');
        expect(done.verdict, 'Beide Werte gemittelt.');
        expect(done.estimate.items.single.grams, 390);
        expect(done.secondOpinionFailed, isFalse);
      },
    );

    test('the decision is shown what the second assistant said', () async {
      final setup = _Setup(mode: 'always');

      await setup.reachEstimate();

      final decideBody = setup.bodies.last;
      final text =
          (((decideBody['messages'] as List).last as Map)['content'] as List)
                  .first['text']
              as String;
      expect(text, contains('Second opinion from ChatGPT'));
      expect(text, contains('BLS nennt 190 kcal'));
      expect(text, contains('<second_opinion>'));
    });

    test('uncertain: only a doubtful estimate triggers it', () async {
      final sure = _Setup(mode: 'uncertain')..firstUncertain = false;
      final sureCubit = await sure.reachEstimate();
      expect((sureCubit.state as GuidedDoneState).secondOpinionBy, isNull);
      expect(sure.calls.where((c) => c.startsWith('chatgpt')), isEmpty);

      final unsure = _Setup(mode: 'uncertain');
      final unsureCubit = await unsure.reachEstimate();
      expect((unsureCubit.state as GuidedDoneState).secondOpinionBy, 'ChatGPT');
    });

    test('with no second provider the setting changes nothing', () async {
      final setup = _Setup(mode: 'always', withSecond: false);

      final cubit = await setup.reachEstimate();

      expect((cubit.state as GuidedDoneState).secondOpinionBy, isNull);
      expect(setup.calls.where((c) => c.startsWith('chatgpt')), isEmpty);
    });

    test(
      'a second opinion that fails ends in the first estimate, with a note',
      () async {
        final setup = _Setup(mode: 'always');
        setup.reviewAnswer = () => http.Response('{}', 401);

        final cubit = await setup.reachEstimate();

        final done = cubit.state as GuidedDoneState;
        expect(done.secondOpinionFailed, isTrue);
        expect(done.secondOpinionBy, isNull);
        expect(done.estimate.items.single.grams, 350);
      },
    );

    test(
      'a decision that fails after a good review also keeps the estimate',
      () async {
        final setup = _Setup(mode: 'always');
        setup.decideAnswer = () => http.Response('{}', 500);

        final cubit = await setup.reachEstimate();

        final done = cubit.state as GuidedDoneState;
        expect(done.secondOpinionFailed, isTrue);
        expect(done.estimate.items.single.grams, 350);
      },
    );

    test('the review gets the photo and the first estimate', () async {
      final setup = _Setup(mode: 'always');

      await setup.reachEstimate();

      final reviewBody = setup.bodies[2];
      final content =
          ((reviewBody['input'] as List).single as Map)['content'] as List;
      expect((content.first as Map)['type'], 'input_image');
      expect(
        (content.last as Map)['text'],
        contains('Spaghetti Carbonara: 350 g'),
      );
    });
  });

  group('the review', () {
    test('is read like an estimate, with its remarks', () {
      final review = guidedReviewFromJson({
        'items': [_item(grams: 400)],
        'remarks': '  Mehr Speck.  ',
      });

      expect(review.estimate.items.single.grams, 400);
      expect(review.remarks, 'Mehr Speck.');
    });

    test('with no food is refused', () {
      expect(
        () => guidedReviewFromJson({'items': <Object?>[], 'remarks': 'x'}),
        throwsA(anything),
      );
    });
  });

  group('the selector', () {
    Widget app(AiCredentialStorage storage) => MaterialApp(
      locale: const Locale('de'),
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: S.supportedLocales,
      home: Scaffold(body: AutoSecondOpinionSelector(storage: storage)),
    );

    testWidgets('names who would be asked, and stores the choice', (
      tester,
    ) async {
      final setup = _Setup(mode: 'off');
      await setup.prepare();
      await tester.pumpWidget(app(setup.storage));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Holt die Zweitmeinung selbst bei ChatGPT'),
        findsOneWidget,
      );

      await tester.tap(find.byType(DropdownButton<AutoSecondOpinion>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Immer').last);
      await tester.pumpAndSettle();

      expect(await setup.storage.readAutoSecondOpinion(), 'always');
    });

    testWidgets('says what is missing when there is no second provider', (
      tester,
    ) async {
      final setup = _Setup(withSecond: false);
      await setup.prepare();
      await tester.pumpWidget(app(setup.storage));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('zweiten eingerichteten Anbieter'),
        findsOneWidget,
      );
    });
  });
}
