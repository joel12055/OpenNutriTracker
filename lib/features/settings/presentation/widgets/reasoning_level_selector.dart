import 'package:flutter/material.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// Where the person picks how much a thinking model may deliberate.
///
/// "Automatic" leaves the choice to the flow, which thinks a little for the
/// questions and a lot for the estimate and the decision. The other three fix
/// one level for every step. Self-contained, like the sign-in section, so the
/// large settings dialog only has to embed it.
class ReasoningLevelSelector extends StatefulWidget {
  final AiCredentialStorage storage;

  const ReasoningLevelSelector({super.key, required this.storage});

  @override
  State<ReasoningLevelSelector> createState() => _ReasoningLevelSelectorState();
}

class _ReasoningLevelSelectorState extends State<ReasoningLevelSelector> {
  static const _auto = 'auto';

  String _value = _auto;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final level = await widget.storage.readReasoningLevel();
    if (mounted) setState(() => _value = level ?? _auto);
  }

  Future<void> _select(String value) async {
    setState(() => _value = value);
    await widget.storage.writeReasoningLevel(value == _auto ? null : value);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final labels = {
      _auto: s.aiAssistReasoningAuto,
      'low': s.aiAssistReasoningLow,
      'medium': s.aiAssistReasoningMedium,
      'high': s.aiAssistReasoningHigh,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.aiAssistReasoningLabel, style: theme.textTheme.titleSmall),
        Semantics(
          identifier: 'ai-assist-reasoning-level',
          child: DropdownButton<String>(
            isExpanded: true,
            value: _value,
            items: [
              for (final entry in labels.entries)
                DropdownMenuItem(
                  value: entry.key,
                  child: Text(entry.value, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) {
              if (value != null) _select(value);
            },
          ),
        ),
        Text(
          s.aiAssistReasoningNote,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
