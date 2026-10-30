import 'package:flutter/material.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_second_provider.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// Where the person turns the automatic second opinion on.
///
/// Off unless chosen: it sends the photo, the answers and the estimate to a
/// second company, and that is the person's decision to make. The note says
/// which one, or that there is none yet.
class AutoSecondOpinionSelector extends StatefulWidget {
  final AiCredentialStorage storage;

  const AutoSecondOpinionSelector({super.key, required this.storage});

  @override
  State<AutoSecondOpinionSelector> createState() =>
      _AutoSecondOpinionSelectorState();
}

class _AutoSecondOpinionSelectorState extends State<AutoSecondOpinionSelector> {
  bool _loading = true;
  AutoSecondOpinion _mode = AutoSecondOpinion.off;
  GuidedSecondary? _secondary;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mode = AutoSecondOpinion.fromTag(
      await widget.storage.readAutoSecondOpinion(),
    );
    final secondary = await findSecondaryProvider(widget.storage);
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _secondary = secondary;
      _loading = false;
    });
  }

  Future<void> _select(AutoSecondOpinion mode) async {
    setState(() => _mode = mode);
    await widget.storage.writeAutoSecondOpinion(mode.name);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final secondary = _secondary;
    final labels = {
      AutoSecondOpinion.off: s.aiAssistAutoSecondOff,
      AutoSecondOpinion.uncertain: s.aiAssistAutoSecondUncertain,
      AutoSecondOpinion.always: s.aiAssistAutoSecondAlways,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.aiAssistAutoSecondLabel, style: theme.textTheme.titleSmall),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          )
        else
          Semantics(
            identifier: 'ai-assist-auto-second-opinion',
            child: DropdownButton<AutoSecondOpinion>(
              isExpanded: true,
              value: _mode,
              items: [
                for (final entry in labels.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.value, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (mode) {
                if (mode != null) _select(mode);
              },
            ),
          ),
        if (!_loading)
          Text(
            secondary == null
                ? s.aiAssistAutoSecondNoProvider
                : s.aiAssistAutoSecondNote(secondary.name),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
