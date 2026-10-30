/// Compiled-in destinations of the hosted providers that share one address
/// between several clients.
///
/// Gemini is reached through Google's OpenAI-compatible route, so the same
/// chat-completions client that serves OpenRouter serves it too. Kept out of
/// both clients so the single-shot reader and the guided flow cannot drift
/// apart on where a photo goes.
final geminiChatEndpoint = Uri.parse(
  'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
);
