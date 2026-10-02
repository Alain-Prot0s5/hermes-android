import 'package:flutter/material.dart';

import '../models/gateway_insight.dart';

class GatewayReasoningCard extends StatelessWidget {
  final String text;
  final bool initiallyExpanded;

  const GatewayReasoningCard({
    required this.text,
    this.initiallyExpanded = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey<String>('gateway-reasoning-${text.hashCode}'),
        initiallyExpanded: initiallyExpanded,
        leading: const Icon(Icons.psychology_outlined),
        title: const Text('Reasoning'),
        subtitle: const Text('Hermes reasoning details'),
        children: [
          const Divider(height: 1),
          SelectionArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Align(alignment: Alignment.centerLeft, child: Text(text)),
            ),
          ),
        ],
      ),
    );
  }
}

class GatewayNoticeCard extends StatelessWidget {
  final GatewayNotice notice;

  const GatewayNoticeCard({required this.notice, super.key});

  @override
  Widget build(BuildContext context) {
    final isBackground = notice.kind == GatewayNoticeKind.background;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isBackground
                  ? Icons.task_alt_outlined
                  : Icons.fact_check_outlined,
              size: 21,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notice.title,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(notice.text),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A gateway record the human never typed: compaction handoffs, background
/// task notices, model/personality switches.
///
/// The server marks these with `display_kind` on a `role: user` row, so a
/// bubble that trusts `role` alone shows them as the user's own words — a
/// 31K-character compaction handoff looks like a message the user has no
/// memory of sending. Nothing is hidden here: the full text stays readable,
/// collapsed by default, with the real author named in the header.
class SystemRecordCard extends StatelessWidget {
  final String displayKind;
  final String content;

  const SystemRecordCard({
    required this.displayKind,
    required this.content,
    super.key,
  });

  /// Header for a record kind. Content sniffing covers the kinds this client
  /// does not know yet (the gateway may add more), so an unrecognised record
  /// still gets an honest label instead of a blank card.
  static String labelFor(String kind, String content) {
    final head = content.trimLeft();
    if (head.startsWith('[CONTEXT COMPACTION')) {
      return 'Context compaction summary';
    }
    if (head.startsWith('[IMPORTANT:') ||
        head.contains('Background process')) {
      return 'Background task notice';
    }
    return switch (kind) {
      'model_switch' => 'Model switch',
      'personality_switch' => 'Personality switch',
      'hidden' => 'Internal record',
      'async_delegation_complete' => 'Task completion notice',
      _ => 'System record',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = labelFor(displayKind, content);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: theme.colorScheme.surfaceContainerHighest,
      child: ExpansionTile(
        leading: const Icon(Icons.memory_outlined, size: 21),
        title: Text(label, style: theme.textTheme.labelLarge),
        subtitle: Text(
          '${content.length} chars · tap to read',
          style: theme.textTheme.bodySmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Not written by you — sent by the gateway.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectionArea(
            child: Text(content, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class GatewaySubagentCard extends StatelessWidget {
  final List<GatewaySubagentActivity> activities;

  const GatewaySubagentCard({required this.activities, super.key});

  @override
  Widget build(BuildContext context) {
    final complete = activities.every((activity) => activity.isComplete);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ExpansionTile(
        initiallyExpanded: !complete,
        leading: Icon(
          complete ? Icons.hub_outlined : Icons.account_tree_outlined,
        ),
        title: Text(
          complete
              ? '${activities.length} delegated task(s) completed'
              : '${activities.where((item) => !item.isComplete).length} delegated task(s) active',
        ),
        children: [
          for (final activity in activities)
            ListTile(
              dense: true,
              leading: activity.isComplete
                  ? const Icon(Icons.check_circle_outline, color: Colors.green)
                  : const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
              title: Text(activity.goal),
              subtitle: Text(
                [
                  activity.phase.name,
                  if (activity.model != null) activity.model!,
                  if (activity.detail != null) activity.detail!,
                ].join(' • '),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}
