import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:flutter_test/flutter_test.dart';
import 'package:bakaloo_rider_app/core/maps/geo_point.dart';
import 'package:bakaloo_rider_app/core/maps/marker_assets.dart';
import 'package:bakaloo_rider_app/features/delivery/application/active_delivery_map_controller.dart';
import 'package:bakaloo_rider_app/features/delivery/domain/assignment_status.dart';
import 'package:bakaloo_rider_app/features/delivery/domain/delivery_address.dart';
import 'package:bakaloo_rider_app/features/delivery/domain/delivery_item.dart';
import 'package:bakaloo_rider_app/features/delivery/domain/delivery_order.dart';
import 'package:bakaloo_rider_app/features/delivery/domain/store_info.dart';

DeliveryOrder _order({
  required AssignmentStatus status,
  String orderId = 'order-1',
  bool quickDeliverySelected = false,
  double? storeLat,
  double? storeLng,
  double? customerLat,
  double? customerLng,
}) {
  return DeliveryOrder(
    orderId: orderId,
    orderNumber: orderId,
    assignmentStatus: status,
    totalAmount: 100,
    paymentMethod: 'COD',
    riderEarning: 50,
    estimatedDuration: 12,
    quickDeliverySelected: quickDeliverySelected,
    customerAddress: DeliveryAddress(
      name: 'Customer',
      address: 'Drop addr',
      lat: customerLat,
      lng: customerLng,
    ),
    storeAddress: DeliveryAddress(
      name: 'Store',
      address: 'Pickup addr',
      lat: storeLat,
      lng: storeLng,
    ),
    items: const <DeliveryItem>[],
  );
}

ActiveDeliveryMapController _newController() {
  final MarkerAssets assets = MarkerAssets();
  // ignore: invalid_use_of_visible_for_testing_member
  assets.warmForTesting();
  return ActiveDeliveryMapController(markerAssets: assets);
}

