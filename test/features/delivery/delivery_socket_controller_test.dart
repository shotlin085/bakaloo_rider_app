import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bakaloo_rider_app/core/maps/geo_point.dart';
import 'package:bakaloo_rider_app/core/realtime/socket_client.dart';
import 'package:bakaloo_rider_app/features/delivery/application/active_delivery_controller.dart';
import 'package:bakaloo_rider_app/features/delivery/application/delivery_socket_controller.dart';
import 'package:bakaloo_rider_app/features/delivery/application/offers_controller.dart';
import 'package:bakaloo_rider_app/features/delivery/data/delivery_repository.dart';
import 'package:bakaloo_rider_app/features/delivery/domain/assignment_status.dart';
import 'package:bakaloo_rider_app/features/delivery/domain/delivery_address.dart';
import 'package:bakaloo_rider_app/features/delivery/domain/delivery_item.dart';
import 'package:bakaloo_rider_app/features/delivery/domain/delivery_order.dart';

import '../../helpers/fake_delivery_api.dart';
import '../../helpers/fake_socket_client.dart';

DeliveryOrder _order(
  String id, {
  required double customerLat,
  required double customerLng,
  DateTime? createdAt,
}) =>
    DeliveryOrder(
      orderId: id,
      orderNumber: id,
      assignmentStatus: AssignmentStatus.inTransit,
      totalAmount: 100,
      paymentMethod: 'COD',
      riderEarning: 30,
      estimatedDuration: 10,
      customerAddress: DeliveryAddress(
        name: 'Customer',
        address: 'Addr',
        lat: customerLat,
        lng: customerLng,
      ),
      storeAddress: DeliveryAddress(name: 'Store', address: 'Store addr'),
      items: const <DeliveryItem>[],
      createdAt: createdAt,
    );

