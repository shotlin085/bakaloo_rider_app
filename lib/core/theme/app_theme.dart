import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_typography.dart';

/// Tied-together [ThemeData] for the Grolin Rider App.
///
/// `AppTheme` is the single seam where colors, typography, and component
/// surfaces meet so screens never reach into raw [Color]/[TextStyle]
/// constants directly. The result is the premium minimal black-on-white
/// language called out in the design: white scaffolds, charcoal
/// foregrounds on the AppBar, hairline 1dp dividers, and Cupertino-style
/// transitions on iOS with the predictive-back animation on Android.
///
/// The class is `abstract final` so it can never be instantiated or
/// extended. Callers consume the theme via [AppTheme.light].
abstract final class AppTheme {
  /// Builds the light theme for the rider app.
  ///
  /// We deliberately rebuild on each call (rather than caching) so unit
  /// tests can assert behavior on a fresh instance and so future
  /// hot-reload edits to tokens propagate without a stale cached theme.
  static ThemeData light() {
    const ColorScheme colorScheme = ColorScheme.light(
      primary: AppColors.black,
      onPrimary: AppColors.white,
      surface: AppColors.white,
      onSurface: AppColors.charcoal,
      surfaceContainerHighest: AppColors.offWhite,
      outline: AppColors.border,
      error: AppColors.danger,
    );

    final TextTheme textTheme = _buildTextTheme();

    // Bootstrap installs light status-bar icons over a transparent status
    // bar; declaring the same overlay style on the AppBar prevents Flutter
    // from silently re-asserting platform defaults the moment a Scaffold
    // pushes its own AppBar. The AppBar background is white, but bootstrap
    // owns the global chrome contract, so we mirror it here.
    const SystemUiOverlayStyle overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: AppColors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
      systemNavigationBarDividerColor: Colors.transparent,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.white,
      canvasColor: AppColors.white,
      // `Typography.material2021` is the M3-correct base; `textTheme`
      // overrides the styles screens actually consume.
      typography: Typography.material2021(platform: TargetPlatform.android),
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: const IconThemeData(color: AppColors.charcoal, size: 22),
      primaryIconTheme: const IconThemeData(color: AppColors.charcoal, size: 22),
      // Premium minimal feedback: no rippling ink wash on taps.
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.charcoal,
        surfaceTintColor: AppColors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle: overlayStyle,
        iconTheme: IconThemeData(color: AppColors.charcoal, size: 22),
        titleTextStyle: TextStyle(
          fontSize: 18,
          height: 24 / 18,
          fontWeight: FontWeight.w700,
          color: AppColors.charcoal,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.white,
        surfaceTintColor: AppColors.white,
        modalBackgroundColor: AppColors.white,
        elevation: 0,
        modalElevation: 0,
        showDragHandle: false,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(28),
          ),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),
      // Explicit page transitions so release builds ship them: Cupertino
      // on iOS/macOS keeps the swipe-to-dismiss feel, while Android picks
      // up Flutter's predictive-back integration on Android 14+.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        },
      ),
    );
  }

  /// Maps the [AppTypography] scale onto Material 3's [TextTheme] slots.
  ///
  /// `displayMedium` is the canonical home for [AppTypography.display] so
  /// `Theme.of(context).textTheme.displayMedium` resolves to the rider
  /// app's hero size. The other slots fan out across the M3 vocabulary so
  /// out-of-the-box widgets (AppBar titles, list-tile primaries, etc.)
  /// inherit the rider scale without bespoke wrapping.
  static TextTheme _buildTextTheme() {
    return const TextTheme(
      displayLarge: AppTypography.display,
      displayMedium: AppTypography.display,
      displaySmall: AppTypography.title,
      headlineLarge: AppTypography.title,
      headlineMedium: AppTypography.title,
      headlineSmall: AppTypography.heading,
      titleLarge: AppTypography.heading,
      titleMedium: AppTypography.heading,
      titleSmall: AppTypography.label,
      bodyLarge: AppTypography.body,
      bodyMedium: AppTypography.body,
      bodySmall: AppTypography.label,
      labelLarge: AppTypography.label,
      labelMedium: AppTypography.label,
      labelSmall: AppTypography.micro,
    );
  }
}
