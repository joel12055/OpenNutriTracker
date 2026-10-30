import 'package:flutter/material.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// Where the person turns the web search for unknown foods on.
///
/// Off unless chosen: it sends the model's short search queries to OpenAI or
/// Google, and that is the person's decision to make. It runs through the
/// ChatGPT plan, else on a Gemini key, whichever provider is in use for the
/// rest, so without either the switch is disabled and the note says why.
class WebLookupSelector extends StatefulWidget {
  final AiCredentialStorage storage;

  const WebLookupSelector({super.key, required this.storage});

  @override
  State<WebLookupSelector> createState() => _WebLookupSelectorState();
}

class _WebLookupSelectorState extends State<WebLookupSelector> {
  bool _loading = true;
  bool _on = false;
  bool _hasRoute = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final on = await widget.storage.readWebLookup() == 'on';
    final model = (await widget.storage.selectionFor(
      AiProvider.chatgpt,
    ))?.modelId;
    final key = (await widget.storage.selectionFor(AiProvider.gemini))?.apiKey;
    if (!mounted) return;
    setState(() {
      _on = on;
      _hasRoute =
          (model != null && model.isNotEmpty) ||
          (key != null && key.isNotEmpty);
      _loading = false;
    });
  }

  Future<void> _set(bool on) async {
    setState(() => _on = on);
    await widget.storage.writeWebLookup(on);
  }

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          identifier: 'ai-assist-web-lookup',
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              s.aiAssistWebLookupLabel,
              style: theme.textTheme.titleSmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            value: _on && _hasRoute,
            onChanged: _hasRoute ? _set : null,
          ),
        ),
        Text(
          _hasRoute ? s.aiAssistWebLookupNote : s.aiAssistWebLookupNoKey,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
