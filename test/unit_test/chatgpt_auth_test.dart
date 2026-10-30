import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opennutritracker/core/utils/chatgpt_auth.dart';
import 'package:opennutritracker/core/utils/chatgpt_session_store.dart';

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

String _b64(Object json) =>
    base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

String _idToken({
  required String clientId,
  required String nonce,
  String issuer = 'https://auth.openai.com',
  int? exp,
  String email = 'joel@example.com',
}) =>
    '${_b64({'alg': 'none'})}.'
    '${_b64({'iss': issuer, 'aud': clientId, 'nonce': nonce, 'exp': exp ?? DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000, 'sub': 'user-1', 'email': email})}.sig';

/// A "browser" that answers the sign-in the way OpenAI would: it reads the
/// request off the authorization URL and calls the loopback redirect back.
typedef _Browser = Future<bool> Function(Uri url);

class _Harness {
  final storage = _MemoryStorage();
  late final store = ChatGptSessionStore(storage);
  final authUrls = <Uri>[];
  final tokenForms = <Map<String, String>>[];

  /// What the browser was finally shown, once the sign-in had an outcome.
  final page = Completer<String>();
  // Real time, because the ID tokens built here carry real expiry dates.
  var now = DateTime.now().toUtc();

  /// What the token endpoint answers; return null for the default success.
  http.Response? Function(Map<String, String> form)? tokenAnswer;

  late final ChatGptAuth auth;

