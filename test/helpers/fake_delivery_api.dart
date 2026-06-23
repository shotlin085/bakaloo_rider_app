import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:grolin_rider_app/core/network/api_envelope.dart';
import 'package:grolin_rider_app/features/delivery/data/delivery_api.dart';
import 'package:grolin_rider_app/features/delivery/domain/delivery_address.dart';
import 'package:grolin_rider_app/features/delivery/domain/delivery_history_entry.dart';
import 'package:grolin_rider_app/features/delivery/domain/delivery_order.dart';
import 'package:grolin_rider_app/features/delivery/domain/assignment_status.dart';
import 'package:grolin_rider_app/features/delivery/domain/payout.dart';
import 'package:grolin_rider_app/features/delivery/domain/rider_earnings.dart';
import 'package:grolin_rider_app/features/delivery/domain/rider_profile.dart';
import 'package:grolin_rider_app/features/delivery/domain/rider_stats.dart';
import 'package:grolin_rider_app/features/delivery/domain/store_info.dart';

/// Captured record of a [FakeDeliveryApi.markDelivered] call.
@immutable
class CapturedMarkDelivered {
  /// Constructs a captured mark-delivered call.
  const CapturedMarkDelivered({
    required this.orderId,
    this.otp,
    this.proofPhotoUrl,
    this.demoMode,
  });

  /// The order id passed to markDelivered.
  final String orderId;

  /// OTP value if supplied.
  final String? otp;

  /// Proof photo URL if supplied.
  final String? proofPhotoUrl;

  /// demoMode flag if supplied.
  final bool? demoMode;
}

/// Hand-rolled fake implementation of [DeliveryApi] for integration tests.
///
/// Behaviour per method is described in the spec's FakeDeliveryApi section.
/// Call counts and argument captures are exposed so tests can assert on
/// them after each step.
class FakeDeliveryApi implements DeliveryApi {
  // ---------------------------------------------------------------------------
  // Seed data (constructed once, reused across calls)
  // ---------------------------------------------------------------------------

  static final RiderProfile _seedProfile = RiderProfile(
    id: 'profile-001',
    userId: 'user-001',
    isApproved: true,
    isOnline: true,
    rating: 4.8,
    totalDeliveries: 42,
    commissionRate: 15.0,
    name: 'Test Rider',
    phone: '9876543210',
  );

  static final StoreInfo _seedStoreInfo = StoreInfo(
    name: 'Grolin Store',
    address: 'Salt Lake, Kolkata',
    lat: 22.57,
    lng: 88.36,
  );

  static final RiderStats _zeroStats = RiderStats(
    totalAssigned: 0,
    totalDelivered: 0,
    deliveredToday: 0,
    deliveriesToday: 0,
    totalEarnings: 0,
    earningsToday: 0,
    earningsThisWeek: 0,
    weeklyData: const <DailyStats>[],
    rating: 0,
    totalDeliveries: 0,
    acceptanceRate: 0,
    dailyTarget: 0,
  );

  static final RiderEarnings _zeroEarnings = RiderEarnings(
    period: 'today',
    totalEarnings: 0,
    deliveriesCount: 0,
    avgPerDelivery: 0,
    breakdown: const EarningsBreakdown(
      baseDeliveryFees: 0,
      distanceBonus: 0,
      performanceBonus: 0,
      tips: 0,
    ),
    dailyBreakdown: const <DailyEarning>[],
    pendingPayout: 0,
    alreadyPaid: 0,
    lastPayoutAmount: 0,
    rating: 0,
  );

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  /// Set to true after [_assignOrder] is called, so that [getOrders] can
  /// return the seeded order.
  DeliveryOrder? _assignedOrder;

  // ---------------------------------------------------------------------------
  // Call-count / argument captures
  // ---------------------------------------------------------------------------

  /// Number of times [getProfile] was called.
  int getProfileCallCount = 0;

  /// List of [isOnline] values passed to [toggleOnline].
  final List<bool> toggleOnlineCalls = <bool>[];

  /// List of (lat, lng) pairs passed to [updateLocation].
  final List<(double lat, double lng)> updateLocationCalls =
      <(double lat, double lng)>[];

  /// Number of times [getOrders] was called.
  int getOrdersCallCount = 0;

  /// List of order ids passed to [acceptOrder].
  final List<String> acceptOrderCalls = <String>[];

  /// List of order ids passed to [markPickedUp].
  final List<String> markPickedUpCalls = <String>[];

  /// List of captured [markDelivered] calls.
  final List<CapturedMarkDelivered> markDeliveredCalls =
      <CapturedMarkDelivered>[];

