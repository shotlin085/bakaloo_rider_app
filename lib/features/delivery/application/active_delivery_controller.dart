import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/maps/geo_point.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/realtime/socket_client.dart';
import '../../../core/realtime/socket_events.dart';
import '../../../core/utils/app_logger.dart';
import '../data/delivery_repository.dart';
import '../domain/assignment_status.dart';
import '../domain/collected_payment.dart';
import '../domain/delivery_order.dart';
import 'assignment_state_machine.dart';

/// Discriminated outcome of the delivery-lifecycle actions on
/// [ActiveDeliveryController]: [ActiveDeliveryController.markPickedUp],
/// [ActiveDeliveryController.deliverDirect],
/// [ActiveDeliveryController.deliverWithProof], and
/// [ActiveDeliveryController.deliverWithDemoMode].
///
/// The presentation layer pattern-matches on the result so each
/// outcome (success, stale order, proof upload failure, generic
/// failure) maps to its own UX path
/// (R13.5, R14.5, R14.6, R15.4, R16.4).
@immutable
sealed class DeliveryResult {
  /// Const constructor.
  const DeliveryResult();
}

/// Successful outcome. Carries enough information to render the
/// completion summary sheet without re-fetching.
@immutable
class DeliveryResultSuccess extends DeliveryResult {
  /// Const constructor.
  const DeliveryResultSuccess({
    required this.orderEarning,
    required this.customerName,
    required this.orderNumber,
  });

  /// Earning credited to the rider for this delivery.
  final double orderEarning;

  /// Customer's name (or the address if name is empty).
  final String customerName;

  /// Human-readable order number rendered on the summary.
  final String orderNumber;
}

/// The order is no longer in a state that accepts the requested
/// transition (backend returned `ORDER_NOT_AVAILABLE` / 409). The
/// caller should refetch `/delivery/orders` (R13.5).
@immutable
class DeliveryResultStale extends DeliveryResult {
  /// Const constructor.
  const DeliveryResultStale({
    this.message = 'Order is no longer in the right state. Refreshing',
  });

  /// User-facing copy.
  final String message;
}

/// Customer's OTP did not match. Keep the OTP sheet open and let the
/// rider retype (R14.5).
@immutable
class DeliveryResultInvalidOtp extends DeliveryResult {
  /// Const constructor.
  const DeliveryResultInvalidOtp({
    this.message = 'OTP did not match. Ask the customer to read it again',
  });

  /// User-facing copy.
  final String message;
}

/// OTP expired (Redis TTL elapsed). Switch to the proof flow (R14.6).
@immutable
class DeliveryResultOtpExpired extends DeliveryResult {
  /// Const constructor.
  const DeliveryResultOtpExpired({
    this.message = 'OTP expired. Use proof photo',
  });

  /// User-facing copy.
  final String message;
}

/// Proof photo upload failed (network / server error). Keep the proof
/// sheet open with a retry CTA (R15.4).
@immutable
class DeliveryResultProofFailed extends DeliveryResult {
  /// Const constructor.
  const DeliveryResultProofFailed({
    this.message = 'Could not upload photo. Try again',
  });

  /// User-facing copy.
  final String message;
}

/// Generic failure. Surface the supplied [message] verbatim (it's
/// either the backend `message` field or a translated transport error).
@immutable
class DeliveryResultFailure extends DeliveryResult {
  /// Const constructor.
  const DeliveryResultFailure(this.message);

  /// User-facing copy.
  final String message;
}

