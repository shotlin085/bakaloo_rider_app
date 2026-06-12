import 'package:flutter/animation.dart';

/// Motion tokens for the Grolin Rider App.
///
/// Durations and curves match the values called out in `design.md`. The
/// 180-300 ms band keeps the app feeling brisk on real devices while
/// leaving enough time for a perceptible camera fit / sheet snap.
///
/// Marked `abstract final` so the class can never be instantiated or
/// extended; callers reach values via `AppMotion.<token>`.
abstract final class AppMotion {
  /// Snappy micro-transitions (status chip changes, switch toggles).
  static const Duration fast = Duration(milliseconds: 180);

  /// Default screen and tab transitions.
  static const Duration normal = Duration(milliseconds: 240);

  /// Camera fits and bottom-sheet snaps.
  static const Duration slow = Duration(milliseconds: 280);

  /// Bottom-sheet open animation.
  static const Duration sheetOpen = Duration(milliseconds: 300);

  /// Standard easing curve. `easeOutCubic` decelerates into rest, which
  /// reads as "premium and finished" for sheet snaps and camera fits.
  static const Curve easing = Curves.easeOutCubic;
}
