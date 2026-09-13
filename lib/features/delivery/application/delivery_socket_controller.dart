import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

import '../../../core/maps/geo_point.dart';
import '../../../core/realtime/socket_client.dart';
import '../../../core/realtime/socket_events.dart';
import '../../../core/utils/app_logger.dart';
import '../data/delivery_repository.dart';
import '../data/order_parser.dart';
import '../domain/assignment_status.dart';
import '../domain/delivery_order.dart';
import 'active_delivery_controller.dart';
import 'offers_controller.dart';
import 'pickup_session_controller.dart';

/// Optional notification sink. The MVP delivery socket pipes
/// `notification` payloads here; the real notifications feature plugs
/// in a concrete implementation later (Task 12.x).
abstract class NotificationSink {
  /// Receives a notification [payload] for display.
  void onNotification(Map<String, dynamic> payload);
}

/// Default no-op [NotificationSink] used until the notifications
/// feature lands.
class NoOpNotificationSink implements NotificationSink {
  /// Constructs a no-op sink.
  const NoOpNotificationSink();

  @override
  void onNotification(Map<String, dynamic> payload) {
    AppLogger.debug(
      LogTopic.socket,
      'NoOpNotificationSink dropping notification payload',
    );
  }
}

/// Bridges Socket.IO delivery events into the offers and
/// active-delivery controllers and reconciles missed offers when the
/// app comes back to the foreground.
///
/// Responsibilities:
/// - On [start]: subscribes to the four listen events
///   (`order:assigned`, `order:expired`, `order:status`, `notification`)
///   via [SocketClient.on] (R8.1, R8.4, R8.5).
/// - Routes `order:assigned` to [OffersController.upsertOffer] using
///   [DeliveryOrder.fromJson] to parse the payload.
/// - Routes `order:expired` to [OffersController.markExpired].
/// - Routes `order:status` to BOTH [OffersController.applyStatus] and
///   [ActiveDeliveryController.applyExternalStatus] so the monotonic
///   transition guard runs in both places (R9.1, R9.2).
/// - Routes `notification` to the supplied [NotificationSink] (no-op
///   for MVP).
/// - Observes [WidgetsBinding] lifecycle and, on
///   [AppLifecycleState.resumed], asks [DeliveryRepository] to fetch
///   `/delivery/orders` to reconcile any offers that arrived while
///   the app was backgrounded (R7.5).
///
/// Lifecycle:
/// 1. `providers.dart` constructs the controller after login.
/// 2. The home screen (or a session listener) calls [start] once the
///    socket is connected.
/// 3. On logout / dispose, [stop] cancels every subscription and
///    detaches the lifecycle observer.
class DeliverySocketController with WidgetsBindingObserver {
  /// Wires the controller to its collaborators.
  DeliverySocketController({
    required SocketClient socket,
    required OffersController offers,
    required ActiveDeliveryController activeDelivery,
    required DeliveryRepository repository,
    PickupSessionController? pickupSession,
    NotificationSink notifications = const NoOpNotificationSink(),
    WidgetsBinding? binding,
    ValueListenable<GeoPoint?>? riderLocation,
  }) : _socket = socket,
       _offers = offers,
       _activeDelivery = activeDelivery,
       _repository = repository,
       _pickupSession = pickupSession,
       _notifications = notifications,
       _binding = binding,
       _riderLocation = riderLocation;

  final SocketClient _socket;
  final OffersController _offers;
  final ActiveDeliveryController _activeDelivery;
  final DeliveryRepository _repository;
  final PickupSessionController? _pickupSession;
  final NotificationSink _notifications;
  final WidgetsBinding? _binding;

