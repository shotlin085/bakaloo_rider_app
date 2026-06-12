import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grolin_rider_app/core/providers.dart';
import 'package:grolin_rider_app/features/delivery/application/offers_controller.dart';
import 'package:grolin_rider_app/features/delivery/data/delivery_api.dart';
import 'package:grolin_rider_app/features/delivery/data/delivery_repository.dart';
import 'package:grolin_rider_app/features/delivery/domain/assignment_status.dart';
import 'package:grolin_rider_app/features/delivery/domain/delivery_address.dart';
import 'package:grolin_rider_app/features/delivery/domain/delivery_item.dart';
import 'package:grolin_rider_app/features/delivery/domain/delivery_order.dart';
import 'package:grolin_rider_app/features/delivery/presentation/delivery_offer_sheet.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/fake_socket_client.dart';

class _MockDeliveryRepository extends Mock implements DeliveryRepository {}

DeliveryOrder _sampleOrder() => DeliveryOrder(
      orderId: 'order-1',
      orderNumber: 'ORD-001',
      assignmentStatus: AssignmentStatus.assigned,
      totalAmount: 540.0,
      paymentMethod: 'COD',
      riderEarning: 65.0,
      estimatedDistance: 2.4,
      estimatedDuration: 18,
      customerAddress: DeliveryAddress(
        name: 'Priya N',
        address: '12 MG Road, Bengaluru',
        landmark: 'Near Coffee Day',
      ),
      storeAddress: DeliveryAddress(
        name: 'Grolin Indiranagar',
        address: '100 Feet Rd, Indiranagar',
      ),
      items: const <DeliveryItem>[
        DeliveryItem(
          id: 'i1',
          name: 'Rice 5kg',
          quantity: 1,
          unitPrice: 450,
          totalPrice: 450,
        ),
        DeliveryItem(
          id: 'i2',
          name: 'Dal',
          quantity: 2,
          unitPrice: 45,
          totalPrice: 90,
        ),
      ],
    );

Widget _harness({
  required Widget child,
  required OffersController controller,
}) {
  return ProviderScope(
    overrides: [
      offersControllerProvider.overrideWith((Ref ref) => controller),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(RejectReason.other);
  });

  Future<void> _setPhoneSize(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  testWidgets(
    'tapping Accept calls OffersController.acceptOffer with the order id',
    (WidgetTester tester) async {
      await _setPhoneSize(tester);

      final _MockDeliveryRepository repo = _MockDeliveryRepository();
      final FakeSocketClient socket = FakeSocketClient();
      final OffersController controller =
          OffersController(repository: repo, socket: socket);
      final DeliveryOrder order = _sampleOrder();
      controller.upsertOffer(order);

      when(() => repo.acceptOrder(order.orderId))
          .thenAnswer((_) async => <String, dynamic>{});

      OfferSheetResult? result;
      await tester.pumpWidget(_harness(
        controller: controller,
        child: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showDeliveryOfferSheet(context, order);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Sheet is visible.
      expect(find.text('New delivery offer'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);

      // Drag the sheet up to its largest snap so the Accept button is
      // within the test viewport.
      await tester.drag(
        find.text('New delivery offer'),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();

      verify(() => repo.acceptOrder(order.orderId)).called(1);
      expect(result?.outcome, OfferSheetOutcome.accepted);
    },
  );

  testWidgets(
    'tapping Decline opens reason picker; selecting reason calls reject',
    (WidgetTester tester) async {
      await _setPhoneSize(tester);

      final _MockDeliveryRepository repo = _MockDeliveryRepository();
      final FakeSocketClient socket = FakeSocketClient();
      final OffersController controller =
          OffersController(repository: repo, socket: socket);
      final DeliveryOrder order = _sampleOrder();
      controller.upsertOffer(order);

      when(() => repo.rejectOrder(order.orderId, RejectReason.tooFar.wire))
          .thenAnswer((_) async {});

      OfferSheetResult? result;
      await tester.pumpWidget(_harness(
        controller: controller,
        child: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showDeliveryOfferSheet(context, order);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.drag(
        find.text('New delivery offer'),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();

      // Reason picker visible.
      expect(find.text('Decline this order'), findsOneWidget);
      expect(find.text('Too far'), findsOneWidget);
      expect(find.text('Vehicle issue'), findsOneWidget);
      expect(find.text('Personal reason'), findsOneWidget);
      expect(find.text('Other'), findsOneWidget);

      await tester.tap(find.text('Too far'));
      await tester.pumpAndSettle();

      verify(() =>
              repo.rejectOrder(order.orderId, RejectReason.tooFar.wire))
          .called(1);
      expect(result?.outcome, OfferSheetOutcome.declined);
    },
  );
}
