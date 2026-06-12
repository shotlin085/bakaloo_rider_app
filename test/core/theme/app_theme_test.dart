import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:grolin_rider_app/core/theme/app_colors.dart';
import 'package:grolin_rider_app/core/theme/app_theme.dart';
import 'package:grolin_rider_app/core/theme/app_typography.dart';

void main() {
  group('AppTheme.light()', () {
    final ThemeData theme = AppTheme.light();

    test('uses Material 3', () {
      expect(theme.useMaterial3, isTrue);
    });

    test('paints scaffolds with the white token', () {
      expect(theme.scaffoldBackgroundColor, AppColors.white);
    });

    test('binds primary color scheme to design tokens', () {
      final ColorScheme cs = theme.colorScheme;
      expect(cs.primary, AppColors.black);
      expect(cs.onPrimary, AppColors.white);
      expect(cs.surface, AppColors.white);
      expect(cs.onSurface, AppColors.charcoal);
      expect(cs.surfaceContainerHighest, AppColors.offWhite);
      expect(cs.outline, AppColors.border);
      expect(cs.error, AppColors.danger);
    });

    test('exposes the display token via TextTheme.displayMedium', () {
      final TextStyle? displayMedium = theme.textTheme.displayMedium;
      expect(displayMedium, isNotNull);
      expect(displayMedium!.fontSize, AppTypography.display.fontSize);
      expect(displayMedium.fontWeight, AppTypography.display.fontWeight);
      expect(displayMedium.height, AppTypography.display.height);
      // The color is part of the AppTypography contract; widgets may
      // override it, but the default mapped style should still carry it.
      expect(displayMedium.color, AppTypography.display.color);
    });

    test('AppBarTheme is white with charcoal foreground and no elevation', () {
      final AppBarThemeData appBar = theme.appBarTheme;
      expect(appBar.backgroundColor, AppColors.white);
      expect(appBar.foregroundColor, AppColors.charcoal);
      expect(appBar.elevation, 0);
      expect(appBar.scrolledUnderElevation, 0);
      expect(appBar.systemOverlayStyle, isNotNull);
    });

    test('BottomSheetTheme is white with a 28dp top radius', () {
      final BottomSheetThemeData bs = theme.bottomSheetTheme;
      expect(bs.backgroundColor, AppColors.white);
      expect(bs.elevation, 0);
      final ShapeBorder? shape = bs.shape;
      expect(shape, isA<RoundedRectangleBorder>());
      final RoundedRectangleBorder rounded = shape! as RoundedRectangleBorder;
      final BorderRadius radius = rounded.borderRadius as BorderRadius;
      expect(radius.topLeft, const Radius.circular(28));
      expect(radius.topRight, const Radius.circular(28));
    });

    test('DividerTheme uses the border token at 1dp', () {
      expect(theme.dividerTheme.color, AppColors.border);
      expect(theme.dividerTheme.thickness, 1);
    });

    test('IconTheme uses charcoal at 22dp', () {
      expect(theme.iconTheme.color, AppColors.charcoal);
      expect(theme.iconTheme.size, 22);
    });

    test('splashFactory is NoSplash for the premium minimal feel', () {
      expect(theme.splashFactory, NoSplash.splashFactory);
    });

    test('PageTransitionsTheme is set explicitly per platform', () {
      final Map<TargetPlatform, PageTransitionsBuilder> builders =
          theme.pageTransitionsTheme.builders;
      expect(builders[TargetPlatform.iOS],
          isA<CupertinoPageTransitionsBuilder>());
      expect(builders[TargetPlatform.android],
          isA<PredictiveBackPageTransitionsBuilder>());
    });
  });
}