/// Holds the rider's active-order **batch** (status `ACCEPTED` or
/// `IN_TRANSIT`, one or more orders picked up in the same store visit) and
/// owns the mid-delivery actions (pickup, direct deliver, proof deliver,
/// demo deliver), each scoped to a specific `orderId`.
///
/// One order in the batch is "focused" at a time — [current] — which is
/// what the existing single-order screens (`active_delivery_map_screen.dart`
/// and its sheets) render, unchanged. This keeps every pre-existing
/// per-order-delivery consumer working exactly as before; only the
/// pickup-phase screens (new in this phase) read [batch] directly.
///
/// Transitions go through [AssignmentStateMachine] to enforce the
/// monotonicity property (R9.1, R9.2). When an order reaches a terminal
/// status it stays in the batch (not auto-removed) so the presentation
/// layer can still read it to render the completion summary; the summary
/// sheet calls [clearActiveDelivery] when the rider acknowledges it, which
/// removes just that order and auto-advances focus to the next
/// not-yet-delivered order in the batch, if any (R9, item 9's "guide the
/// rider to the next stop" — Phase C picks the next batch entry
/// arbitrarily; Phase D's route sequencing decides the real order).
///
/// The same auto-clear behaviour is preserved for externally-driven
/// state changes through [applyExternalStatus] (e.g. socket
/// `order:status` events) so the home screen can react to a remote
/// cancellation without manual cleanup.
///
/// This is a plain [ChangeNotifier] (no Riverpod) so it can be
/// unit-tested in pure Dart without a Flutter widget tree. A typed
/// [DeliveryRepository] and [SocketClient] are accepted optionally so
/// constructors can stay light in tests that only exercise the local
/// list operations; production code wires both via Riverpod.
class ActiveDeliveryController extends ChangeNotifier {
  /// Wires the controller to its [repository] and [socket] dependencies.
  ///
  /// Both are nullable for test ergonomics — tests that only drive
  /// [setActiveDelivery] / [applyExternalStatus] can pass `null` for
  /// either. Network methods ([markPickedUp], [deliverDirect],
  /// [deliverWithProof], [deliverWithDemoMode]) require a non-null
  /// repository; calling them without one returns a
  /// [DeliveryResultFailure].
  ActiveDeliveryController({
    DeliveryRepository? repository,
    SocketClient? socket,
    ValueListenable<GeoPoint?>? riderLocation,
  })  : _repository = repository,
        _socket = socket,
        _riderLocation = riderLocation;

  final DeliveryRepository? _repository;
  final SocketClient? _socket;

  /// Live rider GPS fix, read (not listened to) at auto-advance time so
  /// [_focusNextIfNeeded] can rank the remaining batch by real distance
  /// (item 8/9: "deliver whichever stop is closest next"). Optional —
  /// falls back to time-based ordering when unset (e.g. in tests, or
  /// before the first GPS fix arrives).
  final ValueListenable<GeoPoint?>? _riderLocation;

  final Map<String, DeliveryOrder> _orders = <String, DeliveryOrder>{};
  final Set<String> _busyIds = <String>{};
  String? _focusedOrderId;

  /// Orders the rider explicitly skipped — deprioritized for auto-advance
  /// (see [_focusNextIfNeeded]) but still in the batch, so they're
  /// revisited once every other ready order has been handled.
  final Set<String> _skippedOrderIds = <String>{};

  /// COD cash/UPI split the rider recorded via the "Collect payment" step,
  /// keyed by orderId. Populated by [recordCollectedPayment]; the "Deliver"
  /// action reads from here rather than taking the split as a parameter, so
  /// it survives the (stateless) delivery sheet being rebuilt between the
  /// rider tapping "Collect payment" and later tapping "Deliver".
  final Map<String, CollectedPayment> _collectedPayments =
      <String, CollectedPayment>{};

  /// The payment split recorded for [orderId], or `null` if the rider
  /// hasn't gone through the collection step yet (or the order isn't COD).
  CollectedPayment? collectedPaymentFor(String orderId) =>
      _collectedPayments[orderId];

  /// Records [payment] as the confirmed cash/UPI split for [orderId] and
  /// notifies listeners so the "Deliver" button un-disables.
  void recordCollectedPayment(String orderId, CollectedPayment payment) {
    _collectedPayments[orderId] = payment;
    notifyListeners();
  }

  /// Every order currently in the rider's active batch (pickup-confirmed,
  /// out for delivery), in no particular order — pickup-batch/route
  /// screens read this directly.
  List<DeliveryOrder> get batch =>
      List<DeliveryOrder>.unmodifiable(_orders.values);

