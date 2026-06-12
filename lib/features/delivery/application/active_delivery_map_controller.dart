import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:latlong2/latlong.dart' as ll;

import '../../../core/maps/geo.dart';
import '../../../core/maps/geo_bounds.dart';
import '../../../core/maps/geo_point.dart';
import '../../../core/maps/marker_assets.dart';
import '../../../core/maps/route_service.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/assignment_status.dart';
import '../domain/delivery_address.dart';
import '../domain/delivery_order.dart';
import '../domain/store_info.dart';

/// Active route phase rendered by [ActiveDeliveryMapController].
enum LocationPhase { toStore, toCustomer, none }

/// A keyed marker entry used for idempotent rebuilds.
@immutable
class MarkerEntry {
  const MarkerEntry({
    required this.id,
    required this.position,
    required this.marker,
  });

  final String id;
  final GeoPoint position;
  final fm.Marker marker;

  @override
  bool operator ==(Object other) =>
      other is MarkerEntry && other.id == id && other.position == position;

  @override
  int get hashCode => Object.hash(id, position);
}

/// Owns marker / polyline / phase state for the active delivery
/// map screen, including the road-snapped navigation polyline
/// (rider → destination via OSRM).
class ActiveDeliveryMapController extends ChangeNotifier {
  ActiveDeliveryMapController({
    required MarkerAssets markerAssets,
    RouteService? routeService,
  })  : _markerAssets = markerAssets,
        _routeService = routeService ?? RouteService();

  final MarkerAssets _markerAssets;
  final RouteService _routeService;

  GeoPoint? get riderPosition => _riderPosition;
  GeoPoint? _riderPosition;

  Map<String, MarkerEntry> get markers => _markers;
  Map<String, MarkerEntry> _markers = const <String, MarkerEntry>{};
  List<fm.Marker> get markerWidgets =>
      _markers.values.map((MarkerEntry e) => e.marker).toList(growable: false);

  List<fm.Polyline> get polylines => _polylines;
  List<fm.Polyline> _polylines = const <fm.Polyline>[];

  LocationPhase get phase => _phase;
  LocationPhase _phase = LocationPhase.none;

  bool get showRecenterButton => _showRecenterButton;
  bool _showRecenterButton = false;

  bool get customerLocationApproximate => _customerLocationApproximate;
  bool _customerLocationApproximate = false;

  GeoBounds? get phaseBounds => _phaseBounds;
  GeoBounds? _phaseBounds;

  GeoPoint? get storePosition => _storePosition;
  GeoPoint? _storePosition;

  GeoPoint? get customerPosition => _customerPosition;
  GeoPoint? _customerPosition;

  /// Distance in metres from the rider to the active destination.
  /// `null` when either side is unknown.
  double? get distanceMeters => _distanceMeters;
  double? _distanceMeters;

  /// Estimated travel time in minutes, computed from the road
  /// polyline length divided by an assumed 25 km/h average city
  /// speed. `null` when no route is loaded.
  int? get etaMinutes => _etaMinutes;
  int? _etaMinutes;

  String? _currentOrderId;

  /// Cached road-following polyline points so we don't lose the
  /// route between rider GPS pings.
  List<GeoPoint> _routePoints = const <GeoPoint>[];

  /// Origin/destination this route was fetched for; lets us avoid
  /// redundant network calls when nothing meaningful has changed.
  GeoPoint? _routeFrom;
  GeoPoint? _routeTo;

  static const double _riderMoveThresholdMeters = 5;
  static const double _routeRefetchThresholdMeters = 50;
  static const double _averageSpeedKmh = 25.0;

  // ---------------------------------------------------------------------------
  // Public mutations
  // ---------------------------------------------------------------------------

  void setShowRecenterButton(bool value) {
    if (_showRecenterButton == value) return;
    _showRecenterButton = value;
    notifyListeners();
  }

