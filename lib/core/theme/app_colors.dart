import 'package:flutter/material.dart';

/// Premium minimal color palette for the Grolin Rider App.
///
/// Tokens come from the design system foundation in `design.md` and are
/// reused everywhere instead of hard-coded `Color(0x...)` literals so that
/// a single edit here propagates to every screen, sheet, and theme entry.
///
/// Marked `abstract final` so the class can never be instantiated or
/// extended; callers reach the values via `AppColors.<token>`.
abstract final class AppColors {
  /// Pure black used for primary surfaces and primary action buttons.
  static const Color black = Color(0xFF0B0B0C);

  /// Charcoal used for primary text on white surfaces and AppBar
  /// foregrounds. Slightly softer than [black] so headings don't feel
  /// printed-on-paper harsh.
  static const Color charcoal = Color(0xFF17181A);

  /// Graphite used for secondary text and subdued surfaces sitting on
  /// [offWhite].
  static const Color graphite = Color(0xFF2A2D31);

  /// Pure white scaffold/surface color.
  static const Color white = Color(0xFFFFFFFF);

  /// Subtle off-white used for skeletons, surface containers, and chip
  /// backgrounds where pure white would disappear into the scaffold.
  static const Color offWhite = Color(0xFFF7F8FA);

  /// 1dp hairline divider color used for cards, list separators, and the
  /// secondary button outline.
  static const Color border = Color(0xFFE7E8EC);

  /// Muted text color used for helper copy and disabled states.
  static const Color muted = Color(0xFF6B7280);

  /// Semantic success color for ONLINE chips and successful action states.
  static const Color success = Color(0xFF16A34A);

  /// Semantic warning color for PENDING and approval-related states.
  static const Color warning = Color(0xFFF59E0B);

  /// Semantic danger color for destructive actions and error states.
  static const Color danger = Color(0xFFDC2626);

  /// Map polyline / external-navigation accent.
  static const Color mapBlue = Color(0xFF2563EB);
}