  /// Looks up one batch order by id, or `null` if it isn't in the batch.
  DeliveryOrder? byId(String orderId) => _orders[orderId];

  /// The order the existing single-order delivery screens
  /// (`active_delivery_map_screen.dart` and its sheets) render — the
  /// "focused" batch entry. `null` when nothing is currently focused
  /// (batch empty, or all remaining orders still need pickup).
  ///
  /// Kept as the same getter name/shape the pre-batch codebase used so
  /// every existing single-order consumer keeps working unchanged.
  DeliveryOrder? get current =>
      _focusedOrderId == null ? null : _orders[_focusedOrderId];

  /// Whether a network action is in flight **for the currently focused
  /// order**. Sheets read this flag to disable their primary buttons —
  /// same call shape as before, but now backed by a per-order busy set so
  /// an action on one batch order never blocks another.
  bool get isBusy =>
      _focusedOrderId != null && _busyIds.contains(_focusedOrderId);

  /// Whether a network action is in flight for [orderId] specifically.
  /// Used by batch-aware screens that can have more than one order
  /// visible at once.
  bool isBusyFor(String orderId) => _busyIds.contains(orderId);

  /// Adds or updates [order] in the batch. If nothing is currently
  /// focused, this order becomes the focused one — preserves the
  /// pre-batch behaviour of "the order I was just told about is the one
  /// the single-order screens should show" for the common single-order
  /// case, while additional orders simply join the batch without
  /// stealing focus from whichever delivery is already in progress.
  void setActiveDelivery(DeliveryOrder order) {
    _orders[order.orderId] = order;
    _focusedOrderId ??= order.orderId;
    notifyListeners();
  }

  /// Alias for [setActiveDelivery] with a batch-first name — same
  /// behaviour, used by new pickup-phase code so call sites read clearly
  /// as "this order just joined the batch" rather than the legacy
  /// single-order phrasing.
  void addOrUpdate(DeliveryOrder order) => setActiveDelivery(order);

  /// Removes [orderId] from the batch entirely (used when an order is
  /// cancelled/removed rather than delivered). Un-focuses and
  /// auto-advances if it was the focused order.
  void remove(String orderId) {
    _orders.remove(orderId);
    _busyIds.remove(orderId);
    _collectedPayments.remove(orderId);
    _skippedOrderIds.remove(orderId);
    if (_focusedOrderId == orderId) {
      _focusedOrderId = null;
      _focusNextIfNeeded();
    }
    notifyListeners();
  }

  /// Clears the focused delivery: removes it from the batch and
  /// auto-advances focus to the next remaining batch order, if any.
  ///
  /// Kept as the same method name the completion-summary sheet already
  /// calls — its meaning changes from "there is no more active delivery"
  /// (single-order world) to "this one delivery is done, move to the
  /// next one in the batch" (batch world), which is exactly item 9's
  /// "mark only that order as delivered, keep the other batch orders
  /// active, automatically guide the rider to the next stop."
  void clearActiveDelivery() {
    final String? id = _focusedOrderId;
    if (id != null) {
      _orders.remove(id);
      _busyIds.remove(id);
      _collectedPayments.remove(id);
      _skippedOrderIds.remove(id);
    }
    _focusedOrderId = null;
    _focusNextIfNeeded();
    notifyListeners();
  }

  /// Explicitly focuses [orderId] (used by the pickup-batch screen's
  /// "Start Deliveries" action, and by a batch overview letting the
  /// rider pick which stop to view). No-ops if [orderId] isn't in the
  /// batch. Un-skips it — the rider picking it directly overrides
  /// whatever auto-advance would otherwise have preferred.
  void focusOrder(String orderId) {
    if (!_orders.containsKey(orderId)) return;
    _focusedOrderId = orderId;
    _skippedOrderIds.remove(orderId);
    notifyListeners();
  }