  void applyOrder(DeliveryOrder order, StoreInfo? store) {
    final bool orderChanged = _currentOrderId != order.orderId;
    _currentOrderId = order.orderId;

    GeoPoint? resolvedStore;
    final DeliveryAddress storeAddr = order.storeAddress;
    if (storeAddr.lat != null && storeAddr.lng != null) {
      resolvedStore = GeoPoint(storeAddr.lat!, storeAddr.lng!);
    } else if (store != null && store.isConfigured) {
      resolvedStore = GeoPoint(store.lat, store.lng);
    }

    GeoPoint? resolvedCustomer;
    bool customerLocationMissing = false;
    final DeliveryAddress customerAddr = order.customerAddress;
    if (customerAddr.lat != null && customerAddr.lng != null) {
      resolvedCustomer = GeoPoint(customerAddr.lat!, customerAddr.lng!);
    } else {
      customerLocationMissing = true;
      resolvedCustomer = null;
    }

    final LocationPhase nextPhase;
    GeoPoint? destination;
    switch (order.assignmentStatus) {
      case AssignmentStatus.assigned:
      case AssignmentStatus.accepted:
        nextPhase =
            resolvedStore == null ? LocationPhase.none : LocationPhase.toStore;
        destination = resolvedStore;
      case AssignmentStatus.inTransit:
        nextPhase = resolvedCustomer == null
            ? LocationPhase.none
            : LocationPhase.toCustomer;
        destination = resolvedCustomer;
      case AssignmentStatus.delivered:
      case AssignmentStatus.cancelled:
        nextPhase = LocationPhase.none;
        destination = null;
    }

    _storePosition = resolvedStore;
    _customerPosition = resolvedCustomer;
    _customerLocationApproximate = customerLocationMissing;
    _phase = nextPhase;

    _markers = _buildMarkers(
      rider: _riderPosition,
      store: resolvedStore,
      customer: resolvedCustomer,
    );
    _phaseBounds = Geo.boundsOf(_riderPosition, destination);
    _recomputeDistanceAndEta();
    _polylines = _buildPolylinesFromCache();

    if (orderChanged) {
      _showRecenterButton = false;
    }

    notifyListeners();

    // Fire-and-forget road-route fetch; updates the polyline when
    // OSRM responds.
    unawaited(_refreshRoute(_riderPosition, destination));
  }

