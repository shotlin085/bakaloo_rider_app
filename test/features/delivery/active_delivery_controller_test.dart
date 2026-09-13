import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bakaloo_rider_app/core/maps/geo_point.dart';
import 'package:bakaloo_rider_app/features/delivery/application/active_delivery_controller.dart';
import 'package:bakaloo_rider_app/features/delivery/domain/assignment_status.dart';
import 'package:bakaloo_rider_app/features/delivery/domain/delivery_address.dart';
import 'package:bakaloo_rider_app/features/delivery/domain/delivery_item.dart';
import 'package:bakaloo_rider_app/features/delivery/domain/delivery_order.dart';

DeliveryOrder _order(
  String id,
  AssignmentStatus status, {
  bool quickDeliverySelected = false,
  DateTime? scheduledSlotStart,
  DateTime? createdAt,
  double? customerLat,
  double? customerLng,
}) =>
    DeliveryOrder(
      orderId: id,
      orderNumber: id,
      assignmentStatus: status,
      totalAmount: 100.0,
      paymentMethod: 'ONLINE',
      riderEarning: 10.0,
      estimatedDuration: 10,
      customerAddress: DeliveryAddress(
        name: 'Customer',
        address: 'Addr',
        lat: customerLat,
        lng: customerLng,
      ),
      storeAddress: DeliveryAddress(name: 'Store', address: 'Store Addr'),
      items: const <DeliveryItem>[],
      quickDeliverySelected: quickDeliverySelected,
      scheduledSlotStart: scheduledSlotStart,
      createdAt: createdAt,
    );

