import 'package:flutter/material.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_service.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// Runs the connection test and shows how each model answered.
///
/// The key never leaves the service: this dialog only sees the outcome per
/// model, which is why the test can be run by a person who would rather not
/// paste a key anywhere to find out whether it works.
Future<void> showGuidedConnectionTest(
  BuildContext context,
  GuidedMealService service,
) => showDialog<void>(
  context: context,
  builder: (_) => _GuidedConnectionTestDialog(service: service),
);

class _GuidedConnectionTestDialog extends StatefulWidget {
  final GuidedMealService service;

  const _GuidedConnectionTestDialog({required this.service});

  @override
  State<_GuidedConnectionTestDialog> createState() =>
      _GuidedConnectionTestDialogState();
}

class _GuidedConnectionTestDialogState
    extends State<_GuidedConnectionTestDialog> {
  late final Future<List<GuidedProbeResult>> _results = widget.service
      .testConnection();

  String _line(S s, GuidedProbeResult r) => switch (r.outcome) {
    GuidedProbeOutcome.ok => s.guidedMealTestOk(r.model, '${r.millis}'),
    GuidedProbeOutcome.auth => s.guidedMealTestAuth(r.model),
    GuidedProbeOutcome.billing => s.guidedMealTestBilling(r.model),
    GuidedProbeOutcome.missing => s.guidedMealTestMissing(r.model),
    GuidedProbeOutcome.overloaded => s.guidedMealTestOverloaded(
      r.model,
      '${r.statusCode}',
    ),
    GuidedProbeOutcome.timeout => s.guidedMealTestTimeout(
      r.model,
      '${r.millis}',
    ),
    GuidedProbeOutcome.other => s.guidedMealTestOther(
      r.model,
      r.statusCode == null ? '–' : 'HTTP ${r.statusCode}',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(s.guidedMealTestTitle),
      content: FutureBuilder<List<GuidedProbeResult>>(
        future: _results,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 16),
                Text(s.guidedMealTestRunning),
              ],
            );
          }
          if (snapshot.hasError) {
            return Text(s.bulkAddPhotoUnavailableLabel);
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final result in snapshot.data!)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        result.outcome == GuidedProbeOutcome.ok
                            ? Icons.check_circle_rounded
                            : Icons.error_outline_rounded,
                        size: 20,
                        color: result.outcome == GuidedProbeOutcome.ok
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_line(s, result))),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(s.guidedMealTestClose),
        ),
      ],
    );
  }
}