  /// Skips [orderId]: moves focus to the next ready order in the batch
  /// without changing [orderId]'s status — it stays in the batch and is
  /// revisited automatically once every other ready order has been
  /// delivered/skipped-through. No-ops if [orderId] isn't the focused
  /// order or isn't in the batch (nothing to skip to otherwise).
  void skip(String orderId) {
    if (_focusedOrderId != orderId || !_orders.containsKey(orderId)) return;
    _skippedOrderIds.add(orderId);
    _focusedOrderId = null;
    _focusNextIfNeeded();
    notifyListeners();
  }

  /// Auto-advance target when nothing is currently focused (item 9: "guide
  /// the rider to the next stop"). Prefers the first stop of the real
  /// nearest-neighbor route among orders that are actually ready to
  /// deliver (picked up, [AssignmentStatus.inTransit]) — Express first,
  /// then whichever is physically closest to the rider's live GPS
  /// position (see [DeliveryOrder.sequenceRoute], item 8/9: "closest
  /// distance first, then next from there"). Falls back to any
  /// remaining batch order if none are in-transit yet, so this never
  /// leaves the controller in a "batch non-empty but nothing focused"
  /// state.
  void _focusNextIfNeeded() {
    if (_focusedOrderId != null || _orders.isEmpty) return;
    final List<DeliveryOrder> readyToDeliver = _orders.values
        .where((DeliveryOrder o) => o.assignmentStatus == AssignmentStatus.inTransit)
        .toList();
    // Prefer orders the rider hasn't skipped yet; only fall back to a
    // skipped one once it's the only ready order left, so a skip reliably
    // moves on to something else instead of re-focusing immediately.
    final List<DeliveryOrder> notSkipped = readyToDeliver
        .where((DeliveryOrder o) => !_skippedOrderIds.contains(o.orderId))
        .toList();
    final List<DeliveryOrder> pool =
        notSkipped.isNotEmpty ? notSkipped : readyToDeliver;
    final List<DeliveryOrder> sequenced =
        DeliveryOrder.sequenceRoute(pool, _riderLocation?.value);
    _focusedOrderId =
        sequenced.isNotEmpty ? sequenced.first.orderId : _orders.keys.first;
    if (_focusedOrderId != null) {
      _skippedOrderIds.remove(_focusedOrderId);
    }
  }

  /// Applies an externally received [next] status to the batch order
  /// identified by [orderId].
  ///
  /// If [orderId] isn't in the batch the call is a no-op (the event is
  /// for an order this controller isn't tracking).
  ///
  /// Non-terminal transitions are validated by [AssignmentStateMachine.apply];
  /// illegal ones are rejected and logged without mutating state — that
  /// guard exists for the rider's own step-by-step actions (R9). A
  /// *terminal* [next] (DELIVERED/CANCELLED) is always applied instead,
  /// bypassing the walk check: an admin can mark an order delivered or
  /// cancel it from the dashboard without the rider's local state ever
  /// having stepped through the intermediate stages (e.g. cancelling an
  /// order the rider hasn't picked up yet), and the server's word on a
  /// terminal outcome is authoritative regardless of what this device
  /// thinks the order's current stage is. When the resulting status is
  /// terminal, [_onTerminalExternal] is called to remove just that order
  /// from the batch.
  void applyExternalStatus(String orderId, AssignmentStatus next) {
    final DeliveryOrder? order = _orders[orderId];
    if (order == null) return;

    final AssignmentStatus resolved = AssignmentStateMachine.isTerminal(next)
        ? next
        : AssignmentStateMachine.apply(
            order.assignmentStatus,
            next,
            orderId: orderId,
          );

    if (resolved == order.assignmentStatus) {
      // Either idempotent (same status) or illegal (rejected). Either way
      // the state did not change, so no notification is needed.
      return;
    }

    _orders[orderId] = order.copyWith(assignmentStatus: resolved);
    notifyListeners();

    if (AssignmentStateMachine.isTerminal(resolved)) {
      _onTerminalExternal(orderId);
    }
  }