  /// Live rider GPS fix, read at reconcile time so a fresh batch load
  /// picks the real nearest-neighbor route's first stop as the initial
  /// focus (item 8/9), not just whichever order the API happened to
  /// list first.
  final ValueListenable<GeoPoint?>? _riderLocation;

  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];

  bool _started = false;
  bool _lifecycleAttached = false;

  /// True when the last "fresh batch" focus pick had to fall back to
  /// time-based ordering because no GPS fix was available yet — cleared
  /// (and corrected) the moment a real position arrives.
  bool _pendingGpsFocusCorrection = false;

  /// Whether [start] has been called and [stop] has not yet been
  /// called. Public so tests can assert lifecycle behaviour.
  bool get isStarted => _started;

  /// Manually re-syncs offers/active-delivery against `/delivery/orders`
  /// — the same reconciliation [didChangeAppLifecycleState] runs on
  /// app-foreground, exposed so the UI can offer an explicit "refresh"
  /// action for when the rider doesn't want to wait for the next
  /// background/foreground cycle (or a live socket event that, for
  /// whatever reason — a dropped connection, a background gap — didn't
  /// arrive).
  Future<void> refreshOrders() => _reconcileOnResume();

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Subscribes to the four delivery socket events and attaches the
  /// app-lifecycle observer.
  ///
  /// Idempotent: a second call is a no-op.
  void start() {
    if (_started) return;
    _started = true;

    AppLogger.debug(
      LogTopic.socket,
      'DeliverySocketController.start: subscribing to socket events',
    );

    _subscriptions.add(
      _socket.on(SocketEvents.orderAssigned).listen(_onOrderAssigned),
    );
    _subscriptions.add(
      _socket.on(SocketEvents.orderExpired).listen(_onOrderExpired),
    );
    _subscriptions.add(
      _socket.on(SocketEvents.orderStatus).listen(_onOrderStatus),
    );
    _subscriptions.add(
      _socket.on(SocketEvents.notification).listen(_onNotification),
    );

    // Reconcile on every reconnect, not just app-foreground (R7.5).
    // Mobile WebSocket connections drop and silently re-establish all
    // the time on their own — battery optimization, a network blip, a
    // ping timeout — with the app staying in the foreground the whole
    // time, so AppLifecycleState.resumed never fires. Any order:status
    // event the backend sent during that gap is gone for good (Socket.IO
    // doesn't replay missed events), so without this, an order can sit
    // stuck until the rider happens to background/foreground the app,
    // pulls to refresh, or force-closes it — exactly the "still shows
    // after live delivery/cancel, only a manual refresh clears it"
    // symptom this was chasing.
    _subscriptions.add(
      _socket.statusStream.listen(_onSocketStatusChanged),
    );

    // Attach lifecycle observer for foreground reconciliation (R7.5).
    final WidgetsBinding? binding = _binding ?? _maybeBinding();
    if (binding != null) {
      binding.addObserver(this);
      _lifecycleAttached = true;
    }

    // A cold-start reconcile can race the GPS stream — the rider's first
    // fix often hasn't arrived yet, so the initial nearest-neighbor focus
    // pick may have to fall back to time-based ordering (see
    // _reconcileOnResume). This listener catches the *first* GPS fix that
    // arrives afterward and, if that fallback was used, corrects the
    // focus exactly once — otherwise a wrong-but-permanent guess would
    // stick around for the rest of the trip since focus is never
    // re-evaluated once set (item 8/9: "perfect calculation").
    _riderLocation?.addListener(_onRiderLocationAvailable);

    unawaited(_reconcileOnResume());
  }

  /// Detaches every subscription and lifecycle hook.
  ///
  /// Idempotent: safe to call multiple times.
  Future<void> stop() async {
    if (!_started) return;
    _started = false;

    AppLogger.debug(
      LogTopic.socket,
      'DeliverySocketController.stop: cancelling subscriptions',
    );

    for (final StreamSubscription<dynamic> s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    _riderLocation?.removeListener(_onRiderLocationAvailable);

    if (_lifecycleAttached) {
      final WidgetsBinding? binding = _binding ?? _maybeBinding();
      binding?.removeObserver(this);
      _lifecycleAttached = false;
    }
  }

  /// Releases owned resources. Stops first so cancellation is
  /// guaranteed before disposal.
  Future<void> dispose() async {
    await stop();
  }

  // ---------------------------------------------------------------------------
  // App lifecycle
  // ---------------------------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      AppLogger.info(
        LogTopic.socket,
        'App resumed: reconciling /delivery/orders',
      );
      // Fire-and-forget reconciliation. Errors are swallowed because
      // missing offers are non-fatal (the next assignment event will
      // refresh the list).
      unawaited(_reconcileOnResume());
    }
  }

  /// Reconciles on every transition into [SocketStatus.connected] —
  /// covers reconnects that happen with the app already in the
  /// foreground, which [didChangeAppLifecycleState] never sees. See the
  /// [start] call site for why this matters.
  void _onSocketStatusChanged(SocketStatus status) {
    if (status != SocketStatus.connected) return;
    AppLogger.info(
      LogTopic.socket,
      'Socket (re)connected: reconciling /delivery/orders',
    );
    unawaited(_reconcileOnResume());
  }

  Future<void> _reconcileOnResume() async {
    try {
      // Captured before the loop below claims focus for whichever order
      // happens to be array-first in the API response — lets us tell
      // "this reconcile is populating a previously-empty batch from
      // scratch" apart from "the rider was already actively focused on
      // something and this is just a routine resume refresh."
      final bool wasEmptyBeforeThisReconcile = _activeDelivery.current == null;

      final List<DeliveryOrder> orders = await _repository.getOrders();
      final Set<String> freshIds =
          orders.map((DeliveryOrder o) => o.orderId).toSet();
      for (final DeliveryOrder order in orders) {
        switch (order.assignmentStatus) {
          case AssignmentStatus.assigned:
            // Only reachable via the legacy offer-fan-out path (still
            // dormant-but-present on the backend) — the firm-assignment
            // resolver creates rows already ACCEPTED, so a rider on the
            // new flow never observes `assigned` here.
            _offers.upsertOffer(order);
          case AssignmentStatus.accepted:
          case AssignmentStatus.inTransit:
            _activeDelivery.setActiveDelivery(order);
          case AssignmentStatus.delivered:
          case AssignmentStatus.cancelled:
            // Terminal; nothing to surface in UI state.
            break;
        }
      }

      // /delivery/orders only ever lists orders still open for this
      // rider — a cancelled/delivered order simply stops appearing in
      // it. The loop above only ever adds/updates, so anything the
      // rider was tracking locally that's now missing from a fresh
      // fetch must have gone terminal server-side (e.g. an admin
      // dashboard cancellation) without the live `order:status` socket
      // event reaching this device — a background/foreground gap, or
      // a dropped connection the socket client hadn't yet reconnected
      // from. Prune it here instead of leaving it stuck until the
      // rider force-closes and reopens the app.
      for (final DeliveryOrder offer in _offers.offers.toList()) {
        if (!freshIds.contains(offer.orderId)) {
          _offers.removeOffer(offer.orderId);
        }
      }
      for (final DeliveryOrder order in _activeDelivery.batch.toList()) {
        if (!freshIds.contains(order.orderId)) {
          _activeDelivery.remove(order.orderId);
        }
      }

      // A fresh batch load (not a resume-with-existing-focus refresh)
      // should focus the real nearest-neighbor route's first stop (item
      // 8/9) — not just whichever order the API happened to list first.
      // `setActiveDelivery` above already auto-claimed *some* order as
      // focused the moment the batch went from empty to non-empty, so
      // this explicitly re-focuses to the correct one when that
      // happened.
      if (wasEmptyBeforeThisReconcile) {
        _refocusToNearestStop();
        // No GPS fix yet means the pick above just fell back to
        // time-based ordering — flag it so the very next GPS fix
        // corrects it (see _onRiderLocationAvailable). A pick made
        // *with* a real position needs no correction.
        _pendingGpsFocusCorrection = _riderLocation?.value == null;
      }

      _pickupSession?.syncFromBatch(_activeDelivery.batch);
    } catch (e, stack) {
      AppLogger.warn(
        LogTopic.socket,
        'Order reconciliation on resume failed',
        error: e,
        stackTrace: stack,
      );
    }
  }

  /// Focuses the first stop of the real nearest-neighbor route among
  /// the batch's in-transit orders (item 8/9). Shared by the initial
  /// "fresh batch" pick in [_reconcileOnResume] and the one-time GPS
  /// correction in [_onRiderLocationAvailable].
  void _refocusToNearestStop() {
    final List<DeliveryOrder> readyToDeliver = _activeDelivery.batch
        .where((DeliveryOrder o) => o.assignmentStatus == AssignmentStatus.inTransit)
        .toList();
    final List<DeliveryOrder> sequenced =
        DeliveryOrder.sequenceRoute(readyToDeliver, _riderLocation?.value);
    if (sequenced.isNotEmpty) {
      _activeDelivery.focusOrder(sequenced.first.orderId);
    }
  }

  /// Fires on every rider GPS update. Only acts once: if the last
  /// "fresh batch" focus pick had to guess without a position (see
  /// [_reconcileOnResume]), the first real fix that arrives corrects it
  /// — then never fires again, so it can't disturb a focus the rider
  /// has since driven towards themselves.
  void _onRiderLocationAvailable() {
    if (!_pendingGpsFocusCorrection) return;
    if (_riderLocation?.value == null) return;
    _pendingGpsFocusCorrection = false;
    _refocusToNearestStop();
  }

  // ---------------------------------------------------------------------------
  // Event handlers
  // ---------------------------------------------------------------------------

  void _onOrderAssigned(Map<String, dynamic> payload) {
    AppLogger.info(LogTopic.socket, 'order:assigned received');
    // The firm-assignment resolver sends a deliberately minimal
    // {orderId, status} payload — not a full order — so this event is a
    // "go refetch your orders" signal, not something to parse a
    // DeliveryOrder out of directly. (The legacy offer-fan-out path, if
    // ever triggered via the dormant reject-requeue flow, sends a richer
    // payload, but reconciling via a fetch handles that shape too — the
    // full order comes back from GET /delivery/orders either way.)
    unawaited(_reconcileOnResume());
  }

  void _onOrderExpired(Map<String, dynamic> payload) {
    AppLogger.info(LogTopic.socket, 'order:expired received');
    final String? orderId = _extractOrderId(payload);
    if (orderId == null) {
      AppLogger.warn(
        LogTopic.socket,
        'order:expired: could not extract orderId from $payload',
      );
      return;
    }
    _offers.markExpired(orderId);
  }

  void _onOrderStatus(Map<String, dynamic> payload) {
    AppLogger.info(LogTopic.socket, 'order:status received');
    final String? orderId = _extractOrderId(payload);
    if (orderId == null) {
      AppLogger.warn(
        LogTopic.socket,
        'order:status: missing orderId in $payload',
      );
      return;
    }
    // The backend's order:status payload (see socketio.plugin.js's
    // emitOrderUpdate and every _emitOrderUpdate/_emitOrderStatus call
    // site across delivery.service.js and admin/orders/orders.service.js)
    // always carries the field as `status` — never `assignmentStatus` /
    // `assignment_status`. Those were the wrong keys from the start, so
    // every live status push (admin dashboard cancel/deliver included)
    // silently no-opped here; only a rider's own in-app actions ever
    // updated anything, because those apply the transition locally
    // instead of round-tripping through this parser. `assignmentStatus`
    // is kept as a fallback in case a future payload shape uses it.
    final String? rawStatus = OrderParser.readStringOpt(payload, 'status') ??
        OrderParser.readStringOpt(
          payload,
          'assignmentStatus',
          'assignment_status',
        );
    if (rawStatus == null || rawStatus.isEmpty) {
      AppLogger.warn(
        LogTopic.socket,
        'order:status: missing assignmentStatus in $payload',
      );
      return;
    }
    final AssignmentStatus status;
    try {
      status = AssignmentStatus.parse(rawStatus);
    } catch (e, stack) {
      AppLogger.warn(
        LogTopic.parse,
        'order:status: unknown status $rawStatus',
        error: e,
        stackTrace: stack,
      );
      return;
    }
    _offers.applyStatus(orderId, status);
    _activeDelivery.applyExternalStatus(orderId, status);
    if (status == AssignmentStatus.delivered || status == AssignmentStatus.cancelled) {
      _pickupSession?.remove(orderId);
    }
  }

  void _onNotification(Map<String, dynamic> payload) {
    AppLogger.info(LogTopic.socket, 'notification received');
    _notifications.onNotification(payload);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String? _extractOrderId(Map<String, dynamic> payload) {
    final dynamic raw =
        payload['orderId'] ?? payload['order_id'] ?? payload['id'];
    if (raw == null) return null;
    final String s = raw.toString();
    return s.isEmpty ? null : s;
  }

  WidgetsBinding? _maybeBinding() {
    try {
      return WidgetsBinding.instance;
    } catch (_) {
      // No binding available (pure Dart unit test environment).
      return null;
    }
  }
}
