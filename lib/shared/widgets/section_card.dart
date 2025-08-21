import 'package:flutter/material.dart';

/// SectionCard
/// ---------------------------------------------------------------------------
/// A reusable card component for grouping related settings or informational
/// sections. Provides consistent padding, typography styling, and rounded
/// corners. Keeps visual style centralized so future theme adjustments are
/// easy (e.g., elevation, border, gradient backgrounds).
///
/// Usage:
///   SectionCard(
///     title: 'Runtime',
///     child: Column(children:[ ... ]),
///   );
///
/// Extend:
/// • Add an optional trailing action (e.g., IconButton) next to the title
/// • Support collapsible sections (maintain internal expansion state)
/// • Accept a subtitle or description below the title
/// • Provide semantic labels for accessibility announcements
class SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Widget? trailing;
  final bool dense;

  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(18, 16, 18, 16),
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = dense
        ? theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)
        : theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600);

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: Text(title, style: titleStyle)),
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  DefaultTextStyle.merge(
                    style: theme.textTheme.bodySmall,
                    child: IconTheme.merge(
                      data: IconThemeData(
                        color: theme.colorScheme.onSurfaceVariant,
                        size: 20,
                      ),
                      child: trailing!,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// A thinner convenience variant that sets `dense: true` and reduced padding.
class DenseSectionCard extends SectionCard {
  const DenseSectionCard({
    super.key,
    required super.title,
    required super.child,
    super.trailing,
    EdgeInsetsGeometry densePadding = const EdgeInsets.fromLTRB(16, 12, 16, 12),
  }) : super(dense: true, padding: densePadding);
}