void main() {
  setUp(() {
    MarkerAssets.resetForTesting();
  });

  group('ActiveDeliveryMapController.applyOrder', () {
    test('ACCEPTED phase produces a polyline rider→store (R12.2)', () {
      final ActiveDeliveryMapController controller = _newController();
      controller.updateRiderPosition(const GeoPoint(12.95, 77.60));
      controller.applyOrder(
        _order(
          status: AssignmentStatus.accepted,
          storeLat: 12.97,
          storeLng: 77.59,
          customerLat: 12.93,
          customerLng: 77.62,
        ),
        null,
      );

      expect(controller.phase, LocationPhase.toStore);
      expect(controller.polylines, isNotEmpty);
      final fm.Polyline route = controller.polylines.last;
      expect(route.points.first.latitude, 12.95);
      expect(route.points.first.longitude, 77.60);
      expect(route.points.last.latitude, 12.97);
      expect(route.points.last.longitude, 77.59);
    });

    test('IN_TRANSIT phase produces a polyline rider→customer (R12.3)', () {
      final ActiveDeliveryMapController controller = _newController();
      controller.updateRiderPosition(const GeoPoint(12.95, 77.60));
      controller.applyOrder(
        _order(
          status: AssignmentStatus.inTransit,
          storeLat: 12.97,
          storeLng: 77.59,
          customerLat: 12.93,
          customerLng: 77.62,
        ),
        null,
      );

      expect(controller.phase, LocationPhase.toCustomer);
      expect(controller.polylines, isNotEmpty);
      final fm.Polyline route = controller.polylines.last;
      expect(route.points.first.latitude, 12.95);
      expect(route.points.last.latitude, 12.93);
      expect(route.points.last.longitude, 77.62);
    });

    test(
      'falls back to StoreInfo coordinates when the order payload has '
      'no store coords (R12.4)',
      () {
        final ActiveDeliveryMapController controller = _newController();
        controller.updateRiderPosition(const GeoPoint(12.95, 77.60));
        final StoreInfo store = StoreInfo(
          name: 'Hub',
          address: 'Hub address',
          lat: 12.985,
          lng: 77.575,
        );

        controller.applyOrder(
          _order(
            status: AssignmentStatus.accepted,
            customerLat: 12.93,
            customerLng: 77.62,
          ),
          store,
        );

        expect(controller.phase, LocationPhase.toStore);
        expect(controller.storePosition, const GeoPoint(12.985, 77.575));
        expect(
          controller.polylines.last.points.last.latitude,
          12.985,
        );
        expect(
          controller.polylines.last.points.last.longitude,
          77.575,
        );
      },
    );

    test(
      'unconfigured StoreInfo (lat=0, lng=0) does not satisfy the '
      'fallback — phase becomes none and no polyline is drawn',
      () {
        final ActiveDeliveryMapController controller = _newController();
        controller.updateRiderPosition(const GeoPoint(12.95, 77.60));
        final StoreInfo unconfigured = StoreInfo(
          name: 'Hub',
          address: 'Hub address',
          lat: 0,
          lng: 0,
        );

        controller.applyOrder(
          _order(status: AssignmentStatus.accepted),
          unconfigured,
        );

        expect(controller.phase, LocationPhase.none);
        expect(controller.polylines, isEmpty);
      },
    );

    test(
      'missing customer coords on IN_TRANSIT flips '
      'customerLocationApproximate and does NOT display customer marker '
      '(Bug Fix - Requirements 2.1, 2.3)',
      () {
        final ActiveDeliveryMapController controller = _newController();
        controller.updateRiderPosition(const GeoPoint(12.95, 77.60));

        controller.applyOrder(
          _order(
            status: AssignmentStatus.inTransit,
            storeLat: 12.97,
            storeLng: 77.59,
          ),
          null,
        );

        expect(controller.customerLocationApproximate, isTrue);
        expect(controller.customerPosition, isNull);
        expect(controller.phase, LocationPhase.none);
        expect(controller.polylines, isEmpty);
      },
    );
  });

  group('ActiveDeliveryMapController.updateRiderPosition', () {
    test(
      'ignores deltas under 5 m (R25.2)',
      () {
        final ActiveDeliveryMapController controller = _newController();
        int notifications = 0;
        controller.addListener(() => notifications++);

        controller.updateRiderPosition(const GeoPoint(12.95, 77.60));
        expect(notifications, 1);

        // Move ~3 m east at this latitude (1° lng ≈ 108 km, so 0.00003° ≈ 3 m).
        controller.updateRiderPosition(const GeoPoint(12.95, 77.60003));
        expect(notifications, 1, reason: 'sub-5 m delta should be dropped');
        expect(controller.riderPosition, const GeoPoint(12.95, 77.60));

        // Move ~10 m east — should publish.
        controller.updateRiderPosition(const GeoPoint(12.95, 77.60010));
        expect(notifications, 2);
        expect(controller.riderPosition, const GeoPoint(12.95, 77.60010));
      },
    );

    test('updates the rider marker once the move clears the threshold', () {
      final ActiveDeliveryMapController controller = _newController();
      controller.updateRiderPosition(const GeoPoint(12.95, 77.60));
      controller.applyOrder(
        _order(
          status: AssignmentStatus.accepted,
          storeLat: 12.97,
          storeLng: 77.59,
        ),
        null,
      );

      controller.updateRiderPosition(const GeoPoint(12.951, 77.601));

      final MarkerEntry? rider = controller.markers['rider'];
      expect(rider, isNotNull);
      expect(rider!.position, const GeoPoint(12.951, 77.601));
      // Polyline first endpoint follows the rider.
      expect(controller.polylines.last.points.first.latitude, 12.951);
      expect(controller.polylines.last.points.first.longitude, 77.601);
    });
  });

  group('ActiveDeliveryMapController.stops (item 8/9: multi-stop map)', () {
    test('empty when applyOrder is called without a batch', () {
      final ActiveDeliveryMapController controller = _newController();
      controller.updateRiderPosition(const GeoPoint(12.95, 77.60));
      controller.applyOrder(
        _order(status: AssignmentStatus.inTransit, customerLat: 12.93, customerLng: 77.62),
        null,
      );

      expect(controller.stops, isEmpty);
    });

    test(
      'ranks every in-transit batch order by distance, including the focused one',
      () {
        final ActiveDeliveryMapController controller = _newController();
        controller.updateRiderPosition(const GeoPoint(12.95, 77.60));

        final DeliveryOrder focused = _order(
          orderId: 'near',
          status: AssignmentStatus.inTransit,
          customerLat: 12.951,
          customerLng: 77.601, // very close
        );
        final DeliveryOrder farther = _order(
          orderId: 'far',
          status: AssignmentStatus.inTransit,
          customerLat: 12.20,
          customerLng: 78.20, // far away
        );

        controller.applyOrder(
          focused,
          null,
          batch: <DeliveryOrder>[focused, farther],
        );

        expect(controller.stops, hasLength(2));
        expect(controller.stops[0].order.orderId, 'near');
        expect(controller.stops[0].rank, 1);
        expect(controller.stops[0].isFocused, isTrue);
        expect(controller.stops[1].order.orderId, 'far');
        expect(controller.stops[1].rank, 2);
        expect(controller.stops[1].isFocused, isFalse);
        expect(controller.stops[1].distanceMeters, greaterThan(controller.stops[0].distanceMeters!));
      },
    );

    test('excludes batch orders that are not in-transit yet', () {
      final ActiveDeliveryMapController controller = _newController();
      controller.updateRiderPosition(const GeoPoint(12.95, 77.60));

      final DeliveryOrder focused = _order(
        orderId: 'in-transit',
        status: AssignmentStatus.inTransit,
        customerLat: 12.951,
        customerLng: 77.601,
      );
      final DeliveryOrder stillAtStore = _order(
        orderId: 'accepted',
        status: AssignmentStatus.accepted,
        customerLat: 12.20,
        customerLng: 78.20,
      );

      controller.applyOrder(
        focused,
        null,
        batch: <DeliveryOrder>[focused, stillAtStore],
      );

      expect(controller.stops, hasLength(1));
      expect(controller.stops.single.order.orderId, 'in-transit');
    });

    test('other-stop markers appear alongside the rider/customer markers', () {
      final ActiveDeliveryMapController controller = _newController();
      controller.updateRiderPosition(const GeoPoint(12.95, 77.60));

      final DeliveryOrder focused = _order(
        orderId: 'near',
        status: AssignmentStatus.inTransit,
        customerLat: 12.951,
        customerLng: 77.601,
      );
      final DeliveryOrder farther = _order(
        orderId: 'far',
        status: AssignmentStatus.inTransit,
        customerLat: 12.20,
        customerLng: 78.20,
      );

      controller.applyOrder(
        focused,
        null,
        batch: <DeliveryOrder>[focused, farther],
      );

      expect(controller.markers.containsKey('rider'), isTrue);
      expect(controller.markers.containsKey('customer'), isTrue);
      expect(controller.markers.containsKey('stop:far'), isTrue);
      // The focused order's own destination is rendered via the
      // 'customer' key, not a duplicate numbered stop marker.
      expect(controller.markers.containsKey('stop:near'), isFalse);
    });

    test('re-ranks stops as the rider moves, without changing focus', () {
      final ActiveDeliveryMapController controller = _newController();
      controller.updateRiderPosition(const GeoPoint(12.95, 77.60));

      final DeliveryOrder focused = _order(
        orderId: 'a',
        status: AssignmentStatus.inTransit,
        customerLat: 12.951,
        customerLng: 77.601,
      );
      final DeliveryOrder other = _order(
        orderId: 'b',
        status: AssignmentStatus.inTransit,
        customerLat: 12.20,
        customerLng: 78.20,
      );

      controller.applyOrder(focused, null, batch: <DeliveryOrder>[focused, other]);
      expect(controller.stops[0].order.orderId, 'a');

      // Rider drives far past 'a' towards 'b' — 'b' should now rank closer,
      // but the focused destination (still 'a', from applyOrder) is unchanged.
      controller.updateRiderPosition(const GeoPoint(12.30, 78.10));

      expect(controller.stops[0].order.orderId, 'b');
      expect(controller.stops.firstWhere((s) => s.isFocused).order.orderId, 'a');
    });

    test(
      'ranks a 3-stop batch by real cascading nearest-neighbor, not flat '
      'distance from the rider',
      () {
        // Same hand-verified geometry as DeliveryOrder.sequenceRoute's test:
        // flat distance-from-rider would rank B before C, but the route
        // must chain through each stop — from A, C is the nearer next hop.
        final ActiveDeliveryMapController controller = _newController();
        controller.updateRiderPosition(const GeoPoint(1.00, 1.00));

        final DeliveryOrder a = _order(
          orderId: 'a',
          status: AssignmentStatus.inTransit,
          customerLat: 1.01,
          customerLng: 1.00,
        );
        final DeliveryOrder b = _order(
          orderId: 'b',
          status: AssignmentStatus.inTransit,
          customerLat: 1.01,
          customerLng: 1.05,
        );
        final DeliveryOrder c = _order(
          orderId: 'c',
          status: AssignmentStatus.inTransit,
          customerLat: 1.052,
          customerLng: 1.00,
        );

        controller.applyOrder(a, null, batch: <DeliveryOrder>[b, c, a]);

        expect(
          controller.stops.map((s) => s.order.orderId).toList(),
          <String>['a', 'c', 'b'],
        );
      },
    );

    test(
      'the map polyline covers the whole planned route, not just the next hop',
      () {
        final ActiveDeliveryMapController controller = _newController();
        controller.updateRiderPosition(const GeoPoint(1.00, 1.00));

        final DeliveryOrder a = _order(
          orderId: 'a',
          status: AssignmentStatus.inTransit,
          customerLat: 1.01,
          customerLng: 1.00,
        );
        final DeliveryOrder c = _order(
          orderId: 'c',
          status: AssignmentStatus.inTransit,
          customerLat: 1.052,
          customerLng: 1.00,
        );
        final DeliveryOrder b = _order(
          orderId: 'b',
          status: AssignmentStatus.inTransit,
          customerLat: 1.01,
          customerLng: 1.05,
        );

        controller.applyOrder(a, null, batch: <DeliveryOrder>[a, b, c]);

        // Route order is a -> c -> b (see the cascading-order test above).
        // Before OSRM resolves, each leg is a straight-line placeholder, so
        // the concatenated polyline should visit rider, a, c, b in order.
        final fm.Polyline route = controller.polylines.last;
        expect(route.points[0].latitude, 1.00); // rider
        expect(route.points[1].latitude, 1.01); // a
        expect(route.points[2].latitude, 1.052); // c
        expect(route.points[3].latitude, 1.01); // b
        expect(route.points[3].longitude, 1.05);
      },
    );

    test(
      'distance/ETA reflect only the immediate next leg, not the whole route',
      () {
        final ActiveDeliveryMapController controller = _newController();
        controller.updateRiderPosition(const GeoPoint(1.00, 1.00));

        final DeliveryOrder a = _order(
          orderId: 'a',
          status: AssignmentStatus.inTransit,
          customerLat: 1.01,
          customerLng: 1.00,
        );
        final DeliveryOrder b = _order(
          orderId: 'b',
          status: AssignmentStatus.inTransit,
          customerLat: 1.01,
          customerLng: 1.05,
        );

        controller.applyOrder(a, null, batch: <DeliveryOrder>[a, b]);

        // Leg 1 (rider -> a) is ~1.1 km; the full trip through b is much
        // longer. The stat must reflect only the next hop.
        expect(controller.distanceMeters, isNotNull);
        expect(controller.distanceMeters, lessThan(2000));
      },
    );

    test('phaseBounds encompasses every planned stop, not just the first', () {
      final ActiveDeliveryMapController controller = _newController();
      controller.updateRiderPosition(const GeoPoint(1.00, 1.00));

      final DeliveryOrder a = _order(
        orderId: 'a',
        status: AssignmentStatus.inTransit,
        customerLat: 1.01,
        customerLng: 1.00,
      );
      final DeliveryOrder b = _order(
        orderId: 'b',
        status: AssignmentStatus.inTransit,
        customerLat: 1.01,
        customerLng: 1.05,
      );

      controller.applyOrder(a, null, batch: <DeliveryOrder>[a, b]);

      expect(controller.phaseBounds, isNotNull);
      // b's longitude (1.05) is the farthest east point in the plan — the
      // bounds must stretch out to it, not stop at a's 1.00.
      expect(controller.phaseBounds!.northeast.longitude, greaterThanOrEqualTo(1.05));
    });
  });
}