  /// Number of times [getStats] was called.
  int getStatsCallCount = 0;

  /// Number of times [getEarnings] was called.
  int getEarningsCallCount = 0;

  // ---------------------------------------------------------------------------
  // Test helper
  // ---------------------------------------------------------------------------

  /// Seeds the fake with [order] so that [getOrders] will return it on
  /// the next call (simulating a backend "assignment" event).
  void assignOrder(DeliveryOrder order) {
    _assignedOrder = order;
  }

  // ---------------------------------------------------------------------------
  // DeliveryApi implementation
  // ---------------------------------------------------------------------------

  @override
  Future<RiderProfile> getProfile() async {
    getProfileCallCount++;
    return _seedProfile;
  }

  @override
  Future<void> toggleOnline(bool isOnline) async {
    toggleOnlineCalls.add(isOnline);
  }

  @override
  Future<void> updateLocation(double latitude, double longitude) async {
    updateLocationCalls.add((latitude, longitude));
  }

  @override
  Future<List<DeliveryOrder>> getOrders({String? status}) async {
    getOrdersCallCount++;
    final DeliveryOrder? order = _assignedOrder;
    if (order == null) {
      return const <DeliveryOrder>[];
    }
    return <DeliveryOrder>[order];
  }

  @override
  Future<Map<String, dynamic>> acceptOrder(String orderId) async {
    acceptOrderCalls.add(orderId);
    // Return the order updated with ACCEPTED status.
    final DeliveryOrder? base = _assignedOrder;
    if (base == null) {
      return <String, dynamic>{
        'orderId': orderId,
        'assignmentStatus': 'ACCEPTED',
      };
    }
    final DeliveryOrder accepted =
        base.copyWith(assignmentStatus: AssignmentStatus.accepted);
    return accepted.toJson();
  }

  @override
  Future<void> markPickedUp(String orderId) async {
    markPickedUpCalls.add(orderId);
  }

  @override
  Future<void> markDelivered(
    String orderId, {
    String? otp,
    String? proofPhotoUrl,
    bool? demoMode,
  }) async {
    assert(
      demoMode == true,
      'FakeDeliveryApi.markDelivered: expected demoMode==true '
      'but got demoMode=$demoMode',
    );
    markDeliveredCalls.add(
      CapturedMarkDelivered(
        orderId: orderId,
        otp: otp,
        proofPhotoUrl: proofPhotoUrl,
        demoMode: demoMode,
      ),
    );
  }

  @override
  Future<StoreInfo> getStoreInfo() async {
    return _seedStoreInfo;
  }

  @override
  Future<RiderStats> getStats() async {
    getStatsCallCount++;
    return _zeroStats;
  }

  @override
  Future<RiderEarnings> getEarnings(EarningsPeriod period) async {
    getEarningsCallCount++;
    return _zeroEarnings.copyWith(period: period.wire);
  }

  // ---------------------------------------------------------------------------
  // Unsupported methods (not needed for this integration test path)
  // ---------------------------------------------------------------------------

  @override
  Future<List<Map<String, dynamic>>> getDocuments() {
    throw UnsupportedError('FakeDeliveryApi.getDocuments not implemented');
  }

  @override
  Future<void> rejectOrder(String orderId, String reason) {
    throw UnsupportedError('FakeDeliveryApi.rejectOrder not implemented');
  }

  @override
  Future<void> cancelDelivery(String orderId, String reason) {
    throw UnsupportedError('FakeDeliveryApi.cancelDelivery not implemented');
  }

  @override
  Future<Map<String, dynamic>> resendOtp(String orderId) {
    throw UnsupportedError('FakeDeliveryApi.resendOtp not implemented');
  }

  @override
  Future<RiderProfile> updateProfile({
    String? name,
    String? vehicleType,
    String? vehicleNumber,
    String? bankAccountNumber,
    String? bankIfsc,
    String? bankName,
  }) {
    throw UnsupportedError('FakeDeliveryApi.updateProfile not implemented');
  }

  @override
  Future<String> uploadProof(String orderId, File file) {
    throw UnsupportedError('FakeDeliveryApi.uploadProof not implemented');
  }

  @override
  Future<({List<Payout> items, Pagination pagination})> getPayouts({
    int page = 1,
    int limit = 20,
  }) {
    throw UnsupportedError('FakeDeliveryApi.getPayouts not implemented');
  }

  @override
  Future<({List<DeliveryHistoryEntry> orders, int total})> getHistory({
    int page = 1,
    int limit = 20,
  }) {
    throw UnsupportedError('FakeDeliveryApi.getHistory not implemented');
  }
}
