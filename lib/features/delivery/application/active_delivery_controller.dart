import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/realtime/socket_client.dart';
import '../../../core/realtime/socket_events.dart';
import '../../../core/utils/app_logger.dart';
import '../data/delivery_repository.dart';
import '../domain/assignment_status.dart';
import '../domain/delivery_order.dart';
import 'assignment_state_machine.dart';

/// Discriminated outcome of the four delivery-lifecycle actions on
/// [ActiveDeliveryController]: [ActiveDeliveryController.markPickedUp],
/// [ActiveDeliveryController.deliverWithOtp],
/// [ActiveDeliveryController.deliverWithProof], and
/// [ActiveDeliveryController.deliverWithDemoMode].
///
/// The presentation layer pattern-matches on the result so each
/// outcome (success, stale order, invalid OTP, expired OTP, proof
/// upload failure, generic failure) maps to its own UX path
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

/// Holds the single active delivery (status `ACCEPTED` or `IN_TRANSIT`)
/// and owns the four mid-delivery actions (pickup, OTP deliver, proof
/// deliver, demo deliver).
///
/// Transitions go through [AssignmentStateMachine] to enforce the
/// monotonicity property (R9.1, R9.2). When the delivery reaches a
/// terminal status it is **not** auto-cleared from inside the action
/// methods so the presentation layer can still read the just-completed
/// order to render the completion summary; the sheet calls
/// [clearActiveDelivery] when the rider acknowledges the summary.
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
  /// either. Network methods ([markPickedUp], [deliverWithOtp],
  /// [deliverWithProof], [deliverWithDemoMode]) require a non-null
  /// repository; calling them without one returns a
  /// [DeliveryResultFailure].
  ActiveDeliveryController({
    DeliveryRepository? repository,
    SocketClient? socket,
  })  : _repository = repository,
        _socket = socket;

  final DeliveryRepository? _repository;
  final SocketClient? _socket;

  DeliveryOrder? _current;
  bool _busy = false;

  /// The currently active delivery, or `null` when none is active.
  DeliveryOrder? get current => _current;

  /// Whether a network action ([markPickedUp] / [deliverWith…]) is in
  /// flight. Sheets read this flag to disable their primary buttons.
  bool get isBusy => _busy;

  /// Sets [order] as the active delivery and notifies listeners.
  void setActiveDelivery(DeliveryOrder order) {
    _current = order;
    notifyListeners();
  }

  /// Clears the active delivery and notifies listeners.
  void clearActiveDelivery() {
    _current = null;
    notifyListeners();
  }

  /// Applies an externally received [next] status to the active delivery
  /// identified by [orderId].
  ///
  /// If the current delivery's `orderId` does not match [orderId] the call
  /// is a no-op (the event is for a different order).
  ///
  /// The transition is validated by [AssignmentStateMachine.apply]; illegal
  /// transitions are rejected and logged without mutating state. When the
  /// resulting status is terminal, [_onTerminalExternal] is called to clear the
  /// active delivery.
  void applyExternalStatus(String orderId, AssignmentStatus next) {
    final DeliveryOrder? current = _current;
    if (current == null || current.orderId != orderId) return;

    final AssignmentStatus resolved = AssignmentStateMachine.apply(
      current.assignmentStatus,
      next,
      orderId: orderId,
    );

    if (resolved == current.assignmentStatus) {
      // Either idempotent (same status) or illegal (rejected). Either way
      // the state did not change, so no notification is needed.
      return;
    }

    _current = current.copyWith(assignmentStatus: resolved);
    notifyListeners();

    if (AssignmentStateMachine.isTerminal(resolved)) {
      _onTerminalExternal();
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
      final DeliveryOrder? c = _current;
      if (c == null || c.orderId != orderId) {
        return _genericSuccess(orderId);
      }
      return DeliveryResultSuccess(
        orderEarning: c.riderEarning,
        customerName: c.customerAddress.name.isNotEmpty
            ? c.customerAddress.name
            : c.customerAddress.address,
        orderNumber: c.orderNumber,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Deliver via OTP (R14)
  // ---------------------------------------------------------------------------

  /// Marks [orderId] as delivered using the customer's [otp].
  ///
  /// Translates backend codes:
  /// - `INVALID_OTP` -> [DeliveryResultInvalidOtp] (R14.5).
  /// - `OTP_EXPIRED` -> [DeliveryResultOtpExpired] (R14.6).
  /// - `ORDER_NOT_AVAILABLE` -> [DeliveryResultStale].
  ///
  /// On success: applies the terminal transition
  /// `IN_TRANSIT -> DELIVERED`, emits `order:untrack` (R14.4), and
  /// returns [DeliveryResultSuccess].
  Future<DeliveryResult> deliverWithOtp(String orderId, String otp) async {
    return _runAction(
      'deliverWithOtp',
      orderId,
      () async {
        final DeliveryRepository repository = _requireRepository();
        await repository.markDelivered(orderId, otp: otp);
        return _completeDelivery(orderId);
      },
      mapBackendCode: _mapDeliverError,
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
  Future<DeliveryResult> deliverWithProof(String orderId, File file) async {
    final DeliveryRepository? repository = _repository;
    if (repository == null) {
      return const DeliveryResultFailure('Network unavailable');
    }
    if (_busy) {
      return const DeliveryResultFailure('Action already in progress');
    }
    _busy = true;
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
        await repository.markDelivered(orderId, proofPhotoUrl: url);
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
      _busy = false;
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

  /// Runs [action] guarded by the [_busy] flag, with consistent
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
    if (_busy) {
      return const DeliveryResultFailure('Action already in progress');
    }
    _busy = true;
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
      _busy = false;
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

  /// Applies `IN_TRANSIT -> DELIVERED` to the active delivery, emits
  /// `order:untrack`, and returns a [DeliveryResultSuccess] populated
  /// from the just-completed order. Does NOT clear the active
  /// delivery — the completion sheet reads it before clearing.
  DeliveryResultSuccess _completeDelivery(String orderId) {
    final DeliveryOrder? before = _current;
    _applyLocalTransition(orderId, AssignmentStatus.delivered);
    _socket?.emit(SocketEvents.orderUntrack, <String, dynamic>{
      'orderId': orderId,
    });
    final DeliveryOrder? after = _current ?? before;
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

  /// Locally drives the active delivery through [next] using the state
  /// machine. Same monotonic-walk guard as [applyExternalStatus] but
  /// without triggering the auto-clear on terminal — the action paths
  /// keep the order around for the completion summary.
  void _applyLocalTransition(String orderId, AssignmentStatus next) {
    final DeliveryOrder? current = _current;
    if (current == null || current.orderId != orderId) return;

    final AssignmentStatus resolved = AssignmentStateMachine.apply(
      current.assignmentStatus,
      next,
      orderId: orderId,
    );
    if (resolved == current.assignmentStatus) return;
    _current = current.copyWith(assignmentStatus: resolved);
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

  /// Builds a fallback [DeliveryResultSuccess] when the active delivery
  /// has been cleared between the API call and this method (e.g. a
  /// concurrent cancellation). The home dashboard refresh will fill in
  /// real values on the next refresh.
  DeliveryResultSuccess _genericSuccess(String orderId) {
    return DeliveryResultSuccess(
      orderEarning: 0,
      customerName: '',
      orderNumber: orderId,
    );
  }

  /// Called when the active delivery reaches a terminal status via an
  /// external (socket) event. Clears `_current` and notifies listeners
  /// so the UI can react.
  void _onTerminalExternal() {
    _current = null;
    notifyListeners();
  }

  static String _describeError(Object error) {
    final String s = error.toString();
    if (s.length > 200) return '${s.substring(0, 200)}...';
    return s;
  }
}