  _Harness({_Browser Function(_Harness)? browser, Completer<void>? gate}) {
    auth = ChatGptAuth(
      MockClient((request) async {
        if (request.url == ChatGptAuth.tokenEndpoint) {
          final form = request.bodyFields;
          tokenForms.add(form);
          final custom = tokenAnswer?.call(form);
          if (custom != null) return custom;
          return http.Response(
            jsonEncode({
              'access_token': 'access-${tokenForms.length}',
              'refresh_token': 'refresh-${tokenForms.length}',
              'expires_in': 3600,
              'scope': 'openid ${ChatGptAuth.planScope}',
              'id_token': _idToken(
                clientId: form['client_id']!,
                nonce: authUrls.last.queryParameters['nonce']!,
              ),
            }),
            200,
          );
        }
        if (request.url == ChatGptAuth.modelsEndpoint) {
          return http.Response(
            jsonEncode({
              'models': [
                {'slug': 'gpt-a', 'visibility': 'list'},
                {'slug': 'hidden-b', 'visibility': 'hide'},
                {'slug': 'gpt-c', 'visibility': 'list'},
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
      store,
      openBrowser: (browser ?? _approvingBrowser)(this),
      now: () => now,
      foreground: gate == null ? () async {} : () => gate.future,
    );
  }

  static _Browser _approvingBrowser(_Harness h) =>
      (url) => callBack(h, url, issuedClientId: 'oaiapp_test');

  /// Calls the redirect back with [extra] parameters, on a later turn of the
  /// event loop so the sign-in is already waiting for it.
  static Future<bool> callBack(
    _Harness h,
    Uri url, {
    String? issuedClientId,
    Map<String, String> extra = const {},
    bool wrongState = false,
  }) async {
    h.authUrls.add(url);
    final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
    final params = {
      'code': 'code-1',
      'state': wrongState ? 'not-the-state' : url.queryParameters['state']!,
      'client_id': ?issuedClientId,
      ...extra,
    };
    unawaited(
      Future(() async {
        final client = HttpClient();
        try {
          final request = await client.getUrl(
            redirect.replace(queryParameters: params),
          );
          final response = await request.close();
          final body = await utf8.decodeStream(response);
          if (!h.page.isCompleted) h.page.complete(body);
        } finally {
          client.close(force: true);
        }
      }),
    );
    return true;
  }
}

void main() {
  group('signIn', () {
    test(
      'registers, exchanges the code with PKCE and stores the session',
      () async {
        final h = _Harness();

        final session = await h.auth.signIn();

        final url = h.authUrls.single;
        final q = url.queryParameters;
        expect(url.origin + url.path, ChatGptAuth.authorizeEndpoint.toString());
        expect(q['client_id'], 'dynamic_agent_client');
        expect(q['agent_name_hint'], 'OpenNutriTracker');
        expect(q['ext_agent_host_id'], startsWith('urn:uuid:'));
        expect(q['response_type'], 'code');
        expect(q['resource'], ChatGptAuth.resource);
        expect(q['scope'], contains(ChatGptAuth.planScope));
        expect(q['scope'], contains('offline_access'));
        expect(q['code_challenge_method'], 'S256');
        expect(
          q['redirect_uri'],
          matches(r'^http://127\.0\.0\.1:\d+/auth/callback$'),
        );

        final form = h.tokenForms.single;
        expect(form['grant_type'], 'authorization_code');
        expect(form['client_id'], 'oaiapp_test');
        expect(form['code'], 'code-1');
        expect(form['redirect_uri'], q['redirect_uri']);
        // The verifier sent now must be the one the challenge committed to.
        final challenge = base64Url
            .encode(sha256.convert(utf8.encode(form['code_verifier']!)).bytes)
            .replaceAll('=', '');
        expect(challenge, q['code_challenge']);

        expect(session.clientId, 'oaiapp_test');
        expect(session.accessToken, 'access-1');
        expect(session.email, 'joel@example.com');
        expect((await h.store.read())!.refreshToken, 'refresh-1');
      },
    );

    test('a second sign-in reuses the issued id and the host id', () async {
      final h = _Harness();
      await h.auth.signIn();
      await h.auth.signIn();

      final second = h.authUrls.last.queryParameters;
      expect(second['client_id'], 'oaiapp_test');
      expect(second.containsKey('agent_name_hint'), isFalse);
      expect(
        second['ext_agent_host_id'],
        h.authUrls.first.queryParameters['ext_agent_host_id'],
      );
    });

    test('an answer that is not for this request is refused', () async {
      final h = _Harness(
        browser: (h) =>
            (url) => _Harness.callBack(
              h,
              url,
              issuedClientId: 'oaiapp_test',
              wrongState: true,
            ),
      );

      await expectLater(
        h.auth.signIn(),
        throwsA(
          isA<ChatGptAuthException>().having(
            (e) => e.problem,
            'problem',
            ChatGptAuthProblem.stateMismatch,
          ),
        ),
      );
      expect(h.tokenForms, isEmpty);
      expect(await h.store.read(), isNull);
    });

    test(
      'a refusal in the browser is a denial and exchanges nothing',
      () async {
        final h = _Harness(
          browser: (h) =>
              (url) =>
                  _Harness.callBack(h, url, extra: {'error': 'access_denied'}),
        );

        await expectLater(
          h.auth.signIn(),
          throwsA(
            isA<ChatGptAuthException>().having(
              (e) => e.problem,
              'problem',
              ChatGptAuthProblem.denied,
            ),
          ),
        );
        expect(h.tokenForms, isEmpty);
      },
    );

    test('a first sign-in without an issued app id is incomplete', () async {
      final h = _Harness(
        browser: (h) =>
            (url) => _Harness.callBack(h, url),
      );

      await expectLater(
        h.auth.signIn(),
        throwsA(
          isA<ChatGptAuthException>().having(
            (e) => e.problem,
            'problem',
            ChatGptAuthProblem.registrationIncomplete,
          ),
        ),
      );
    });

    test('a sign-in that grants no plan usage is refused', () async {
      final h = _Harness();
      h.tokenAnswer = (form) => http.Response(
        jsonEncode({
          'access_token': 'a',
          'refresh_token': 'r',
          'expires_in': 3600,
          'scope': 'openid profile',
          'id_token': _idToken(
            clientId: form['client_id']!,
            nonce: h.authUrls.last.queryParameters['nonce']!,
          ),
        }),
        200,
      );

      await expectLater(
        h.auth.signIn(),
        throwsA(
          isA<ChatGptAuthException>().having(
            (e) => e.problem,
            'problem',
            ChatGptAuthProblem.noPlanUsage,
          ),
        ),
      );
      expect(await h.store.read(), isNull);
    });

    test('an identity for another request or app is refused', () async {
      for (final bad in [
        (String client, String nonce) =>
            _idToken(clientId: client, nonce: 'someone-elses'),
        (String client, String nonce) =>
            _idToken(clientId: 'oaiapp_other', nonce: nonce),
        (String client, String nonce) => _idToken(
          clientId: client,
          nonce: nonce,
          issuer: 'https://evil.test',
        ),
        (String client, String nonce) =>
            _idToken(clientId: client, nonce: nonce, exp: 1000),
      ]) {
        final h = _Harness();
        h.tokenAnswer = (form) => http.Response(
          jsonEncode({
            'access_token': 'a',
            'refresh_token': 'r',
            'expires_in': 3600,
            'scope': ChatGptAuth.planScope,
            'id_token': bad(
              form['client_id']!,
              h.authUrls.last.queryParameters['nonce']!,
            ),
          }),
          200,
        );

        await expectLater(
          h.auth.signIn(),
          throwsA(
            isA<ChatGptAuthException>().having(
              (e) => e.problem,
              'problem',
              ChatGptAuthProblem.invalidIdToken,
            ),
          ),
        );
        expect(await h.store.read(), isNull);
      }
    });

    test('a browser that cannot open is reported', () async {
      final h = _Harness(
        browser: (_) =>
            (url) async => false,
      );

      await expectLater(
        h.auth.signIn(),
        throwsA(
          isA<ChatGptAuthException>().having(
            (e) => e.problem,
            'problem',
            ChatGptAuthProblem.browserUnavailable,
          ),
        ),
      );
    });
  });

  group('accessToken', () {
    Future<_Harness> signedIn() async {
      final h = _Harness();
      await h.auth.signIn();
      h.tokenForms.clear();
      return h;
    }

    test('a fresh token is returned without calling OpenAI', () async {
      final h = await signedIn();

      expect(await h.auth.accessToken(), 'access-1');
      expect(h.tokenForms, isEmpty);
    });

    test(
      'a token about to expire is refreshed and the new pair stored',
      () async {
        final h = await signedIn();
        h.now = h.now.add(const Duration(minutes: 59, seconds: 30));
        h.tokenAnswer = (_) => http.Response(
          jsonEncode({
            'access_token': 'access-new',
            'refresh_token': 'refresh-new',
            'expires_in': 3600,
          }),
          200,
        );

        expect(await h.auth.accessToken(), 'access-new');

        expect(h.tokenForms.single['grant_type'], 'refresh_token');
        expect(h.tokenForms.single['refresh_token'], 'refresh-1');
        final stored = (await h.store.read())!;
        expect(stored.refreshToken, 'refresh-new');
        // The account and the app id survive a refresh.
        expect(stored.email, 'joel@example.com');
        expect(stored.clientId, 'oaiapp_test');
      },
    );

    test('forceRefresh replaces a token that looks fresh', () async {
      final h = await signedIn();
      h.tokenAnswer = (_) => http.Response(
        jsonEncode({'access_token': 'access-forced', 'expires_in': 3600}),
        200,
      );

      expect(await h.auth.accessToken(forceRefresh: true), 'access-forced');
      // No new refresh token came back, so the old one is kept.
      expect((await h.store.read())!.refreshToken, 'refresh-1');
    });

    test('a refused refresh token ends the session', () async {
      final h = await signedIn();
      h.now = h.now.add(const Duration(hours: 2));
      h.tokenAnswer = (_) => http.Response('{"error":"invalid_grant"}', 400);

      await expectLater(
        h.auth.accessToken(),
        throwsA(
          isA<ChatGptAuthException>().having(
            (e) => e.problem,
            'problem',
            ChatGptAuthProblem.refreshFailed,
          ),
        ),
      );
      expect(await h.store.read(), isNull);
      await expectLater(
        h.auth.accessToken(),
        throwsA(
          isA<ChatGptAuthException>().having(
            (e) => e.problem,
            'problem',
            ChatGptAuthProblem.notSignedIn,
          ),
        ),
      );
    });

    test('a server hiccup while refreshing keeps the session', () async {
      final h = await signedIn();
      h.now = h.now.add(const Duration(hours: 2));
      h.tokenAnswer = (_) => http.Response('', 503);

      await expectLater(
        h.auth.accessToken(),
        throwsA(isA<ChatGptAuthException>()),
      );
      expect(await h.store.read(), isNotNull);
    });
  });

  group('the rest', () {
    test('signOut removes the session but keeps the host id', () async {
      final h = _Harness();
      await h.auth.signIn();
      final hostId = await h.store.readHostId();

      await h.auth.signOut();

      expect(await h.store.read(), isNull);
      expect(await h.store.readHostId(), hostId);
      for (final tag in ChatGptSessionStore.sessionTags) {
        expect(h.storage.values.containsKey(tag), isFalse);
      }
    });

    test('listModels returns only the models meant to be listed', () async {
      final h = _Harness();
      await h.auth.signIn();

      expect(await h.auth.listModels(), ['gpt-a', 'gpt-c']);
    });
  });

  group('what the browser is told', () {
    test('it is sent back to the app at once, without a promise', () async {
      final gate = Completer<void>();
      final h = _Harness(gate: gate);
      final result = h.auth.signIn();

      // The page arrives while the exchange is still held back.
      final page = await h.page.future;
      expect(page, contains('Zurück zur App'));
      expect(page, isNot(contains('Angemeldet')));
      expect(page, isNot(contains('fehlgeschlagen')));
      expect(h.tokenForms, isEmpty);

      gate.complete();
      expect((await result).clientId, 'oaiapp_test');
      expect(h.tokenForms, hasLength(1));
    });

    test('the code is exchanged only once the app is in front', () async {
      final gate = Completer<void>();
      final h = _Harness(gate: gate);
      var finished = false;
      final result = h.auth.signIn().whenComplete(() => finished = true);

      await h.page.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(finished, isFalse);
      expect(h.tokenForms, isEmpty);

      gate.complete();
      await result;
      expect(finished, isTrue);
    });

    test(
      'a failed exchange is still reported to the app, not the browser',
      () async {
        final h = _Harness();
        h.tokenAnswer = (_) => http.Response(
          jsonEncode({
            'error': 'invalid_grant',
            'error_description': 'bad code',
          }),
          400,
        );

        await expectLater(
          h.auth.signIn(),
          throwsA(isA<ChatGptAuthException>()),
        );

        expect(await h.page.future, contains('Zurück zur App'));
      },
    );
  });

  group('what a failure says about itself', () {
    Future<ChatGptAuthException> failure(_Harness h) async {
      try {
        await h.auth.signIn();
      } on ChatGptAuthException catch (e) {
        return e;
      }
      fail('expected a sign-in failure');
    }

    test('a refused code names the OAuth error and the status', () async {
      final h = _Harness();
      h.tokenAnswer = (_) => http.Response(
        jsonEncode({'error': 'invalid_grant', 'error_description': 'expired'}),
        400,
      );

      final e = await failure(h);

      expect(e.problem, ChatGptAuthProblem.tokenExchangeFailed);
      expect(e.statusCode, 400);
      expect(e.detail, 'invalid_grant - expired');
    });

    test('a callback without an app id lists what it did bring', () async {
      final h = _Harness(
        browser: (h) =>
            (url) => _Harness.callBack(h, url),
      );

      final e = await failure(h);

      expect(e.problem, ChatGptAuthProblem.registrationIncomplete);
      expect(e.detail, 'callback has: code,state');
    });

    test('an identity that does not check out says which check', () async {
      final h = _Harness();
      h.tokenAnswer = (form) => http.Response(
        jsonEncode({
          'access_token': 'a',
          'refresh_token': 'r',
          'expires_in': 3600,
          'scope': ChatGptAuth.planScope,
          'id_token': _idToken(clientId: form['client_id']!, nonce: 'other'),
        }),
        200,
      );

      final e = await failure(h);

      expect(e.problem, ChatGptAuthProblem.invalidIdToken);
      expect(e.detail, 'iss=true aud=true nonce=false exp=true');
    });

    test('a response with no ID token lists its fields', () async {
      final h = _Harness();
      h.tokenAnswer = (_) => http.Response(
        jsonEncode({
          'access_token': 'a',
          'refresh_token': 'r',
          'scope': ChatGptAuth.planScope,
        }),
        200,
      );

      final e = await failure(h);

      expect(e.problem, ChatGptAuthProblem.invalidIdToken);
      expect(e.detail, contains('access_token,refresh_token,scope'));
    });

    test('the detail never contains the code or a token', () async {
      final h = _Harness();
      h.tokenAnswer = (_) =>
          http.Response(jsonEncode({'error': 'invalid_grant'}), 400);

      final e = await failure(h);

      expect('$e', isNot(contains('code-1')));
    });
  });

  group('a request that does not reach OpenAI', () {
    test('names the kind of failure instead of a bare problem', () async {
      final store = ChatGptSessionStore(_MemoryStorage());
      final auth = ChatGptAuth(
        MockClient((request) async {
          if (request.url == ChatGptAuth.tokenEndpoint) {
            throw const SocketException('Failed host lookup');
          }
          return http.Response('{}', 404);
        }),
        store,
        openBrowser: (url) async {
          final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
          unawaited(
            Future(() async {
              final client = HttpClient();
              try {
                final request = await client.getUrl(
                  redirect.replace(
                    queryParameters: {
                      'code': 'c',
                      'state': url.queryParameters['state']!,
                      'client_id': 'oaiapp_test',
                    },
                  ),
                );
                await (await request.close()).drain<void>();
              } finally {
                client.close(force: true);
              }
            }),
          );
          return true;
        },
        foreground: () async {},
      );

      await expectLater(
        auth.signIn(),
        throwsA(
          isA<ChatGptAuthException>()
              .having(
                (e) => e.problem,
                'problem',
                ChatGptAuthProblem.tokenExchangeFailed,
              )
              .having((e) => e.statusCode, 'statusCode', isNull)
              .having((e) => e.detail, 'detail', contains('SocketException')),
        ),
      );
    });
  });
}
