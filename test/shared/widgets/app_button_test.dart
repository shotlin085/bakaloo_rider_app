import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:grolin_rider_app/core/theme/app_colors.dart';
import 'package:grolin_rider_app/shared/widgets/app_button.dart';

void main() {
  Future<void> pumpButton(
    WidgetTester tester, {
    required AppButtonVariant variant,
    VoidCallback? onPressed,
    bool isLoading = false,
    String label = 'Action',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AppButton(
              label: label,
              variant: variant,
              isLoading: isLoading,
              onPressed: onPressed,
            ),
          ),
        ),
      ),
    );
  }

  Material materialFor(WidgetTester tester) {
    // The button surface is the topmost Material descendant inside the
    // AppButton. Filter on the design-system colors so we don't grab
    // the Scaffold's Material.
    final Iterable<Material> materials =
        tester.widgetList<Material>(find.byType(Material));
    return materials.firstWhere(
      (Material m) =>
          m.color == AppColors.black ||
          m.color == AppColors.white ||
          m.color == AppColors.success ||
          (m.color != null &&
              (m.color!.toARGB32() == AppColors.black.toARGB32() ||
                  m.color!.toARGB32() == AppColors.white.toARGB32() ||
                  m.color!.toARGB32() == AppColors.success.toARGB32())),
    );
  }

  Container surfaceContainerFor(WidgetTester tester) {
    // The bordered container is the Container we built inside the
    // InkWell. Its decoration is a BoxDecoration so we can read the
    // border color back.
    final Iterable<Container> containers =
        tester.widgetList<Container>(find.byType(Container));
    return containers.firstWhere(
      (Container c) => c.decoration is BoxDecoration,
    );
  }

  group('AppButton variants', () {
    testWidgets('primary uses black surface with white label and no border',
        (WidgetTester tester) async {
      await pumpButton(
        tester,
        variant: AppButtonVariant.primary,
        onPressed: () {},
      );

      final Material material = materialFor(tester);
      expect(material.color, AppColors.black);

      final Text text = tester.widget<Text>(find.text('Action'));
      expect(text.style?.color, AppColors.white);

      final Container surface = surfaceContainerFor(tester);
      final BoxDecoration decoration = surface.decoration! as BoxDecoration;
      expect(decoration.border, isNull);
    });

    testWidgets(
        'secondary uses white surface with charcoal label and 1dp border',
        (WidgetTester tester) async {
      await pumpButton(
        tester,
        variant: AppButtonVariant.secondary,
        onPressed: () {},
      );

      final Material material = materialFor(tester);
      expect(material.color, AppColors.white);

      final Text text = tester.widget<Text>(find.text('Action'));
      expect(text.style?.color, AppColors.charcoal);

      final Container surface = surfaceContainerFor(tester);
      final BoxDecoration decoration = surface.decoration! as BoxDecoration;
      final Border border = decoration.border! as Border;
      expect(border.top.color, AppColors.border);
      expect(border.top.width, 1);
    });

    testWidgets(
        'danger uses white surface with danger label and danger border',
        (WidgetTester tester) async {
      await pumpButton(
        tester,
        variant: AppButtonVariant.danger,
        onPressed: () {},
      );

      final Material material = materialFor(tester);
      expect(material.color, AppColors.white);

      final Text text = tester.widget<Text>(find.text('Action'));
      expect(text.style?.color, AppColors.danger);

      final Container surface = surfaceContainerFor(tester);
      final BoxDecoration decoration = surface.decoration! as BoxDecoration;
      final Border border = decoration.border! as Border;
      expect(border.top.color, AppColors.danger);
      expect(border.top.width, 1);
    });

    testWidgets('success uses success surface with white label and no border',
        (WidgetTester tester) async {
      await pumpButton(
        tester,
        variant: AppButtonVariant.success,
        onPressed: () {},
      );

      final Material material = materialFor(tester);
      expect(material.color, AppColors.success);

      final Text text = tester.widget<Text>(find.text('Action'));
      expect(text.style?.color, AppColors.white);

      final Container surface = surfaceContainerFor(tester);
      final BoxDecoration decoration = surface.decoration! as BoxDecoration;
      expect(decoration.border, isNull);
    });
  });

  group('AppButton interaction state', () {
    testWidgets('null onPressed disables the InkWell',
        (WidgetTester tester) async {
      await pumpButton(
        tester,
        variant: AppButtonVariant.primary,
        // ignore: avoid_redundant_argument_values
        onPressed: null,
      );

      final InkWell ink = tester.widget<InkWell>(find.byType(InkWell));
      expect(ink.onTap, isNull);
    });

    testWidgets('isLoading replaces the label with a 16dp spinner',
        (WidgetTester tester) async {
      await pumpButton(
        tester,
        variant: AppButtonVariant.primary,
        onPressed: () {},
        isLoading: true,
      );

      expect(find.text('Action'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // The spinner is constrained to a 16x16 box.
      final SizedBox box = tester.widget<SizedBox>(
        find
            .ancestor(
              of: find.byType(CircularProgressIndicator),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(box.height, 16);
      expect(box.width, 16);

      // While loading, taps are inert.
      final InkWell ink = tester.widget<InkWell>(find.byType(InkWell));
      expect(ink.onTap, isNull);
    });

    testWidgets('tapping a primary button fires onPressed',
        (WidgetTester tester) async {
      int taps = 0;
      await pumpButton(
        tester,
        variant: AppButtonVariant.primary,
        onPressed: () => taps++,
      );

      await tester.tap(find.byType(AppButton));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('tap target is at least 48 dp tall',
        (WidgetTester tester) async {
      await pumpButton(
        tester,
        variant: AppButtonVariant.primary,
        onPressed: () {},
      );

      final Size size = tester.getSize(find.byType(AppButton));
      expect(size.height, greaterThanOrEqualTo(48));
    });
  });
}
