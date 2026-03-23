import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/emoji_text.dart';

class ScreenShell extends StatelessWidget {
  final String title;
  final IconData icon;
  final String subtitle;
  final Widget? headerTrailing;
  final bool showHeader;
  final VoidCallback? onHeaderTap;
  final double titleFontSize;
  final List<Widget> content;
  final Future<void> Function()? onRefresh;
  final AppTone tone;

  const ScreenShell({
    super.key,
    required this.title,
    required this.icon,
    required this.subtitle,
    this.headerTrailing,
    this.showHeader = true,
    this.onHeaderTap,
    this.titleFontSize = 24,
    required this.content,
    this.onRefresh,
    this.tone = AppTone.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final scroll = CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: onRefresh != null
          ? const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics())
          : const ClampingScrollPhysics(),
      slivers: [
        if (showHeader)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: onHeaderTap,
                      borderRadius: BorderRadius.circular(18),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: AppTheme.glowCircle(tone: tone, radius: 18),
                              child: Icon(icon, color: AppTheme.textPrimary, size: 20),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  EmojiText(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                          fontSize: titleFontSize,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                  if (subtitle.trim().isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      subtitle,
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: AppTheme.textSecondary,
                                            fontSize: 13,
                                          ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (headerTrailing != null) ...[
                    const SizedBox(width: 12),
                    headerTrailing!,
                  ],
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: SizedBox(height: showHeader ? (subtitle.trim().isNotEmpty ? 12 : 8) : 6),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList(
            delegate: SliverChildListDelegate(content),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: AppTheme.shellGradient(tone),
        ),
      ),
      child: SafeArea(
        child: onRefresh != null
            ? RefreshIndicator(onRefresh: onRefresh!, child: scroll)
            : scroll,
      ),
    );
  }
}

class PreviewCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? titleWidget;
  final IconData icon;
  final VoidCallback? onTap;
  final AppTone tone;

  const PreviewCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.titleWidget,
    required this.icon,
    this.onTap,
    this.tone = AppTone.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AppTheme.tonePrimary(tone);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: AppTheme.panel(tone: tone, radius: 18, elevated: true),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: accent.withOpacity(0.16),
                border: Border.all(color: accent.withOpacity(0.24)),
              ),
              child: Icon(icon, color: accent, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  titleWidget ??
                      EmojiText(
                        title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 15),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppTheme.textTertiary),
          ],
        ),
      ),
    );
  }
}