  // ---------------------------------------------------------------------------
  // Pickup (R13)
  // ---------------------------------------------------------------------------

  /// Marks [orderId] as picked up at the store.
  ///
  /// On success: drives the assignment through
  /// `ACCEPTED -> IN_TRANSIT` via [AssignmentStateMachine.apply] so the
  /// monotonic-walk invariant (R9) holds. Does NOT emit `order:track`
  /// — that emit happens on accept (R10.3). Callers should switch the
  /// `LocationProfile` to in-transit after this returns success
  /// (R13.4); this controller does not own the location profile.
  ///
  /// On `ORDER_NOT_AVAILABLE`: surfaces [DeliveryResultStale] so the
  /// caller can refetch `/delivery/orders` (R13.5).
  Future<DeliveryResult> markPickedUp(String orderId) async {
    return _runAction('markPickedUp', orderId, () async {
      final DeliveryRepository repository = _requireRepository();
      await repository.markPickedUp(orderId);
      _applyLocalTransition(orderId, AssignmentStatus.inTransit);
      final DeliveryOrder? o = _orders[orderId];
      if (o == null) {
        return _genericSuccess(orderId);
      }
      return DeliveryResultSuccess(
        orderEarning: o.riderEarning,
        customerName: o.customerAddress.name.isNotEmpty
            ? o.customerAddress.name
            : o.customerAddress.address,
        orderNumber: o.orderNumber,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Cancel delivery (customer refused / unreachable)
  // ---------------------------------------------------------------------------

  /// Cancels [orderId] when the customer refuses the order at the
  /// door or can't be reached at the drop location.
  ///
  /// Applies the terminal transition `ACCEPTED/IN_TRANSIT ->
  /// CANCELLED`, emits `order:untrack`, and removes it from the batch
  /// (auto-advancing focus if it was the focused order) so the rider can
  /// immediately continue with the rest of the batch or go back online.
  /// Returns `true` on success.
  Future<bool> cancelDelivery(String orderId, String reason) async {
    final DeliveryRepository? repository = _repository;
    if (repository == null || _busyIds.contains(orderId)) return false;
    _busyIds.add(orderId);
    notifyListeners();
    try {
      await repository.cancelDelivery(orderId, reason);
      _socket?.emit(SocketEvents.orderUntrack, <String, dynamic>{
        'orderId': orderId,
      });
      _onTerminalExternal(orderId);
      return true;
    } catch (e, stack) {
      AppLogger.warn(
        LogTopic.state,
        'cancelDelivery($orderId) failed',
        error: e,
        stackTrace: stack,
      );
      return false;
    } finally {
      _busyIds.remove(orderId);
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Deliver directly (no OTP / proof step)
  // ---------------------------------------------------------------------------

  /// Marks [orderId] as delivered immediately — no OTP or proof-photo
  /// verification. COD collection (if any) has already happened via
  /// [recordCollectedPayment] before this is called.
  Future<DeliveryResult> deliverDirect(
    String orderId, {
    double? cashCollected,
    double? upiCollected,
  }) async {
    return _runAction(
      'deliverDirect',
      orderId,
      () async {
        final DeliveryRepository repository = _requireRepository();
        await repository.markDelivered(
          orderId,
          cashCollected: cashCollected,
          upiCollected: upiCollected,
        );
        return _completeDelivery(orderId);
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Deliver via proof photo (R15)
  // ---------------------------------------------------------------------------

  /// Uploads [file] as proof and marks [orderId] as delivered.
  ///
  /// Two-step flow per R15.3:
  /// 1. `POST /delivery/orders/:id/proof` returns the public URL.
  /// 2. `PATCH /delivery/orders/:id/deliver` with `proofPhotoUrl: url`.
  ///
  /// Surfaces [DeliveryResultProofFailed] when step 1 fails so the
  /// proof sheet can keep the preview and offer a retry (R15.4).
  /// Step-2 errors are surfaced via the standard mapping (stale /
  /// generic).
  Future<DeliveryResult> deliverWithProof(
    String orderId,
    File file, {
    double? cashCollected,
    double? upiCollected,
  }) async {
    final DeliveryRepository? repository = _repository;
    if (repository == null) {
      return const DeliveryResultFailure('Network unavailable');
    }
    if (_busyIds.contains(orderId)) {
      return const DeliveryResultFailure('Action already in progress');
    }
    _busyIds.add(orderId);
    notifyListeners();

    try {
      final String url;
      try {
        url = await repository.uploadProof(orderId, file);
      } catch (e, stack) {
        AppLogger.warn(
          LogTopic.state,
          'deliverWithProof.upload($orderId) failed',
          error: e,
          stackTrace: stack,
        );
        return const DeliveryResultProofFailed();
      }

      if (url.isEmpty) {
        return const DeliveryResultProofFailed();
      }

      try {
        await repository.markDelivered(
          orderId,
          proofPhotoUrl: url,
          cashCollected: cashCollected,
          upiCollected: upiCollected,
        );
        return _completeDelivery(orderId);
      } on OrderNotAvailableException catch (e) {
        AppLogger.info(
          LogTopic.state,
          'deliverWithProof($orderId): order not available — ${e.message}',
        );
        return DeliveryResultStale(message: e.message);
      } on ApiException catch (e) {
        return _mapDeliverError(e) ?? DeliveryResultFailure(e.message);
      }
    } catch (e, stack) {
      AppLogger.warn(
        LogTopic.state,
        'deliverWithProof($orderId) unexpected error',
        error: e,
        stackTrace: stack,
      );
      return DeliveryResultFailure(_describeError(e));
    } finally {
      _busyIds.remove(orderId);
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Deliver in demo mode (R16)
  // ---------------------------------------------------------------------------

  /// Marks [orderId] as delivered with `demoMode: true`. The caller
  /// MUST gate this method by `Env.current.enableDevAffordances` so
  /// production builds never invoke it (R16.3).
  ///
  /// Surfaces the backend's error message verbatim when the route
  /// returns `demo mode disabled` (R16.4).
  Future<DeliveryResult> deliverWithDemoMode(String orderId) async {
    return _runAction(
      'deliverWithDemoMode',
      orderId,
      () async {
        final DeliveryRepository repository = _requireRepository();
        await repository.markDelivered(orderId, demoMode: true);
        return _completeDelivery(orderId);
      },
      mapBackendCode: _mapDeliverError,
    );
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Runs [action] guarded by a per-[orderId] busy flag, with consistent
  /// listener notification and stale-order / generic error mapping.
  ///
  /// [mapBackendCode] is consulted before the generic
  /// [DeliveryResultFailure] fallback so action-specific codes
  /// (`INVALID_OTP`, `OTP_EXPIRED`, `DEMO_MODE_DISABLED`) can be
  /// translated by the caller.
  Future<DeliveryResult> _runAction(
    String name,
    String orderId,
    Future<DeliveryResult> Function() action, {
    DeliveryResult? Function(ApiException error)? mapBackendCode,
  }) async {
    if (_repository == null) {
      return const DeliveryResultFailure('Network unavailable');
    }
    if (_busyIds.contains(orderId)) {
      return const DeliveryResultFailure('Action already in progress');
    }
    _busyIds.add(orderId);
    notifyListeners();

    try {
      return await action();
    } on OrderNotAvailableException catch (e) {
      AppLogger.info(
        LogTopic.state,
        '$name($orderId): order not available — ${e.message}',
      );
      return DeliveryResultStale(message: e.message);
    } on ApiException catch (e, stack) {
      AppLogger.warn(
        LogTopic.state,
        '$name($orderId) failed: ${e.backendCode ?? 'no-code'} ${e.message}',
        error: e,
        stackTrace: stack,
      );
      final DeliveryResult? mapped = mapBackendCode?.call(e);
      if (mapped != null) return mapped;
      return DeliveryResultFailure(e.message);
    } catch (e, stack) {
      AppLogger.warn(
        LogTopic.state,
        '$name($orderId) unexpected error',
        error: e,
        stackTrace: stack,
      );
      return DeliveryResultFailure(_describeError(e));
    } finally {
      _busyIds.remove(orderId);
      notifyListeners();
    }
  }

  /// Maps the deliver-specific backend codes to typed results. Returns
  /// `null` so [_runAction] falls back to a generic
  /// [DeliveryResultFailure].
  static DeliveryResult? _mapDeliverError(ApiException error) {
    final String? code = error.backendCode?.toUpperCase();
    if (code == 'INVALID_OTP') {
      return DeliveryResultInvalidOtp(message: error.message);
    }
    if (code == 'OTP_EXPIRED') {
      return DeliveryResultOtpExpired(message: error.message);
    }
    return null;
  }

  /// Applies `IN_TRANSIT -> DELIVERED` to [orderId], emits
  /// `order:untrack`, and returns a [DeliveryResultSuccess] populated
  /// from the just-completed order. Does NOT remove it from the batch —
  /// the completion sheet reads it before calling [clearActiveDelivery].
  DeliveryResultSuccess _completeDelivery(String orderId) {
    final DeliveryOrder? before = _orders[orderId];
    _applyLocalTransition(orderId, AssignmentStatus.delivered);
    _socket?.emit(SocketEvents.orderUntrack, <String, dynamic>{
      'orderId': orderId,
    });
    final DeliveryOrder? after = _orders[orderId] ?? before;
    if (after == null) {
      return _genericSuccess(orderId);
    }
    return DeliveryResultSuccess(
      orderEarning: after.riderEarning,
      customerName: after.customerAddress.name.isNotEmpty
          ? after.customerAddress.name
          : after.customerAddress.address,
      orderNumber: after.orderNumber,
    );
  }

  /// Locally drives [orderId] through [next] using the state machine.
  /// Same monotonic-walk guard as [applyExternalStatus] but without
  /// triggering the auto-remove on terminal — the action paths keep the
  /// order around for the completion summary.
  void _applyLocalTransition(String orderId, AssignmentStatus next) {
    final DeliveryOrder? order = _orders[orderId];
    if (order == null) return;

    final AssignmentStatus resolved = AssignmentStateMachine.apply(
      order.assignmentStatus,
      next,
      orderId: orderId,
    );
    if (resolved == order.assignmentStatus) return;
    _orders[orderId] = order.copyWith(assignmentStatus: resolved);
    notifyListeners();
  }

  DeliveryRepository _requireRepository() {
    final DeliveryRepository? repo = _repository;
    if (repo == null) {
      // Reached only by tests that wire the controller without a
      // repository and then drive a network action; surfaced via the
      // outer `_runAction` guard.
      throw StateError('Network unavailable');
    }
    return repo;
  }

  /// Builds a fallback [DeliveryResultSuccess] when the order has been
  /// removed from the batch between the API call and this method (e.g. a
  /// concurrent cancellation). The home dashboard refresh will fill in
  /// real values on the next refresh.
  DeliveryResultSuccess _genericSuccess(String orderId) {
    return DeliveryResultSuccess(
      orderEarning: 0,
      customerName: '',
      orderNumber: orderId,
    );
  }

  /// Called when [orderId] reaches a terminal status via an external
  /// (socket) event or an in-controller cancel. Removes it from the
  /// batch and auto-advances focus to the next remaining order, if any.
  void _onTerminalExternal(String orderId) {
    _orders.remove(orderId);
    _busyIds.remove(orderId);
    _collectedPayments.remove(orderId);
    _skippedOrderIds.remove(orderId);
    if (_focusedOrderId == orderId) {
      _focusedOrderId = null;
      _focusNextIfNeeded();
    }
    notifyListeners();
  }

  static String _describeError(Object error) {
    final String s = error.toString();
    if (s.length > 200) return '${s.substring(0, 200)}...';
    return s;
  }
}
