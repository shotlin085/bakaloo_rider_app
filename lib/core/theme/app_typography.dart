import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Typography scale for the Grolin Rider App.
///
/// Sizes, line-heights, and weights match the scale defined in
/// `design.md`. No `fontFamily` is set so the platform default ships
/// (SF Pro on iOS, Roboto on Android), keeping the app feeling native on
/// both platforms without bundling extra font assets.
///
/// Each style applies [AppColors.black] as the default foreground; widgets
/// can override `color` per-call site when they need a non-default tint.
///
/// Marked `abstract final` so the class can never be instantiated or
/// extended; callers reach styles via `AppTypography.<token>`.
abstract final class AppTypography {
  /// Display: 32 / 38, w700. Used for splash, hero, and onboarding
  /// headings where the app needs to set a confident first impression.
  static const TextStyle display = TextStyle(
    fontSize: 32,
    height: 38 / 32,
    fontWeight: FontWeight.w700,
    color: AppColors.black,
  );

  /// Title: 22 / 28, w700. Used for screen titles and section leads.
  static const TextStyle title = TextStyle(
    fontSize: 22,
    height: 28 / 22,
    fontWeight: FontWeight.w700,
    color: AppColors.black,
  );

  /// Heading: 18 / 24, w700. Used for card and bottom-sheet headings.
  static const TextStyle heading = TextStyle(
    fontSize: 18,
    height: 24 / 18,
    fontWeight: FontWeight.w700,
    color: AppColors.black,
  );

  /// Body: 15 / 22, w500. Used for primary running text and form inputs.
  static const TextStyle body = TextStyle(
    fontSize: 15,
    height: 22 / 15,
    fontWeight: FontWeight.w500,
    color: AppColors.black,
  );

  /// Label: 13 / 18, w600. Used for buttons, form labels, and chips.
  static const TextStyle label = TextStyle(
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w600,
    color: AppColors.black,
  );

  /// Micro: 11 / 14, w600. Used for badges, captions, and metadata rows.
  static const TextStyle micro = TextStyle(
    fontSize: 11,
    height: 14 / 11,
    fontWeight: FontWeight.w600,
    color: AppColors.black,
  );
}
