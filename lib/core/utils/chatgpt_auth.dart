import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/utils/chatgpt_session_store.dart';
import 'package:synchronized/synchronized.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

/// Why a sign-in or a token refresh did not produce a usable session.
enum ChatGptAuthProblem {
  /// The browser could not be opened.
  browserUnavailable,

  /// Nobody came back through the browser in time.
  timedOut,

  /// The person said no, or OpenAI refused.
  denied,

  /// The answer did not belong to the request that was sent.
  stateMismatch,

  /// OpenAI did not issue the app id a first sign-in must return.
  registrationIncomplete,

  /// The token endpoint refused the code.
  tokenExchangeFailed,

  /// The identity OpenAI vouched for did not check out.
  invalidIdToken,

  /// The account signed in but did not grant use of its plan.
  noPlanUsage,

  /// Asked for a token with nobody signed in.
  notSignedIn,

  /// The refresh token no longer works; signing in again is the fix.
  refreshFailed,
}

class ChatGptAuthException implements Exception {
  final ChatGptAuthProblem problem;
  final int? statusCode;

  /// A short account of what exactly was wrong, for the person to read out and
  /// for the log: names of fields and OAuth error codes, never a value that is
  /// a code, a token or an address.
  final String? detail;

  const ChatGptAuthException(this.problem, {this.statusCode, this.detail});

  @override
  String toString() =>
      'ChatGptAuthException(${problem.name}'
      '${statusCode == null ? '' : ', status: $statusCode'}'
      '${detail == null ? '' : ', $detail'})';
}

/// Where the inference client gets the bearer token for the signed-in plan.
///
/// An interface so the client does not need the whole sign-in machinery to be
/// tested, and so the token can be refreshed behind it.
abstract interface class ChatGptTokenSource {
  /// A token valid now. [forceRefresh] asks for a new one even if the stored
  /// one looks fresh, for the case where the server said it was not.
  Future<String> accessToken({bool forceRefresh = false});
}

/// "Sign in with ChatGPT" for an open-source app: the person's own ChatGPT
/// plan pays for the model calls, and no API key exists anywhere.
///
/// OpenAI's flow for a public client without a secret: an OAuth 2.0
/// authorization-code grant with PKCE, a loopback redirect on `127.0.0.1`,
/// and a first sign-in that registers this installation by itself
/// (`client_id=dynamic_agent_client`). The app learns its own id from the
/// callback and keeps it with the account.
///
/// The ID token's signature is not verified here: it arrives straight from
/// OpenAI's token endpoint over TLS in answer to a request this app made, and
/// what the app uses it for — the e-mail to show — decides nothing about
/// access. Its issuer, audience, expiry and nonce are checked.
class ChatGptAuth implements ChatGptTokenSource {
  static final _log = Logger('ChatGptAuth');

  static const issuer = 'https://auth.openai.com';
  static final authorizeEndpoint = Uri.parse(
    'https://auth.openai.com/api/accounts/authorize',
  );
  static final tokenEndpoint = Uri.parse(
    'https://auth.openai.com/api/accounts/oauth/token',
  );
  static const resource = 'https://api.openai.com/v1';
  static final modelsEndpoint = Uri.parse('https://api.openai.com/v1/models');

  /// The scope that lets the app spend the plan's allowance. Without it a
  /// sign-in is only an identity.
  static const planScope = 'chatgpt.tokens.use.direct';
  static const _scopes =
      'openid profile email offline_access resource.invoke $planScope';

  static const _callbackPath = '/auth/callback';
  static const _signInTimeout = Duration(minutes: 5);

  /// A token this close to expiring is replaced before it is used.
  static const _refreshMargin = Duration(seconds: 60);

  final http.Client _http;
  final ChatGptSessionStore _store;
  final Future<bool> Function(Uri url) _openBrowser;
  final Future<HttpServer> Function() _bindLoopback;
  final DateTime Function() _now;
  final Random _random;
  final Future<void> Function() _foreground;
  final _refreshLock = Lock();