void main() {
  group(
    'DeliverySocketController reconcile-on-resume initial focus '
    '(item 8/9: fresh batch loads should focus the closest stop)',
    () {
      test(
        'a fresh reconcile focuses the physically closest order, not '
        'whichever the API listed first',
        () async {
          final FakeDeliveryApi api = FakeDeliveryApi();
          // API lists the FAR order first — a naive "first wins" focus
          // would pick this one.
          final DeliveryOrder far = _order('far', customerLat: 23.50, customerLng: 89.30);
          final DeliveryOrder near = _order('near', customerLat: 22.51, customerLng: 88.31);
          api.assignOrders(<DeliveryOrder>[far, near]);

          final DeliveryRepository repository = DeliveryRepository(api);
          final FakeSocketClient socket = FakeSocketClient();
          final ActiveDeliveryController activeDelivery = ActiveDeliveryController(
            repository: repository,
            socket: socket,
          );
          final OffersController offers =
              OffersController(repository: repository, socket: socket);
          final ValueNotifier<GeoPoint?> riderLocation =
              ValueNotifier<GeoPoint?>(const GeoPoint(22.50, 88.30));

          final DeliverySocketController controller = DeliverySocketController(
            socket: socket,
            offers: offers,
            activeDelivery: activeDelivery,
            repository: repository,
            riderLocation: riderLocation,
          );

          controller.start();
          // Reconcile is fire-and-forget from start(); let its Future settle.
          await pumpEventQueue();

          expect(activeDelivery.batch, hasLength(2));
          expect(
            activeDelivery.current?.orderId,
            'near',
            reason: 'the closest order must be focused, regardless of API order',
          );

          await controller.dispose();
        },
      );

      test(
        'a resume reconcile never overrides an already-focused order',
        () async {
          final FakeDeliveryApi api = FakeDeliveryApi();
          final DeliveryOrder alreadyFocused =
              _order('already-focused', customerLat: 23.50, customerLng: 89.30);
          final DeliveryOrder closerButNew =
              _order('closer-but-new', customerLat: 22.51, customerLng: 88.31);

          final DeliveryRepository repository = DeliveryRepository(api);
          final FakeSocketClient socket = FakeSocketClient();
          final ActiveDeliveryController activeDelivery = ActiveDeliveryController(
            repository: repository,
            socket: socket,
          );
          // Rider is already actively focused on the far order (e.g. they
          // tapped a stop chip, or it was the only order at pickup time).
          activeDelivery.setActiveDelivery(alreadyFocused);

          final OffersController offers =
              OffersController(repository: repository, socket: socket);
          final ValueNotifier<GeoPoint?> riderLocation =
              ValueNotifier<GeoPoint?>(const GeoPoint(22.50, 88.30));

          final DeliverySocketController controller = DeliverySocketController(
            socket: socket,
            offers: offers,
            activeDelivery: activeDelivery,
            repository: repository,
            riderLocation: riderLocation,
          );

          // A new order appears in the API response mid-shift.
          api.assignOrders(<DeliveryOrder>[alreadyFocused, closerButNew]);

          controller.start();
          await pumpEventQueue();

          expect(activeDelivery.batch, hasLength(2));
          expect(
            activeDelivery.current?.orderId,
            'already-focused',
            reason:
                'reconcile must never yank focus away from an order the rider '
                'is already actively navigating to, even if a newer one is '
                'physically closer',
          );

          await controller.dispose();
        },
      );
    },
  );

  group(
    'DeliverySocketController reconcile prunes stale entries '
    '(regression: admin-cancelled order stuck until force-close)',
    () {
      test(
        'an order missing from a fresh /delivery/orders fetch is removed '
        'from the active-delivery batch, leaving the rest untouched',
        () async {
          final FakeDeliveryApi api = FakeDeliveryApi();
          final DeliveryOrder cancelled =
              _order('cancelled-by-admin', customerLat: 23.50, customerLng: 89.30);
          final DeliveryOrder stillActive =
              _order('still-active', customerLat: 22.51, customerLng: 88.31);
          api.assignOrders(<DeliveryOrder>[cancelled, stillActive]);

          final DeliveryRepository repository = DeliveryRepository(api);
          final FakeSocketClient socket = FakeSocketClient();
          final ActiveDeliveryController activeDelivery = ActiveDeliveryController(
            repository: repository,
            socket: socket,
          );
          final OffersController offers =
              OffersController(repository: repository, socket: socket);

          final DeliverySocketController controller = DeliverySocketController(
            socket: socket,
            offers: offers,
            activeDelivery: activeDelivery,
            repository: repository,
          );

          controller.start();
          await pumpEventQueue();
          expect(activeDelivery.batch, hasLength(2));

          // Admin cancels 'cancelled-by-admin' from the dashboard while
          // this device's socket connection missed (or never got) the
          // live order:status event — the backend endpoint simply stops
          // listing it once it's terminal.
          api.assignOrders(<DeliveryOrder>[stillActive]);

          await controller.refreshOrders();

          expect(
            activeDelivery.byId('cancelled-by-admin'),
            isNull,
            reason: 'a manual refresh must prune orders no longer open on the server',
          );
          expect(activeDelivery.byId('still-active'), isNotNull);
          expect(activeDelivery.batch, hasLength(1));

          await controller.dispose();
        },
      );

      test(
        'a stale offer no longer present on refresh is removed from the offers list',
        () async {
          final FakeDeliveryApi api = FakeDeliveryApi();
          final DeliveryRepository repository = DeliveryRepository(api);
          final FakeSocketClient socket = FakeSocketClient();
          final ActiveDeliveryController activeDelivery = ActiveDeliveryController(
            repository: repository,
            socket: socket,
          );
          final OffersController offers =
              OffersController(repository: repository, socket: socket);

          final DeliverySocketController controller = DeliverySocketController(
            socket: socket,
            offers: offers,
            activeDelivery: activeDelivery,
            repository: repository,
          );

          controller.start();
          await pumpEventQueue();

          // An offer arrives live via socket (not yet accepted, so it
          // lands in OffersController, not the active-delivery batch).
          final DeliveryOrder offer =
              _order('offer-1', customerLat: 22.51, customerLng: 88.31)
                  .copyWith(assignmentStatus: AssignmentStatus.assigned);
          offers.upsertOffer(offer);
          expect(offers.offers, hasLength(1));

          // The offer expires/gets reassigned elsewhere before the rider
          // accepts it — a fresh fetch no longer lists it at all.
          await controller.refreshOrders();

          expect(
            offers.offers,
            isEmpty,
            reason: 'a stale offer must not linger after a refresh confirms it is gone',
          );

          await controller.dispose();
        },
      );
    },
  );

  group(
    'DeliverySocketController live order:status payload (regression: '
    'the backend field is `status`, never `assignmentStatus` — this '
    'silently no-opped every live admin-triggered update since the '
    'field name was never actually checked against a real payload)',
    () {
      test(
        'a live order:status event with the real backend payload shape '
        '(status, not assignmentStatus) removes the order immediately, '
        'with no refresh involved',
        () async {
          final FakeDeliveryApi api = FakeDeliveryApi();
          final DeliveryOrder inTransitOrder = _order(
            'order-live-1',
            customerLat: 22.51,
            customerLng: 88.31,
          );
          api.assignOrders(<DeliveryOrder>[inTransitOrder]);
          final DeliveryRepository repository = DeliveryRepository(api);
          final FakeSocketClient socket = FakeSocketClient();
          final ActiveDeliveryController activeDelivery = ActiveDeliveryController(
            repository: repository,
            socket: socket,
          );
          final OffersController offers =
              OffersController(repository: repository, socket: socket);

          final DeliverySocketController controller = DeliverySocketController(
            socket: socket,
            offers: offers,
            activeDelivery: activeDelivery,
            repository: repository,
          );

          controller.start();
          await pumpEventQueue();
          expect(activeDelivery.byId('order-live-1'), isNotNull);

          // Exactly the shape emitOrderUpdate/_emitOrderStatus send on the
          // backend: {orderId, orderNumber, status, message, timestamp}.
          // No `assignmentStatus` key at all.
          socket.pushEvent('order:status', <String, dynamic>{
            'orderId': 'order-live-1',
            'orderNumber': 'order-live-1',
            'status': 'DELIVERED',
            'message': 'Order delivered successfully',
          });
          await pumpEventQueue();

          expect(
            activeDelivery.byId('order-live-1'),
            isNull,
            reason: 'a live order:status push must remove the order without '
                'any manual refresh or app reopen',
          );

          await controller.dispose();
        },
      );

      test(
        'an admin cancelling an order the rider only ever ACCEPTED (never '
        'picked up) still removes it live, even though CANCELLED is not a '
        'legal next step from ACCEPTED in the rider-driven walk',
        () async {
          final FakeDeliveryApi api = FakeDeliveryApi();
          final DeliveryOrder accepted = _order(
            'order-live-2',
            customerLat: 22.51,
            customerLng: 88.31,
          ).copyWith(assignmentStatus: AssignmentStatus.accepted);
          api.assignOrders(<DeliveryOrder>[accepted]);
          final DeliveryRepository repository = DeliveryRepository(api);
          final FakeSocketClient socket = FakeSocketClient();
          final ActiveDeliveryController activeDelivery = ActiveDeliveryController(
            repository: repository,
            socket: socket,
          );
          final OffersController offers =
              OffersController(repository: repository, socket: socket);

          final DeliverySocketController controller = DeliverySocketController(
            socket: socket,
            offers: offers,
            activeDelivery: activeDelivery,
            repository: repository,
          );

          controller.start();
          await pumpEventQueue();
          expect(
            activeDelivery.current?.assignmentStatus,
            AssignmentStatus.accepted,
          );

          socket.pushEvent('order:status', <String, dynamic>{
            'orderId': 'order-live-2',
            'status': 'CANCELLED',
          });
          await pumpEventQueue();

          expect(
            activeDelivery.byId('order-live-2'),
            isNull,
            reason: 'a server-reported terminal status must always win, '
                'even from a stage the rider-driven walk would reject',
          );

          await controller.dispose();
        },
      );
    },
  );

  group(
    'DeliverySocketController reconciles on socket reconnect (regression: '
    'a WebSocket drop/reconnect while the app stays in the foreground '
    'never fires AppLifecycleState.resumed, so an order:status event '
    'lost during that gap would otherwise sit stuck until the rider '
    'manually refreshes or force-closes the app)',
    () {
      test(
        'an order that went terminal while the socket was down is pruned '
        'the moment the socket reconnects, with no lifecycle event and no '
        'manual refresh',
        () async {
          final FakeDeliveryApi api = FakeDeliveryApi();
          final DeliveryOrder order = _order(
            'order-reconnect-1',
            customerLat: 22.51,
            customerLng: 88.31,
          );
          api.assignOrders(<DeliveryOrder>[order]);

          final DeliveryRepository repository = DeliveryRepository(api);
          final FakeSocketClient socket =
              FakeSocketClient(status: SocketStatus.connected);
          final ActiveDeliveryController activeDelivery = ActiveDeliveryController(
            repository: repository,
            socket: socket,
          );
          final OffersController offers =
              OffersController(repository: repository, socket: socket);

          final DeliverySocketController controller = DeliverySocketController(
            socket: socket,
            offers: offers,
            activeDelivery: activeDelivery,
            repository: repository,
          );

          controller.start();
          await pumpEventQueue();
          expect(activeDelivery.byId('order-reconnect-1'), isNotNull);

          // The WebSocket transport drops (network blip, ping timeout,
          // battery-optimization throttling) — the app is still in the
          // foreground the whole time.
          socket.fakeStatus = SocketStatus.disconnected;
          await pumpEventQueue();

          // While disconnected, admin marks the order delivered. The
          // live order:status event is gone — nothing is listening — but
          // the server-side source of truth (what a fresh GET returns)
          // has already moved on, exactly like the real backend endpoint
          // that stops listing terminal orders.
          api.assignOrders(<DeliveryOrder>[]);

          // The transport quietly re-establishes on its own.
          socket.fakeStatus = SocketStatus.connected;
          await pumpEventQueue();

          expect(
            activeDelivery.byId('order-reconnect-1'),
            isNull,
            reason: 'reconnecting must trigger the same reconcile as an '
                'app-foreground resume — the rider should never have to '
                'manually refresh to see this',
          );

          await controller.dispose();
        },
      );
    },
  );

  group(
    'DeliverySocketController GPS-race focus correction (regression: cold '
    'start can reconcile before the first GPS fix arrives)',
    () {
      test(
        'without a GPS fix yet, falls back to time-based ordering (the '
        'earlier-placed order, not the physically closer one)',
        () async {
          final FakeDeliveryApi api = FakeDeliveryApi();
          // Exactly the real production scenario that surfaced this bug:
          // the earlier-placed order is physically farther away.
          final DeliveryOrder earlierButFarther = _order(
            'earlier-farther',
            customerLat: 23.50,
            customerLng: 89.30,
            createdAt: DateTime(2026, 8, 15, 7, 49),
          );
          final DeliveryOrder laterButCloser = _order(
            'later-closer',
            customerLat: 22.51,
            customerLng: 88.31,
            createdAt: DateTime(2026, 8, 15, 7, 51),
          );
          api.assignOrders(<DeliveryOrder>[earlierButFarther, laterButCloser]);

          final DeliveryRepository repository = DeliveryRepository(api);
          final FakeSocketClient socket = FakeSocketClient();
          final ActiveDeliveryController activeDelivery = ActiveDeliveryController(
            repository: repository,
            socket: socket,
          );
          final OffersController offers =
              OffersController(repository: repository, socket: socket);
          // No GPS fix yet — matches a rider whose location stream
          // hasn't reported anything within the reconcile's timing window.
          final ValueNotifier<GeoPoint?> riderLocation = ValueNotifier<GeoPoint?>(null);

          final DeliverySocketController controller = DeliverySocketController(
            socket: socket,
            offers: offers,
            activeDelivery: activeDelivery,
            repository: repository,
            riderLocation: riderLocation,
          );

          controller.start();
          await pumpEventQueue();

          expect(activeDelivery.current?.orderId, 'earlier-farther');

          await controller.dispose();
        },
      );

      test(
        'the first GPS fix that arrives afterward corrects focus to the '
        'physically closest order — the bug this session actually hit',
        () async {
          final FakeDeliveryApi api = FakeDeliveryApi();
          final DeliveryOrder earlierButFarther = _order(
            'earlier-farther',
            customerLat: 23.50,
            customerLng: 89.30,
            createdAt: DateTime(2026, 8, 15, 7, 49),
          );
          final DeliveryOrder laterButCloser = _order(
            'later-closer',
            customerLat: 22.51,
            customerLng: 88.31,
            createdAt: DateTime(2026, 8, 15, 7, 51),
          );
          api.assignOrders(<DeliveryOrder>[earlierButFarther, laterButCloser]);

          final DeliveryRepository repository = DeliveryRepository(api);
          final FakeSocketClient socket = FakeSocketClient();
          final ActiveDeliveryController activeDelivery = ActiveDeliveryController(
            repository: repository,
            socket: socket,
          );
          final OffersController offers =
              OffersController(repository: repository, socket: socket);
          final ValueNotifier<GeoPoint?> riderLocation = ValueNotifier<GeoPoint?>(null);

          final DeliverySocketController controller = DeliverySocketController(
            socket: socket,
            offers: offers,
            activeDelivery: activeDelivery,
            repository: repository,
            riderLocation: riderLocation,
          );

          controller.start();
          await pumpEventQueue();
          expect(
            activeDelivery.current?.orderId,
            'earlier-farther',
            reason: 'sanity check: the initial no-GPS guess landed on the wrong one',
          );

          // The rider's first GPS fix arrives moments later.
          riderLocation.value = const GeoPoint(22.50, 88.30);
          await pumpEventQueue();

          expect(
            activeDelivery.current?.orderId,
            'later-closer',
            reason: 'the first real GPS fix must correct the earlier no-GPS guess',
          );

          await controller.dispose();
        },
      );

      test(
        'the correction fires only once and never overrides a focus the '
        'rider has since chosen themselves',
        () async {
          final FakeDeliveryApi api = FakeDeliveryApi();
          final DeliveryOrder earlierButFarther = _order(
            'earlier-farther',
            customerLat: 23.50,
            customerLng: 89.30,
            createdAt: DateTime(2026, 8, 15, 7, 49),
          );
          final DeliveryOrder laterButCloser = _order(
            'later-closer',
            customerLat: 22.51,
            customerLng: 88.31,
            createdAt: DateTime(2026, 8, 15, 7, 51),
          );
          api.assignOrders(<DeliveryOrder>[earlierButFarther, laterButCloser]);

          final DeliveryRepository repository = DeliveryRepository(api);
          final FakeSocketClient socket = FakeSocketClient();
          final ActiveDeliveryController activeDelivery = ActiveDeliveryController(
            repository: repository,
            socket: socket,
          );
          final OffersController offers =
              OffersController(repository: repository, socket: socket);
          final ValueNotifier<GeoPoint?> riderLocation = ValueNotifier<GeoPoint?>(null);

          final DeliverySocketController controller = DeliverySocketController(
            socket: socket,
            offers: offers,
            activeDelivery: activeDelivery,
            repository: repository,
            riderLocation: riderLocation,
          );

          controller.start();
          await pumpEventQueue();

          // First GPS fix corrects focus to 'later-closer'.
          riderLocation.value = const GeoPoint(22.50, 88.30);
          await pumpEventQueue();
          expect(activeDelivery.current?.orderId, 'later-closer');

          // The rider deliberately switches to the other stop themselves.
          activeDelivery.focusOrder('earlier-farther');

          // Further GPS updates must not re-run the correction and yank
          // focus back.
          riderLocation.value = const GeoPoint(22.55, 88.35);
          await pumpEventQueue();

          expect(activeDelivery.current?.orderId, 'earlier-farther');

          await controller.dispose();
        },
      );
    },
  );
}
