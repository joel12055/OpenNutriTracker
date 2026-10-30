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
import 'package:opennutritracker/features/settings/presentation/widgets/reasoning_level_selector.dart';
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

String _chatReply(String tool, Object arguments) => jsonEncode({
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

void main() {
  group('the stored level', () {
    test('is automatic until one is chosen', () async {
      final storage = AiCredentialStorage(_MapStorage({}));

      expect(await storage.readReasoningLevel(), isNull);
    });

    test('keeps one of the three levels and nothing else', () async {
      final storage = AiCredentialStorage(_MapStorage({}));

      await storage.writeReasoningLevel('high');
      expect(await storage.readReasoningLevel(), 'high');

      await storage.writeReasoningLevel('extreme');
      expect(await storage.readReasoningLevel(), isNull);

      await storage.writeReasoningLevel('low');
      await storage.writeReasoningLevel(null);
      expect(await storage.readReasoningLevel(), isNull);
    });

    test('is removed with all the other AI data', () async {
      final storage = AiCredentialStorage(_MapStorage({}));
      await storage.writeReasoningLevel('medium');

      await storage.clearAll();

      expect(await storage.readReasoningLevel(), isNull);
    });
  });

  group('what is sent', () {
    Future<List<Map<String, dynamic>>> geminiBodies(String? level) async {
      final bodies = <Map<String, dynamic>>[];
      final storage = AiCredentialStorage(
        _MapStorage({
          'AiProviderTag': 'gemini',
          'AiApiKeyTag.gemini': 'k',
          'AiAssistEnabledTag': 'true',
          'AiReasoningLevelTag': ?level,
        }),
      );
      final service = GuidedMealService(
        storage,
        GuidedToolClient(
          MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            bodies.add(body);
            final tool =
                ((body['tools'] as List).single as Map)['function']['name']
                    as String;
            return http.Response(
              tool == askQuestionsToolName
                  ? _chatReply(tool, {'summary': 'x', 'questions': []})
                  : _chatReply(tool, {
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
      final analysis = await service.analyze(photo: _photo);
      await service.estimate(
        photo: _photo,
        analysis: analysis,
        answers: const {},
        unknownLabel: '?',
      );
      return bodies;
    }

    test(
      'automatic means medium for the questions and high for the estimate',
      () async {
        final bodies = await geminiBodies(null);

        expect(bodies.map((b) => b['reasoning_effort']), ['medium', 'high']);
      },
    );

    test('a chosen level applies to every step', () async {
      final bodies = await geminiBodies('low');

      expect(bodies.map((b) => b['reasoning_effort']), ['low', 'low']);
    });

    Future<List<Map<String, dynamic>>> chatGptBodies(String? level) async {
      final bodies = <Map<String, dynamic>>[];
      final storage = AiCredentialStorage(
        _MapStorage({
          'AiProviderTag': 'chatgpt',
          'AiApiKeyTag.chatgpt': AiCredentialStorage.chatGptSessionMarker,
          'AiAssistEnabledTag': 'true',
          'AiReasoningLevelTag': ?level,
        }),
      );
      await storage.writeModel('gpt-a', provider: AiProvider.chatgpt);
      final service = GuidedMealService(
        storage,
        GuidedToolClient(
          MockClient((request) async {
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(
              _sse(askQuestionsToolName, {'summary': 'x', 'questions': []}),
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }),
          chatGpt: _Tokens(),
        ),
      );
      await service.analyze(photo: _photo);
      return bodies;
    }

    test(
      'the ChatGPT plan route is sent no level unless one was chosen',
      () async {
        final automatic = await chatGptBodies(null);
        expect(automatic.single.containsKey('reasoning'), isFalse);

        final chosen = await chatGptBodies('high');
        expect(chosen.single['reasoning'], {'effort': 'high'});
      },
    );
  });

  group('the destination of a photo', () {
    test('a ChatGPT plan is OpenAI, with or without a curated list', () async {
      final storage = AiCredentialStorage(
        _MapStorage({
          'AiProviderTag': 'chatgpt',
          'AiApiKeyTag.chatgpt': AiCredentialStorage.chatGptSessionMarker,
          'AiAssistEnabledTag': 'true',
        }),
      );
      await storage.writeModel('gpt-a', provider: AiProvider.chatgpt);
      final service = GuidedMealService(
        storage,
        GuidedToolClient(MockClient((_) async => http.Response('{}', 404))),
      );

      final destination = await service.destination();

      expect(destination?.provider, AiProvider.chatgpt);
      expect(destination?.name, 'OpenAI');
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
      home: Scaffold(body: ReasoningLevelSelector(storage: storage)),
    );

    testWidgets('starts on automatic and stores what is picked', (
      tester,
    ) async {
      final storage = AiCredentialStorage(_MapStorage({}));
      await tester.pumpWidget(app(storage));
      await tester.pumpAndSettle();

      expect(find.text('Automatisch'), findsOneWidget);

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hoch').last);
      await tester.pumpAndSettle();

      expect(await storage.readReasoningLevel(), 'high');
      expect(find.text('Hoch'), findsOneWidget);
    });

    testWidgets('shows a stored level and can go back to automatic', (
      tester,
    ) async {
      final storage = AiCredentialStorage(_MapStorage({}));
      await storage.writeReasoningLevel('low');
      await tester.pumpWidget(app(storage));
      await tester.pumpAndSettle();

      expect(find.text('Niedrig'), findsOneWidget);

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Automatisch').last);
      await tester.pumpAndSettle();

      expect(await storage.readReasoningLevel(), isNull);
    });
  });
}