  ChatGptAuth(
    this._http,
    this._store, {
    Future<bool> Function(Uri url)? openBrowser,
    Future<HttpServer> Function()? bindLoopback,
    DateTime Function()? now,
    Random? random,
    Future<void> Function()? foreground,
  }) : _openBrowser = openBrowser ?? _launchExternally,
       _foreground = foreground ?? _waitForForeground,
       _bindLoopback =
           bindLoopback ??
           (() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)),
       _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  static Future<bool> _launchExternally(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  /// The e-mail of the signed-in account, or null when nobody is signed in.
  Future<ChatGptSession?> currentSession() => _store.read();

  Future<void> signOut() => _store.clear();

  /// Opens the browser for the person to sign in, waits for them to come
  /// back, and stores the session.
  Future<ChatGptSession> signIn({String agentName = 'OpenNutriTracker'}) async {
    final hostId = await _hostId();
    final existing = await _store.read();

    final verifier = _randomUrlSafe(48);
    final state = _randomUrlSafe(24);
    final nonce = _randomUrlSafe(24);

    // The listener comes up before the browser opens, so a quick answer finds
    // somebody home.
    final server = await _bindLoopback();
    try {
      final redirectUri =
          'http://${InternetAddress.loopbackIPv4.address}:${server.port}$_callbackPath';
      final callback = _awaitCallback(server);

      final url = authorizeEndpoint.replace(
        queryParameters: {
          'client_id': existing?.clientId ?? 'dynamic_agent_client',
          // Display metadata for the first registration only.
          if (existing == null) 'agent_name_hint': agentName,
          'ext_agent_host_id': hostId,
          'response_type': 'code',
          'redirect_uri': redirectUri,
          'scope': _scopes,
          'resource': resource,
          'state': state,
          'nonce': nonce,
          'code_challenge_method': 'S256',
          'code_challenge': base64Url
              .encode(sha256.convert(utf8.encode(verifier)).bytes)
              .replaceAll('=', ''),
        },
      );
      if (!await _openBrowser(url)) {
        throw const ChatGptAuthException(ChatGptAuthProblem.browserUnavailable);
      }

      final _Callback received;
      try {
        received = await callback.timeout(_signInTimeout);
      } on TimeoutException {
        throw const ChatGptAuthException(ChatGptAuthProblem.timedOut);
      }

      // The browser is answered at once, and with nothing the app has not yet
      // earned: it says to go back to the app, not that the sign-in worked.
      await _respond(received.response);

      // The person is in the browser now, and the app is in the background.
      // Android restricts what a backgrounded app may do on the network, and
      // the exchange failed there before it reached OpenAI; so it waits for
      // the app to be in front again, which is where the person returns to.
      await _foreground();

      try {
        return await _complete(
          received.params,
          existing: existing,
          state: state,
          nonce: nonce,
          verifier: verifier,
          redirectUri: redirectUri,
        );
      } on ChatGptAuthException catch (e) {
        _log.warning('Sign-in failed: $e');
        rethrow;
      }
    } finally {
      await server.close(force: true);
    }
  }

  /// Everything after the browser came back: checks the answer belongs to
  /// the request, exchanges the code and validates what comes back.
  Future<ChatGptSession> _complete(
    Map<String, String> params, {
    required ChatGptSession? existing,
    required String state,
    required String nonce,
    required String verifier,
    required String redirectUri,
  }) async {
    if (params['error'] != null) {
      throw ChatGptAuthException(
        ChatGptAuthProblem.denied,
        detail: 'error=${params['error']}',
      );
    }
    if (params['state'] != state) {
      throw const ChatGptAuthException(
        ChatGptAuthProblem.stateMismatch,
        detail: 'state differs',
      );
    }
    final code = params['code'];
    if (code == null || code.isEmpty) {
      throw ChatGptAuthException(
        ChatGptAuthProblem.denied,
        detail:
            'no code, callback has: ${(params.keys.toList()..sort()).join(',')}',
      );
    }

    // A first sign-in has to hand back the id OpenAI made for this app; a
    // repeat one may, and if it names a different one something is wrong.
    final issuedId = params['client_id'];
    if (existing == null && (issuedId == null || issuedId.isEmpty)) {
      throw ChatGptAuthException(
        ChatGptAuthProblem.registrationIncomplete,
        detail: 'callback has: ${(params.keys.toList()..sort()).join(',')}',
      );
    }
    if (existing != null && issuedId != null && issuedId != existing.clientId) {
      throw const ChatGptAuthException(
        ChatGptAuthProblem.denied,
        detail: 'client id differs from the stored one',
      );
    }
    final clientId = existing?.clientId ?? issuedId!;

    final tokens = await _postToken({
      'grant_type': 'authorization_code',
      'client_id': clientId,
      'code': code,
      'code_verifier': verifier,
      'redirect_uri': redirectUri,
      'resource': resource,
    }, failure: ChatGptAuthProblem.tokenExchangeFailed);

    final granted = (tokens['scope'] as String?) ?? params['scope'];
    if (granted != null && !granted.split(' ').contains(planScope)) {
      throw const ChatGptAuthException(
        ChatGptAuthProblem.noPlanUsage,
        detail: 'plan scope not granted',
      );
    }

    final idToken = tokens['id_token'];
    if (idToken is! String) {
      throw ChatGptAuthException(
        ChatGptAuthProblem.invalidIdToken,
        detail:
            'no id_token, response has: '
            '${(tokens.keys.toList()..sort()).join(',')}',
      );
    }
    final claims = _validatedClaims(idToken, clientId: clientId, nonce: nonce);

    final session = _sessionFrom(
      tokens,
      clientId: clientId,
      email: claims['email'] is String ? claims['email'] as String : null,
    );
    await _store.write(session);
    return session;
  }

  @override
  Future<String> accessToken({bool forceRefresh = false}) =>
      _refreshLock.synchronized(() async {
        final session = await _store.read();
        if (session == null) {
          throw const ChatGptAuthException(ChatGptAuthProblem.notSignedIn);
        }
        final fresh = session.expiresAt.isAfter(_now().add(_refreshMargin));
        if (fresh && !forceRefresh) return session.accessToken;
        return (await _refresh(session)).accessToken;
      });

  Future<ChatGptSession> _refresh(ChatGptSession session) async {
    final Map<String, dynamic> tokens;
    try {
      tokens = await _postToken({
        'grant_type': 'refresh_token',
        'client_id': session.clientId,
        'refresh_token': session.refreshToken,
        'resource': resource,
      }, failure: ChatGptAuthProblem.refreshFailed);
    } on ChatGptAuthException catch (e) {
      // A refused refresh token will never work again. Dropping the session
      // turns the next attempt into "sign in", which is the honest state.
      if (e.statusCode == 400 || e.statusCode == 401) await _store.clear();
      rethrow;
    }
    final renewed = _sessionFrom(
      tokens,
      clientId: session.clientId,
      email: session.email,
      fallbackRefreshToken: session.refreshToken,
    );
    await _store.write(renewed);
    return renewed;
  }

  /// The models this account can use, as the slugs to put in a request.
  Future<List<String>> listModels() async {
    Future<http.Response> ask(String token) =>
        _http.get(modelsEndpoint, headers: {'authorization': 'Bearer $token'});

    var response = await ask(await accessToken());
    if (response.statusCode == 401) {
      response = await ask(await accessToken(forceRefresh: true));
    }
    if (response.statusCode != 200) return const [];
    try {
      final models = (jsonDecode(response.body) as Map)['models'];
      if (models is! List) return const [];
      return [
        for (final model in models)
          if (model is Map &&
              model['visibility'] == 'list' &&
              model['slug'] is String)
            model['slug'] as String,
      ];
    } catch (_) {
      return const [];
    }
  }

  // ---- internals -----------------------------------------------------------

  Future<String> _hostId() async {
    final stored = await _store.readHostId();
    if (stored != null && stored.isNotEmpty) return stored;
    final created = 'urn:uuid:${const Uuid().v4()}';
    await _store.writeHostId(created);
    return created;
  }

  /// Waits for the browser to land on the callback and answers it with a page
  /// that says the app can be opened again.
  Future<_Callback> _awaitCallback(HttpServer server) {
    final completer = Completer<_Callback>();
    server.listen((request) async {
      if (request.uri.path != _callbackPath || completer.isCompleted) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      // Left open on purpose: it is answered once the sign-in has a result.
      completer.complete(
        _Callback(request.uri.queryParameters, request.response),
      );
    });
    return completer.future;
  }

  Future<void> _respond(HttpResponse response) async {
    try {
      response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(_donePage);
      await response.close();
    } catch (_) {
      // The person may have closed the tab; the result stands regardless.
    }
  }

  static const _donePage =
      '<!doctype html><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>OpenNutriTracker</title>'
      '<body style="font-family:sans-serif;text-align:center;padding:3em 1em">'
      '<h2>Zurück zur App</h2><p>Go back to the app to finish.</p>'
      '<p>Kehre zur App zurück, dort geht es weiter.</p></body>';

  Future<Map<String, dynamic>> _postToken(
    Map<String, String> form, {
    required ChatGptAuthProblem failure,
  }) async {
    final http.Response response;
    try {
      response = await _http.post(tokenEndpoint, body: form);
    } catch (e) {
      // The kind of failure and its own message, never the form: the client's
      // exceptions name the address and the OS error, and the form is what
      // carries a code or a refresh token.
      final detail = _describe(e);
      _log.warning('Token request did not get through: $detail');
      throw ChatGptAuthException(failure, detail: detail);
    }
    if (response.statusCode != 200) {
      final detail = _oauthError(response.body);
      _log.warning('Token endpoint answered ${response.statusCode}$detail');
      throw ChatGptAuthException(
        failure,
        statusCode: response.statusCode,
        detail: detail.isEmpty ? null : detail.substring(2),
      );
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    } catch (_) {
      throw ChatGptAuthException(failure, statusCode: response.statusCode);
    }
  }

  static String _describe(Object error) {
    final text = error.toString();
    final cut = text.length > 160 ? text.substring(0, 160) : text;
    return '${error.runtimeType}: $cut';
  }

  /// `": code - description"` from an OAuth error body, cut short, or empty.
  /// Both fields are standard (RFC 6749) and say what was refused, not who by.
  static String _oauthError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return '';
      var error = decoded['error'];
      if (error is Map) {
        error = error['code'] ?? error['message'];
      }
      final description = decoded['error_description'];
      final text = [
        if (error is String) error,
        if (description is String) description,
      ].join(' - ');
      if (text.isEmpty) return '';
      return ': ${text.length > 200 ? text.substring(0, 200) : text}';
    } catch (_) {
      return '';
    }
  }

  ChatGptSession _sessionFrom(
    Map<String, dynamic> tokens, {
    required String clientId,
    required String? email,
    String? fallbackRefreshToken,
  }) {
    final access = tokens['access_token'];
    final refresh = tokens['refresh_token'] ?? fallbackRefreshToken;
    if (access is! String || refresh is! String) {
      throw const ChatGptAuthException(ChatGptAuthProblem.tokenExchangeFailed);
    }
    final expiresIn = tokens['expires_in'];
    final seconds = expiresIn is num ? expiresIn.toInt() : 3600;
    return ChatGptSession(
      clientId: clientId,
      accessToken: access,
      refreshToken: refresh,
      expiresAt: _now().add(Duration(seconds: seconds)),
      email: email,
    );
  }

  Map<String, dynamic> _validatedClaims(
    String idToken, {
    required String clientId,
    required String nonce,
  }) {
    final Map<String, dynamic> claims;
    try {
      final payload = idToken.split('.')[1];
      claims = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload))))
            as Map,
      );
    } catch (_) {
      throw const ChatGptAuthException(ChatGptAuthProblem.invalidIdToken);
    }
    final aud = claims['aud'];
    final audiences = aud is List ? aud : [aud];
    final exp = claims['exp'];
    final issOk = (claims['iss'] as String?)?.startsWith(issuer) == true;
    final audOk = audiences.contains(clientId);
    final nonceOk = claims['nonce'] == nonce;
    final expOk =
        exp is num &&
        DateTime.fromMillisecondsSinceEpoch(
          exp.toInt() * 1000,
          isUtc: true,
        ).isAfter(_now());
    if (!(issOk && audOk && nonceOk && expOk)) {
      // Which checks, never what was in them.
      throw ChatGptAuthException(
        ChatGptAuthProblem.invalidIdToken,
        detail: 'iss=$issOk aud=$audOk nonce=$nonceOk exp=$expOk',
      );
    }
    return claims;
  }

  String _randomUrlSafe(int bytes) => base64Url
      .encode([for (var i = 0; i < bytes; i++) _random.nextInt(256)])
      .replaceAll('=', '');
}

/// What the browser brought back, with its request still open.
class _Callback {
  final Map<String, String> params;
  final HttpResponse response;

  const _Callback(this.params, this.response);
}

/// Returns once the app is in front, at once if it already is or if there is
/// no app lifecycle to ask (a unit test). Gives up after two minutes, so a
/// phone that never reports it simply goes on.
Future<void> _waitForForeground() async {
  final WidgetsBinding binding;
  try {
    binding = WidgetsBinding.instance;
  } catch (_) {
    return;
  }
  final state = binding.lifecycleState;
  if (state == null || state == AppLifecycleState.resumed) return;

  final resumed = Completer<void>();
  final observer = _ResumeObserver(resumed);
  binding.addObserver(observer);
  try {
    await resumed.future.timeout(const Duration(minutes: 2));
  } on TimeoutException {
    // Go on regardless.
  } finally {
    binding.removeObserver(observer);
  }
}

class _ResumeObserver with WidgetsBindingObserver {
  final Completer<void> _resumed;

  _ResumeObserver(this._resumed);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_resumed.isCompleted) {
      _resumed.complete();
    }
  }
}
