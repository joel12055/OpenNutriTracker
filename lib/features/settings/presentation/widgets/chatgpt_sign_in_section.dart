import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/core/utils/chatgpt_auth.dart';
import 'package:opennutritracker/core/utils/chatgpt_session_store.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// The model to start with after signing in, from the slugs OpenAI offered.
///
/// The one the sign-in documentation itself uses if it is there, otherwise
/// the first that is not a coding-only model, otherwise the first. A guess
/// the person can change in the list that follows; whether it reads photos is
/// what the connection test and the first meal are for.
String? pickDefaultChatGptModel(List<String> slugs) {
  if (slugs.isEmpty) return null;
  if (slugs.contains('gpt-6.1-sol')) return 'gpt-6.1-sol';
  return slugs.firstWhere(
    (slug) => !slug.toLowerCase().contains('codex'),
    orElse: () => slugs.first,
  );
}

/// Where settings sign in to ChatGPT instead of asking for a key.
///
/// Self-contained so the settings dialog, which is already very large, only
/// has to embed it and reload when it reports a change. It writes the same
/// storage the other providers use: the marker in the key slot and the chosen
/// model, so everything that asks whether a provider is usable gets the same
/// answer as for a pasted key.
class ChatGptSignInSection extends StatefulWidget {
  final AiCredentialStorage storage;
  final ChatGptAuth auth;

  /// Asks for the agreement about what leaves the device, true once given.
  final Future<bool> Function() ensureAgreed;

  /// Called after the sign-in or the model changed, so the dialog can reload.
  final VoidCallback onChanged;

  const ChatGptSignInSection({
    super.key,
    required this.storage,
    required this.auth,
    required this.ensureAgreed,
    required this.onChanged,
  });

  @override
  State<ChatGptSignInSection> createState() => _ChatGptSignInSectionState();
}

class _ChatGptSignInSectionState extends State<ChatGptSignInSection> {
  static final _log = Logger('ChatGptSignInSection');

  bool _loading = true;
  bool _busy = false;
  ChatGptSession? _session;
  String? _modelId;
  List<String> _models = const [];
  ChatGptAuthProblem? _problem;

  /// What the failure said about itself, shown small under the message so a
  /// person can read it out.
  String? _problemDetail;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh({bool loadModels = true}) async {
    final session = await widget.auth.currentSession();
    final modelId = await widget.storage.readModel(
      provider: AiProvider.chatgpt,
    );
    var models = _models;
    if (session != null && loadModels) {
      try {
        models = await widget.auth.listModels();
      } catch (e) {
        _log.info('Listing ChatGPT models failed');
      }
    }
    if (!mounted) return;
    setState(() {
      _session = session;
      _modelId = modelId;
      _models = models;
      _loading = false;
    });
  }

  Future<void> _signIn() async {
    if (!await widget.ensureAgreed() || !mounted) return;
    setState(() {
      _busy = true;
      _problem = null;
      _problemDetail = null;
    });
    try {
      await widget.auth.signIn();
      final models = await widget.auth.listModels();
      var modelId = await widget.storage.readModel(
        provider: AiProvider.chatgpt,
      );
      modelId ??= pickDefaultChatGptModel(models);
      if (modelId != null) {
        await widget.storage.writeModel(modelId, provider: AiProvider.chatgpt);
      }
      // The marker is what makes the provider count as having a credential.
      await widget.storage.writeApiKey(
        AiCredentialStorage.chatGptSessionMarker,
        provider: AiProvider.chatgpt,
      );
      widget.onChanged();
      await _refresh();
    } on ChatGptAuthException catch (e) {
      _log.info('ChatGPT sign-in failed: $e');
      if (mounted) {
        setState(() {
          _problem = e.problem;
          _problemDetail = [
            e.problem.name,
            if (e.statusCode != null) 'HTTP ${e.statusCode}',
            ?e.detail,
          ].join(' · ');
        });
      }
    } catch (e) {
      _log.warning('ChatGPT sign-in failed unexpectedly: ${e.runtimeType}');
      if (mounted) {
        setState(() {
          _problem = ChatGptAuthProblem.tokenExchangeFailed;
          _problemDetail = e.runtimeType.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectModel(String slug) async {
    await widget.storage.writeModel(slug, provider: AiProvider.chatgpt);
    if (!mounted) return;
    setState(() => _modelId = slug);
    widget.onChanged();
  }

  String _problemText(S s, ChatGptAuthProblem problem) => switch (problem) {
    ChatGptAuthProblem.browserUnavailable => s.aiAssistChatGptErrorBrowser,
    ChatGptAuthProblem.timedOut => s.aiAssistChatGptErrorTimeout,
    ChatGptAuthProblem.denied => s.aiAssistChatGptErrorDenied,
    ChatGptAuthProblem.noPlanUsage => s.aiAssistChatGptErrorNoPlan,
    _ => s.aiAssistChatGptErrorOther,
  };

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      );
    }

    final session = _session;
    final modelChoices = {..._models, ?_modelId}.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.aiAssistChatGptIntro,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        if (session == null)
          Semantics(
            identifier: 'ai-assist-chatgpt-sign-in',
            child: FilledButton.icon(
              onPressed: _busy ? null : _signIn,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login_rounded),
              label: Text(
                _busy ? s.aiAssistChatGptWaiting : s.aiAssistChatGptSignIn,
              ),
            ),
          )
        else ...[
          Row(
            children: [
              const Icon(Icons.check_circle_rounded, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  session.email == null
                      ? s.aiAssistChatGptSignedIn
                      : s.aiAssistChatGptSignedInAs(session.email!),
                  style: theme.textTheme.bodyMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(s.aiAssistModelLabel, style: theme.textTheme.titleSmall),
          if (modelChoices.isEmpty)
            Text(s.aiAssistChatGptNoModels, style: theme.textTheme.bodySmall)
          else
            DropdownButton<String>(
              isExpanded: true,
              value: _modelId,
              hint: Text(s.aiAssistPickModelLabel),
              items: [
                for (final slug in modelChoices)
                  DropdownMenuItem(
                    value: slug,
                    child: Text(slug, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (slug) {
                if (slug != null) _selectModel(slug);
              },
            ),
        ],
        if (_problem != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _problemText(s, _problem!),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                if (_problemDetail != null)
                  SelectableText(
                    _problemDetail!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
