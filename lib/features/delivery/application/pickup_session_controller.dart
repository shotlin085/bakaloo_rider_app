import 'package:flutter/foundation.dart';

import '../domain/assignment_status.dart';
import '../domain/delivery_order.dart';
import '../domain/pickup_batch.dart';

/// Tracks per-order QR-pickup progress for the rider's **current** store
/// visit — purely client-side, session-local state layered on top of
/// [ActiveDeliveryController]'s batch. The backend has no notion of
/// "needs scan" vs. "verified": that's the `order_pickup_tokens` row's own
/// ACTIVE/VERIFIED/CONSUMED lifecycle, enforced server-side on every
/// `verify-scan`/`markPickedUp` call regardless of what this controller
/// thinks — this is a UI convenience so the pickup-batch screen can show
/// "2 of 4 collected" without re-querying token status for every order on
/// every rebuild.
///
/// Pure-Dart [ChangeNotifier], no Riverpod, matching every other
/// controller in this feature (`ActiveDeliveryController`,
/// `OffersController`).
class PickupSessionController extends ChangeNotifier {
  final Map<String, PickupScanStatus> _status = <String, PickupScanStatus>{};
  final Map<String, PickupVerification> _verifications =
      <String, PickupVerification>{};

  /// Read-only snapshot of every order's current scan status this
  /// session.
  Map<String, PickupScanStatus> get statuses => Map<String, PickupScanStatus>.unmodifiable(_status);

  /// The checklist returned by `verify-scan` for [orderId], if it's been
  /// scanned this session.
  PickupVerification? verificationFor(String orderId) => _verifications[orderId];

  PickupScanStatus statusFor(String orderId) =>
      _status[orderId] ?? PickupScanStatus.needsScan;

  /// Count of orders tracked this session that have reached
  /// [PickupScanStatus.pickedUp] — the "X" in "X of Y collected".
  int get pickedUpCount =>
      _status.values.where((PickupScanStatus s) => s == PickupScanStatus.pickedUp).length;

  /// Total orders tracked this session — the "Y" in "X of Y collected".
  int get totalCount => _status.length;

  /// Ensures every order in [batch] has a tracked status, without
  /// clobbering an order that's already further along (e.g. re-called
  /// after a routine `/delivery/orders` reconciliation). New entries are
  /// seeded from the order's real wire status: still [AssignmentStatus.accepted]
  /// means it hasn't been picked up yet this app install, so it needs a
  /// scan; [AssignmentStatus.inTransit] means pickup already happened
  /// (e.g. the app was restarted mid-delivery) so there's nothing to
  /// scan for it this session.
  void syncFromBatch(List<DeliveryOrder> batch) {
    bool changed = false;
    for (final DeliveryOrder order in batch) {
      if (_status.containsKey(order.orderId)) continue;
      _status[order.orderId] = order.assignmentStatus == AssignmentStatus.inTransit
          ? PickupScanStatus.pickedUp
          : PickupScanStatus.needsScan;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Records a successful `verify-scan` result for [orderId].
  void markVerified(String orderId, PickupVerification verification) {
    _status[orderId] = PickupScanStatus.verified;
    _verifications[orderId] = verification;
    notifyListeners();
  }

  /// Records a successful pickup confirmation (`markPickedUp` succeeded)
  /// for [orderId].
  void markPickedUp(String orderId) {
    _status[orderId] = PickupScanStatus.pickedUp;
    notifyListeners();
  }

  /// Drops [orderId] from this session (order cancelled/removed from the
  /// batch before pickup).
  void remove(String orderId) {
    if (_status.remove(orderId) == null) return;
    _verifications.remove(orderId);
    notifyListeners();
  }

  /// Clears the whole session — called once the rider leaves the pickup
  /// phase and moves into delivering, so a later store visit starts
  /// fresh.
  void reset() {
    _status.clear();
    _verifications.clear();
    notifyListeners();
  }
}
