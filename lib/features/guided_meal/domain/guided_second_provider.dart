import 'package:opennutritracker/core/utils/ai_credential_storage.dart';

/// How the automatic second opinion is set: not at all, only when the
/// estimate came with a doubt, or every time.
enum AutoSecondOpinion {
  off,
  uncertain,
  always;

  static AutoSecondOpinion fromTag(String? tag) => switch (tag) {
    'uncertain' => uncertain,
    'always' => always,
    _ => off,
  };
}

/// The assistant asked for the second opinion, and what to call it.
class GuidedSecondary {
  final AiProvider provider;
  final AiSelection selection;
  final String name;

  const GuidedSecondary({
    required this.provider,
    required this.selection,
    required this.name,
  });
}

/// What a provider is called to the person, in the app and in the text of the
/// prompts. Brand names, deliberately not localized.
String providerDisplayName(AiProvider provider) => switch (provider) {
  AiProvider.anthropic => 'Anthropic',
  AiProvider.openrouter => 'OpenRouter',
  AiProvider.openai => 'OpenAI',
  AiProvider.gemini => 'Google Gemini',
  AiProvider.chatgpt => 'ChatGPT',
  AiProvider.ownServer => 'Own server',
};

/// The first usable provider other than the one in use, or null when there is
/// none.
///
/// A server the person runs is left out: whether it can read a photo is
/// established by a setup check that belongs to that provider's own settings,
/// and a second opinion that silently cannot see the meal would be worse than
/// none. Everything else is asked of storage as any request would be, so a
/// paused feature, a missing agreement or an incomplete sign-in all answer
/// "not usable".
Future<GuidedSecondary?> findSecondaryProvider(
  AiCredentialStorage storage,
) async {
  final active = await storage.activeProvider();
  for (final provider in AiProvider.values) {
    if (provider == active || provider == AiProvider.ownServer) continue;
    final selection = await storage.selectionFor(provider);
    if (selection != null) {
      return GuidedSecondary(
        provider: provider,
        selection: selection,
        name: providerDisplayName(provider),
      );
    }
  }
  return null;
}