void main() {
  late ActiveDeliveryController controller;

  setUp(() {
    controller = ActiveDeliveryController();
  });

  tearDown(() {
    controller.dispose();
  });

  test('starts with no active delivery', () {
    expect(controller.current, isNull);
  });

  test('setActiveDelivery / clearActiveDelivery notify listeners', () {
    int notifyCount = 0;
    controller.addListener(() => notifyCount++);

    controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
    expect(controller.current?.orderId, 'o1');
    expect(notifyCount, 1);

    controller.clearActiveDelivery();
    expect(controller.current, isNull);
    expect(notifyCount, 2);
  });

  group('applyExternalStatus enforces monotonic walk', () {
    test('legal transition accepted → inTransit updates current', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.applyExternalStatus('o1', AssignmentStatus.inTransit);
      expect(
        controller.current?.assignmentStatus,
        AssignmentStatus.inTransit,
      );
    });

    test('illegal transition is rejected (state unchanged)', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.inTransit));
      // Illegal: inTransit → accepted
      controller.applyExternalStatus('o1', AssignmentStatus.accepted);
      expect(
        controller.current?.assignmentStatus,
        AssignmentStatus.inTransit,
      );
    });

    test('illegal transition does NOT notify listeners', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.inTransit));
      bool notified = false;
      controller.addListener(() => notified = true);

      controller.applyExternalStatus('o1', AssignmentStatus.accepted);
      expect(notified, isFalse);
    });

    test('terminal transition delivered clears the active delivery', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.inTransit));
      controller.applyExternalStatus('o1', AssignmentStatus.delivered);
      expect(controller.current, isNull);
    });

    test('terminal transition cancelled clears the active delivery', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.applyExternalStatus('o1', AssignmentStatus.cancelled);
      expect(controller.current, isNull);
    });

    test('no-op when orderId does not match current delivery', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.applyExternalStatus('other', AssignmentStatus.inTransit);
      expect(
        controller.current?.assignmentStatus,
        AssignmentStatus.accepted,
      );
    });

    test('no-op when no active delivery exists', () {
      bool notified = false;
      controller.addListener(() => notified = true);
      controller.applyExternalStatus('o1', AssignmentStatus.accepted);
      expect(notified, isFalse);
      expect(controller.current, isNull);
    });

    test('full monotonic walk: accepted → inTransit → delivered', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));

      controller.applyExternalStatus('o1', AssignmentStatus.inTransit);
      expect(
        controller.current?.assignmentStatus,
        AssignmentStatus.inTransit,
      );

      controller.applyExternalStatus('o1', AssignmentStatus.delivered);
      expect(controller.current, isNull);
    });

    test('idempotent self-transition does nothing observable', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      bool notified = false;
      controller.addListener(() => notified = true);
      controller.applyExternalStatus('o1', AssignmentStatus.accepted);
      expect(notified, isFalse);
      expect(
        controller.current?.assignmentStatus,
        AssignmentStatus.accepted,
      );
    });
  });

  group('batch behaviour (Phase C)', () {
    test('adding a second order does not steal focus from the first', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.addOrUpdate(_order('o2', AssignmentStatus.accepted));

      expect(controller.current?.orderId, 'o1');
      expect(controller.batch.map((DeliveryOrder o) => o.orderId), <String>['o1', 'o2']);
    });

    test('byId looks up any batch order regardless of focus', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.addOrUpdate(_order('o2', AssignmentStatus.inTransit));

      expect(controller.byId('o2')?.assignmentStatus, AssignmentStatus.inTransit);
      expect(controller.byId('missing'), isNull);
    });

    test('focusOrder switches which order `current` returns', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.addOrUpdate(_order('o2', AssignmentStatus.accepted));

      controller.focusOrder('o2');
      expect(controller.current?.orderId, 'o2');
    });

    test('focusOrder is a no-op for an order not in the batch', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.focusOrder('not-in-batch');
      expect(controller.current?.orderId, 'o1');
    });

    test('clearActiveDelivery removes only the focused order and auto-advances', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.addOrUpdate(_order('o2', AssignmentStatus.accepted));

      controller.clearActiveDelivery();

      expect(controller.byId('o1'), isNull, reason: 'o1 should be removed');
      expect(controller.current?.orderId, 'o2', reason: 'focus should auto-advance to the remaining order');
      expect(controller.batch, hasLength(1));
    });

    test('clearActiveDelivery on the last order leaves an empty batch', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.clearActiveDelivery();

      expect(controller.current, isNull);
      expect(controller.batch, isEmpty);
    });

    test('remove() drops an order from the batch and auto-advances if it was focused', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.addOrUpdate(_order('o2', AssignmentStatus.accepted));

      controller.remove('o1');

      expect(controller.byId('o1'), isNull);
      expect(controller.current?.orderId, 'o2');
    });

    test('remove() on a non-focused order does not disturb the focused one', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.addOrUpdate(_order('o2', AssignmentStatus.accepted));

      controller.remove('o2');

      expect(controller.current?.orderId, 'o1');
      expect(controller.batch, hasLength(1));
    });

    test('applyExternalStatus on a non-focused batch order updates it without touching focus', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.addOrUpdate(_order('o2', AssignmentStatus.accepted));

      controller.applyExternalStatus('o2', AssignmentStatus.inTransit);

      expect(controller.current?.orderId, 'o1', reason: 'focus must not move');
      expect(controller.byId('o2')?.assignmentStatus, AssignmentStatus.inTransit);
    });

    test('applyExternalStatus terminal on a non-focused order removes just that one', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.addOrUpdate(_order('o2', AssignmentStatus.inTransit));

      controller.applyExternalStatus('o2', AssignmentStatus.delivered);

      expect(controller.current?.orderId, 'o1');
      expect(controller.byId('o2'), isNull);
      expect(controller.batch, hasLength(1));
    });

    test('isBusyFor is scoped per order, unlike the legacy global isBusy', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.addOrUpdate(_order('o2', AssignmentStatus.accepted));

      // No network calls in flight yet.
      expect(controller.isBusyFor('o1'), isFalse);
      expect(controller.isBusyFor('o2'), isFalse);
      expect(controller.isBusy, isFalse);
    });
  });

  group('skip', () {
    test('moves focus to the next ready order without changing status', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.inTransit));
      controller.addOrUpdate(_order('o2', AssignmentStatus.inTransit));

      controller.skip('o1');

      expect(controller.current?.orderId, 'o2');
      expect(controller.byId('o1'), isNotNull, reason: 'skipped order stays in the batch');
      expect(controller.byId('o1')?.assignmentStatus, AssignmentStatus.inTransit);
      expect(controller.batch, hasLength(2));
    });

    test('skipped order is revisited once no other ready order remains', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.inTransit));
      controller.addOrUpdate(_order('o2', AssignmentStatus.inTransit));

      controller.skip('o1');
      expect(controller.current?.orderId, 'o2');

      // o2 delivered — o1 (skipped) is the only one left, so it must come
      // back into focus rather than leaving nothing focused.
      controller.applyExternalStatus('o2', AssignmentStatus.delivered);
      expect(controller.current?.orderId, 'o1');
    });

    test('no-ops when orderId is not the currently focused order', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.inTransit));
      controller.addOrUpdate(_order('o2', AssignmentStatus.inTransit));

      controller.skip('o2'); // o2 isn't focused — o1 is.

      expect(controller.current?.orderId, 'o1', reason: 'skip only applies to the focused order');
    });
  });

  group('multi-stop priority sequencing (Phase D)', () {
    test(
        'auto-advance after clearActiveDelivery focuses the Express order '
        'over a standard order that was added first', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.addOrUpdate(_order('o2', AssignmentStatus.inTransit));
      controller.addOrUpdate(
        _order('o3', AssignmentStatus.inTransit, quickDeliverySelected: true),
      );

      controller.clearActiveDelivery();

      expect(
        controller.current?.orderId,
        'o3',
        reason: 'Express order must win auto-advance even though o2 (standard) was added earlier',
      );
    });

    test(
        'auto-advance picks the earliest scheduledSlotStart within the same '
        'priority tier, regardless of insertion order', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.addOrUpdate(
        _order(
          'o2',
          AssignmentStatus.inTransit,
          scheduledSlotStart: DateTime(2026, 1, 1, 10, 30),
        ),
      );
      controller.addOrUpdate(
        _order(
          'o3',
          AssignmentStatus.inTransit,
          scheduledSlotStart: DateTime(2026, 1, 1, 10, 0),
        ),
      );

      controller.clearActiveDelivery();

      expect(
        controller.current?.orderId,
        'o3',
        reason: 'o3 has the earlier scheduled slot even though o2 was added first',
      );
    });

    test(
        'auto-advance falls back to any remaining order when none are '
        'in-transit yet', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.inTransit));
      controller.addOrUpdate(
        _order('o2', AssignmentStatus.accepted, quickDeliverySelected: true),
      );

      controller.remove('o1');

      expect(
        controller.current?.orderId,
        'o2',
        reason: 'o2 is the only remaining order even though it is not yet in-transit',
      );
    });

    test(
        'remove() on a non-focused order re-sorts the pending pool so the '
        'next auto-advance still honours priority', () {
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.addOrUpdate(_order('o2', AssignmentStatus.inTransit));
      controller.addOrUpdate(
        _order('o3', AssignmentStatus.inTransit, quickDeliverySelected: true),
      );

      // o3 (Express) is not focused yet; removing a bystander must not
      // disturb who wins the next auto-advance.
      controller.remove('o2');
      controller.clearActiveDelivery();

      expect(controller.current?.orderId, 'o3');
    });
  });

  group('distance-aware auto-advance (item 8/9: real-map sequencing)', () {
    const GeoPoint rider = GeoPoint(22.50, 88.30);

    test('picks the physically closer order over an earlier-placed one', () {
      final ValueNotifier<GeoPoint?> riderLocation =
          ValueNotifier<GeoPoint?>(rider);
      final ActiveDeliveryController withLocation =
          ActiveDeliveryController(riderLocation: riderLocation);

      withLocation.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      withLocation.addOrUpdate(
        _order(
          'o2',
          AssignmentStatus.inTransit,
          customerLat: 23.50,
          customerLng: 89.30, // far
          createdAt: DateTime(2026, 8, 15, 9), // placed earlier
        ),
      );
      withLocation.addOrUpdate(
        _order(
          'o3',
          AssignmentStatus.inTransit,
          customerLat: 22.51,
          customerLng: 88.31, // near
          createdAt: DateTime(2026, 8, 15, 12), // placed later
        ),
      );

      withLocation.clearActiveDelivery();

      expect(
        withLocation.current?.orderId,
        'o3',
        reason: 'o3 is physically closer even though o2 was placed earlier',
      );
      withLocation.dispose();
    });

    test('still gives Express priority over a physically closer standard order', () {
      final ValueNotifier<GeoPoint?> riderLocation =
          ValueNotifier<GeoPoint?>(rider);
      final ActiveDeliveryController withLocation =
          ActiveDeliveryController(riderLocation: riderLocation);

      withLocation.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      withLocation.addOrUpdate(
        _order(
          'o2',
          AssignmentStatus.inTransit,
          customerLat: 22.51,
          customerLng: 88.31, // near, standard
        ),
      );
      withLocation.addOrUpdate(
        _order(
          'o3',
          AssignmentStatus.inTransit,
          quickDeliverySelected: true,
          customerLat: 23.50,
          customerLng: 89.30, // far, Express
        ),
      );

      withLocation.clearActiveDelivery();

      expect(withLocation.current?.orderId, 'o3');
      withLocation.dispose();
    });

    test('without a riderLocation dependency, falls back to time-based ordering', () {
      // The shared `controller` from setUp() has no riderLocation wired —
      // matches every other test in this file (constructed with no args).
      controller.setActiveDelivery(_order('o1', AssignmentStatus.accepted));
      controller.addOrUpdate(
        _order(
          'o2',
          AssignmentStatus.inTransit,
          customerLat: 23.50,
          customerLng: 89.30,
          createdAt: DateTime(2026, 8, 15, 12),
        ),
      );
      controller.addOrUpdate(
        _order(
          'o3',
          AssignmentStatus.inTransit,
          customerLat: 22.51,
          customerLng: 88.31,
          createdAt: DateTime(2026, 8, 15, 9),
        ),
      );

      controller.clearActiveDelivery();

      expect(
        controller.current?.orderId,
        'o3',
        reason: 'earliest createdAt wins when no live GPS fix is available',
      );
    });
  });
}