  void updateRiderPosition(GeoPoint next) {
    final GeoPoint? prev = _riderPosition;
    if (prev != null) {
      final double meters = Geo.distanceMeters(prev, next);
      if (meters < _riderMoveThresholdMeters) return;
    }
    _riderPosition = next;

    final GeoPoint? destination = _resolveDestinationForPhase();
    _markers = _buildMarkers(
      rider: next,
      store: _storePosition,
      customer: _customerPosition,
    );
    _phaseBounds = Geo.boundsOf(next, destination);
    _recomputeDistanceAndEta();
    _polylines = _buildPolylinesFromCache();
    notifyListeners();

    // Re-fetch the road route only if the rider has drifted far
    // enough from the previous origin (saves OSRM round-trips).
    if (destination != null) {
      final GeoPoint? lastFrom = _routeFrom;
      final GeoPoint? lastTo = _routeTo;
      final bool destChanged = lastTo == null || lastTo != destination;
      final bool riderDrifted = lastFrom == null ||
          Geo.distanceMeters(lastFrom, next) >= _routeRefetchThresholdMeters;
      if (destChanged || riderDrifted) {
        unawaited(_refreshRoute(next, destination));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  GeoPoint? _resolveDestinationForPhase() {
    switch (_phase) {
      case LocationPhase.toStore:
        return _storePosition;
      case LocationPhase.toCustomer:
        return _customerPosition;
      case LocationPhase.none:
        return null;
    }
  }

  Future<void> _refreshRoute(GeoPoint? from, GeoPoint? to) async {
    if (from == null || to == null || _phase == LocationPhase.none) {
      _routePoints = const <GeoPoint>[];
      _routeFrom = null;
      _routeTo = null;
      _polylines = _buildPolylinesFromCache();
      notifyListeners();
      return;
    }
    final List<GeoPoint> route = await _routeService.getRoute(from, to);
    // Discard stale results (rider may have moved on or accepted a
    // different order while OSRM was thinking).
    if (_phase == LocationPhase.none) return;
    final GeoPoint? currentDest = _resolveDestinationForPhase();
    if (currentDest == null || currentDest != to) return;

    _routePoints = route;
    _routeFrom = from;
    _routeTo = to;
    _polylines = _buildPolylinesFromCache();
    _recomputeDistanceAndEta();
    notifyListeners();
  }

  Map<String, MarkerEntry> _buildMarkers({
    required GeoPoint? rider,
    required GeoPoint? store,
    required GeoPoint? customer,
  }) {
    final Map<String, MarkerEntry> out = <String, MarkerEntry>{};
    if (rider != null) {
      out['rider'] = MarkerEntry(
        id: 'rider',
        position: rider,
        marker: fm.Marker(
          key: const ValueKey<String>('rider'),
          point: rider.toLatLng(),
          width: MarkerAssets.riderSizeDp,
          height: MarkerAssets.riderSizeDp,
          alignment: Alignment.center,
          child: _markerAssets.riderMarker(),
        ),
      );
    }
    if (store != null) {
      out['store'] = MarkerEntry(
        id: 'store',
        position: store,
        marker: fm.Marker(
          key: const ValueKey<String>('store'),
          point: store.toLatLng(),
          width: MarkerAssets.otherSizeDp,
          height: MarkerAssets.otherSizeDp,
          alignment: Alignment.center,
          child: _markerAssets.storeMarker(),
        ),
      );
    }
    if (customer != null) {
      out['customer'] = MarkerEntry(
        id: 'customer',
        position: customer,
        marker: fm.Marker(
          key: const ValueKey<String>('customer'),
          point: customer.toLatLng(),
          width: MarkerAssets.otherSizeDp,
          height: MarkerAssets.otherSizeDp,
          alignment: Alignment.center,
          child: _markerAssets.customerMarker(),
        ),
      );
    }
    return out;
  }

  List<fm.Polyline> _buildPolylinesFromCache() {
    if (_phase == LocationPhase.none) return const <fm.Polyline>[];
    final GeoPoint? rider = _riderPosition;
    final GeoPoint? dest = _resolveDestinationForPhase();
    if (rider == null || dest == null) return const <fm.Polyline>[];

    final List<GeoPoint> points = _routePoints.length >= 2
        ? _routePoints
        : <GeoPoint>[rider, dest];

    final List<ll.LatLng> latLngs =
        points.map((GeoPoint p) => p.toLatLng()).toList(growable: false);

    return <fm.Polyline>[
      // Soft white halo so the route stays readable on busy tiles.
      fm.Polyline(
        points: latLngs,
        color: AppColors.white.withValues(alpha: 0.85),
        strokeWidth: 9,
      ),
      fm.Polyline(
        points: latLngs,
        color: AppColors.mapBlue,
        strokeWidth: 5,
      ),
    ];
  }

  void _recomputeDistanceAndEta() {
    final GeoPoint? rider = _riderPosition;
    final GeoPoint? dest = _resolveDestinationForPhase();
    if (rider == null || dest == null) {
      _distanceMeters = null;
      _etaMinutes = null;
      return;
    }
    final double meters = _routePoints.length >= 2
        ? _polylineLengthMeters(_routePoints)
        : Geo.distanceMeters(rider, dest);
    _distanceMeters = meters;
    final double minutes = (meters / 1000.0) / _averageSpeedKmh * 60.0;
    _etaMinutes = minutes < 1 ? 1 : minutes.ceil().clamp(1, 999);
  }

  static double _polylineLengthMeters(List<GeoPoint> pts) {
    double total = 0;
    for (int i = 1; i < pts.length; i++) {
      total += Geo.distanceMeters(pts[i - 1], pts[i]);
    }
    return total;
  }
}
