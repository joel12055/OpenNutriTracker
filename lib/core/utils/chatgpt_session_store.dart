import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What a "Sign in with ChatGPT" sign-in leaves on the device.
///
/// The refresh token is the long-lived secret: it, not the short-lived access
/// token, is what keeps the person signed in, and it is what a sign-out and
/// "delete all data" have to remove.
class ChatGptSession {
  /// The id OpenAI issued for this app and this ChatGPT account (`oaiapp_…`).
  /// Kept with the identity, because the account's e-mail and subject do not
  /// name the workspace.
  final String clientId;
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  /// Shown in settings so the person can see which account is connected.
  final String? email;

  const ChatGptSession({
    required this.clientId,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.email,
  });

  ChatGptSession copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) => ChatGptSession(
    clientId: clientId,
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    expiresAt: expiresAt ?? this.expiresAt,
    email: email,
  );
}

/// Keeps the ChatGPT sign-in in the platform keystore, next to the API keys
/// and with the same lifetime: [AiCredentialStorage] clears it when the
/// provider is removed and when all data is deleted.
///
/// The tags are public so that storage can name exactly what to delete and
/// nothing else.
class ChatGptSessionStore {
  static const clientIdTag = 'ChatGptClientIdTag';
  static const accessTokenTag = 'ChatGptAccessTokenTag';
  static const refreshTokenTag = 'ChatGptRefreshTokenTag';
  static const expiresAtTag = 'ChatGptExpiresAtTag';
  static const emailTag = 'ChatGptEmailTag';

  /// Survives a sign-out: it names this installation to OpenAI, not the person.
  static const hostIdTag = 'ChatGptHostIdTag';

  /// Everything that goes with the session, for a sign-out.
  static const sessionTags = [
    clientIdTag,
    accessTokenTag,
    refreshTokenTag,
    expiresAtTag,
    emailTag,
  ];

  final FlutterSecureStorage _storage;

  ChatGptSessionStore(this._storage);

  Future<ChatGptSession?> read() async {
    final clientId = await _storage.read(key: clientIdTag);
    final access = await _storage.read(key: accessTokenTag);
    final refresh = await _storage.read(key: refreshTokenTag);
    final expires = int.tryParse(await _storage.read(key: expiresAtTag) ?? '');
    if (clientId == null ||
        access == null ||
        refresh == null ||
        expires == null) {
      return null;
    }
    return ChatGptSession(
      clientId: clientId,
      accessToken: access,
      refreshToken: refresh,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true),
      email: await _storage.read(key: emailTag),
    );
  }

  Future<void> write(ChatGptSession session) async {
    await _storage.write(key: clientIdTag, value: session.clientId);
    await _storage.write(key: accessTokenTag, value: session.accessToken);
    await _storage.write(key: refreshTokenTag, value: session.refreshToken);
    await _storage.write(
      key: expiresAtTag,
      value: '${session.expiresAt.millisecondsSinceEpoch}',
    );
    if (session.email == null) {
      await _storage.delete(key: emailTag);
    } else {
      await _storage.write(key: emailTag, value: session.email);
    }
  }

  Future<void> clear() async {
    for (final tag in sessionTags) {
      await _storage.delete(key: tag);
    }
  }

  /// The per-installation id OpenAI asks for. Opaque, random and stable, so a
  /// later sign-in is recognised as the same host.
  Future<String?> readHostId() => _storage.read(key: hostIdTag);

  Future<void> writeHostId(String hostId) =>
      _storage.write(key: hostIdTag, value: hostId);
}
