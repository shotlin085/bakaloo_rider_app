import 'package:flutter_test/flutter_test.dart';
import 'package:grolin_rider_app/features/delivery/application/active_delivery_controller.dart';
import 'package:grolin_rider_app/features/delivery/domain/assignment_status.dart';
import 'package:grolin_rider_app/features/delivery/domain/delivery_address.dart';
import 'package:grolin_rider_app/features/delivery/domain/delivery_item.dart';
import 'package:grolin_rider_app/features/delivery/domain/delivery_order.dart';

DeliveryOrder _order(String id, AssignmentStatus status) => DeliveryOrder(
      orderId: id,
      orderNumber: id,
      assignmentStatus: status,
      totalAmount: 100.0,
      paymentMethod: 'ONLINE',
      riderEarning: 10.0,
      estimatedDuration: 10,
      customerAddress: DeliveryAddress(name: 'Customer', address: 'Addr'),
      storeAddress: DeliveryAddress(name: 'Store', address: 'Store Addr'),
      items: const <DeliveryItem>[],
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
}
