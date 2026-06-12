import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';

/// Tone classification for [StatusChip].
///
/// The tone selects the leading-dot color while keeping the pill body
/// neutral. Mapped per `design.md`:
/// online -> success, offline -> muted, pending -> warning,
/// success -> success, danger -> danger, info -> mapBlue,
/// neutral -> muted.
enum StatusTone {
  /// Default neutral tone (e.g., generic status badges).
  neutral,

  /// Rider is ONLINE / connection is healthy.
  online,

  /// Rider is OFFLINE / connection is intentionally down.
  offline,

  /// Pending state (approval, review, queued action).
  pending,

  /// Success state acknowledgement.
  success,

  /// Destructive / failed state acknowledgement.
  danger,

  /// Informational accent (typically map / route related).
  info,
}

/// Compact pill-shaped status indicator used across the rider shell.
///
/// `StatusChip` renders a 999-radius pill on [AppColors.offWhite] with a
/// charcoal uppercase label and an optional 8 px leading dot whose color
/// reflects the supplied [StatusTone]. It is the canonical surface for
/// the home connection pill, document statuses on the approval screen,
/// assignment-status badges on offers, and history-list result chips.
class StatusChip extends StatelessWidget {
  /// Creates a status chip showing [label] colored per [tone].
  const StatusChip({
    super.key,
    required this.label,
    this.tone = StatusTone.neutral,
    this.showDot = true,
  });

  /// Pill label. Rendered uppercased in [AppTypography.label].
  final String label;

  /// Tone driving the leading-dot color.
  final StatusTone tone;

  /// Whether to render the 8 px leading dot. Defaults to `true`.
  final bool showDot;

  /// Maps a [StatusTone] to its leading-dot color.
  static Color dotColorFor(StatusTone tone) {
    switch (tone) {
      case StatusTone.online:
      case StatusTone.success:
        return AppColors.success;
      case StatusTone.offline:
      case StatusTone.neutral:
        return AppColors.muted;
      case StatusTone.pending:
        return AppColors.warning;
      case StatusTone.danger:
        return AppColors.danger;
      case StatusTone.info:
        return AppColors.mapBlue;
    }
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.offWhite,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (showDot) ...<Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: dotColorFor(tone),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              label.toUpperCase(),
              style: AppTypography.label.copyWith(color: AppColors.charcoal),
            ),
          ],
        ),
      ),
    );
  }
}
