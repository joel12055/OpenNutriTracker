import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/core/utils/chatgpt_auth.dart';
import 'package:opennutritracker/core/utils/chatgpt_session_store.dart';
import 'package:opennutritracker/features/settings/presentation/widgets/chatgpt_sign_in_section.dart';
import 'package:opennutritracker/generated/l10n.dart';

class _MemoryStorage implements FlutterSecureStorage {
  final values = <String, String>{};

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

/// A sign-in that does what the test says, without a browser or a network.
class _FakeAuth extends ChatGptAuth {
  final _MemoryStorage backing;
  final models = const ['codex-x', 'gpt-a', 'gpt-b'];
  Object? signInFails;
  var signIns = 0;

  _FakeAuth(this.backing)
    : super(
        MockClient((_) async => throw StateError('no network')),
        ChatGptSessionStore(backing),
      );

  @override
  Future<ChatGptSession> signIn({String agentName = 'OpenNutriTracker'}) async {
    signIns++;
    final failure = signInFails;
    if (failure != null) throw failure;
    final session = ChatGptSession(
      clientId: 'oaiapp_test',
      accessToken: 'a',
      refreshToken: 'r',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      email: 'joel@example.com',
    );
    await ChatGptSessionStore(backing).write(session);
    return session;
  }

  @override
  Future<List<String>> listModels() async => models;
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
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  late _MemoryStorage backing;
  late AiCredentialStorage storage;
  late _FakeAuth auth;
  late int changes;
  late bool agreed;

  setUp(() async {
    backing = _MemoryStorage();
    storage = AiCredentialStorage(backing);
    auth = _FakeAuth(backing);
    changes = 0;
    agreed = true;
    // Using a credential requires the agreement to have been given.
    await storage.setTermsAccepted(true);
  });

  Widget section() => _app(
    ChatGptSignInSection(
      storage: storage,
      auth: auth,
      ensureAgreed: () async => agreed,
      onChanged: () => changes++,
    ),
  );

  group('pickDefaultChatGptModel', () {
    test('prefers the model the sign-in documentation names', () {
      expect(
        pickDefaultChatGptModel(['codex-x', 'gpt-6.1-sol', 'gpt-a']),
        'gpt-6.1-sol',
      );
    });

    test('otherwise the first that is not a coding-only model', () {
      expect(pickDefaultChatGptModel(['codex-x', 'gpt-a']), 'gpt-a');
    });

    test('otherwise the first, and nothing for nothing', () {
      expect(pickDefaultChatGptModel(['codex-only']), 'codex-only');
      expect(pickDefaultChatGptModel(const []), isNull);
    });
  });

  testWidgets('offers the sign-in when nobody is signed in', (tester) async {
    await tester.pumpWidget(section());
    await tester.pumpAndSettle();

    expect(find.text('Mit ChatGPT anmelden'), findsOneWidget);
    expect(find.textContaining('Angemeldet als'), findsNothing);
  });

  testWidgets('signing in stores the marker and a model, and says so', (
    tester,
  ) async {
    await tester.pumpWidget(section());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mit ChatGPT anmelden'));
    await tester.pumpAndSettle();

    expect(auth.signIns, 1);
    expect(changes, greaterThan(0));
    expect(find.text('Angemeldet als joel@example.com'), findsOneWidget);
    // The key slot holds the marker, so the provider counts as having a
    // credential, and the first model that is not coding-only was chosen.
    expect(
      await storage.readApiKey(provider: AiProvider.chatgpt),
      AiCredentialStorage.chatGptSessionMarker,
    );
    expect(await storage.readModel(provider: AiProvider.chatgpt), 'gpt-a');
  });

  testWidgets('without the agreement nothing happens', (tester) async {
    agreed = false;
    await tester.pumpWidget(section());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mit ChatGPT anmelden'));
    await tester.pumpAndSettle();

    expect(auth.signIns, 0);
    expect(await storage.readApiKey(provider: AiProvider.chatgpt), isNull);
  });

  testWidgets('a refused sign-in says why and stores nothing', (tester) async {
    auth.signInFails = const ChatGptAuthException(
      ChatGptAuthProblem.noPlanUsage,
    );
    await tester.pumpWidget(section());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mit ChatGPT anmelden'));
    await tester.pumpAndSettle();

    expect(find.textContaining('ChatGPT-Plus- oder -Pro-Abo'), findsOneWidget);
    expect(await storage.readApiKey(provider: AiProvider.chatgpt), isNull);
    // Still offered, so it can be tried again.
    expect(find.text('Mit ChatGPT anmelden'), findsOneWidget);
  });

  testWidgets('a sign-in that fails unexpectedly is reported, not thrown', (
    tester,
  ) async {
    auth.signInFails = StateError('boom');
    await tester.pumpWidget(section());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mit ChatGPT anmelden'));
    await tester.pumpAndSettle();

    expect(find.text('Mit ChatGPT anmelden'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a signed-in account shows its models and changing one is stored',
    (tester) async {
      await ChatGptSessionStore(backing).write(
        ChatGptSession(
          clientId: 'oaiapp_test',
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          email: 'joel@example.com',
        ),
      );
      await storage.writeModel('gpt-a', provider: AiProvider.chatgpt);
      await tester.pumpWidget(section());
      await tester.pumpAndSettle();

      expect(find.text('Angemeldet als joel@example.com'), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('gpt-b').last);
      await tester.pumpAndSettle();

      expect(await storage.readModel(provider: AiProvider.chatgpt), 'gpt-b');
      expect(changes, greaterThan(0));
    },
  );

  group('the provider as a whole', () {
    test('is usable only with a sign-in marker and a model', () async {
      await storage.writeApiKey(
        AiCredentialStorage.chatGptSessionMarker,
        provider: AiProvider.chatgpt,
      );
      await storage.setActiveProvider(AiProvider.chatgpt);
      expect(await storage.readSelection(), isNull);

      await storage.writeModel('gpt-a', provider: AiProvider.chatgpt);
      final selection = await storage.readSelection();

      expect(selection?.provider, AiProvider.chatgpt);
      expect(selection?.modelId, 'gpt-a');
    });

    test('removing it also signs out', () async {
      await ChatGptSessionStore(backing).write(
        ChatGptSession(
          clientId: 'oaiapp_test',
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
      );
      await storage.writeApiKey(
        AiCredentialStorage.chatGptSessionMarker,
        provider: AiProvider.chatgpt,
      );

      await storage.clear(provider: AiProvider.chatgpt);

      expect(await ChatGptSessionStore(backing).read(), isNull);
    });

    test('deleting all data removes the session and the host id', () async {
      final store = ChatGptSessionStore(backing);
      await store.writeHostId('urn:uuid:test');
      await store.write(
        ChatGptSession(
          clientId: 'oaiapp_test',
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
      );

      await storage.clearAll();

      expect(await store.read(), isNull);
      expect(await store.readHostId(), isNull);
      expect(
        backing.values.keys.where((k) => k.startsWith('ChatGpt')),
        isEmpty,
      );
    });
  });
}
