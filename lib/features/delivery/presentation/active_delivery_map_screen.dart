import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:url_launcher/url_launcher.dart' as ul;

import '../../../app/router.dart';
import '../../../core/config/env.dart';
import '../../../core/location/location_lifecycle_manager.dart';
import '../../../core/location/rider_location_provider.dart';
import '../../../core/maps/cached_tile_provider.dart';
import '../../../core/maps/geo_bounds.dart';
import '../../../core/maps/geo_point.dart';
import '../../../core/maps/marker_assets.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/external_nav_launcher.dart';
import '../../../shared/widgets/app_button.dart';
import '../application/active_delivery_controller.dart';
import '../application/active_delivery_map_controller.dart';
import '../application/delivery_socket_controller.dart';
import '../data/delivery_api.dart' show CancelDeliveryReason;
import '../domain/assignment_status.dart';
import '../domain/collected_payment.dart';
import '../domain/delivery_address.dart';
import '../domain/delivery_order.dart';
import '../domain/delivery_outcome.dart';
import '../domain/store_info.dart';
import 'camera_director.dart';
import 'cancel_delivery_sheet.dart';
import 'collect_payment_sheet.dart';
import 'completion_summary_sheet.dart';
import 'demo_complete_sheet.dart';
import 'pickup_sheet.dart';

/// Map-first screen the rider sees while completing an active
/// delivery (R12).
///
/// Three layers (top-down):
///
/// 1. A long-lived [FlutterMap] with OSM raster tiles fed through
///    the on-device [CachedTileProvider]. Marker / polyline updates
///    flow through [ActiveDeliveryMapController] (a [ChangeNotifier])
///    consumed via a [ValueListenableBuilder] reading the rider's
///    [ValueNotifier<GeoPoint?>] from [riderLocationNotifierProvider]
///    so the surrounding [Scaffold] never rebuilds when the rider
///    moves (R25.1).
/// 2. A status pill in the top SafeArea reflecting the
///    [AssignmentStatus] phase ("Heading to store" / "Heading to
///    customer" / "Delivered").
/// 3. A [DraggableScrollableSheet] anchored at the bottom with
///    snap positions `[0.20, 0.48, 0.82]` carrying the
///    phase-specific actions (call, navigate, mark picked up /
///    deliver). A floating recenter button sits above the sheet,
///    visible only while the rider is mid-pan.
class ActiveDeliveryMapScreen extends ConsumerStatefulWidget {
  const ActiveDeliveryMapScreen({super.key});

  @override
  ConsumerState<ActiveDeliveryMapScreen> createState() =>
      _ActiveDeliveryMapScreenState();
}

class _ActiveDeliveryMapScreenState
    extends ConsumerState<ActiveDeliveryMapScreen> {
  late final MapController _mapController = MapController();
  bool _mapReady = false;

  /// Whether [MarkerAssets.ensureWarmedFor] has populated the cache
  /// for the active DPR. Kept for API parity with the bitmap era.
  bool _markersWarmed = false;

  ValueNotifier<GeoPoint?>? _riderNotifier;
  void Function()? _riderListener;

  String? _appliedOrderId;
  AssignmentStatus? _appliedStatus;

  /// orderIds of every in-transit batch order the map was last rendered
  /// for. Lets [build] re-apply the map when a *different* batch order
  /// is picked up or delivered mid-trip — not just when the focused
  /// order itself changes — so the "other stops" pins/strip stay
  /// current (item 8/9).
  Set<String> _appliedInTransitIds = const <String>{};

  String? _summaryShownForOrderId;
  bool _summaryVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_warmMarkers());
      unawaited(_startLocationStream());
    });
  }

  Future<void> _startLocationStream() async {
    if (!mounted) return;
    final LocationLifecycleManager manager =
        ref.read<LocationLifecycleManager>(locationLifecycleManagerProvider);
    // Ensure the stream is running — the manager handles permission,
    // seeding, and backend uploads automatically.
    if (!manager.isStreaming) {
      await manager.onWentOnline();
    }
  }

  Future<void> _warmMarkers() async {
    if (!mounted) return;
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final MarkerAssets assets = ref.read<MarkerAssets>(markerAssetsProvider);
    if (!assets.isWarmedFor(dpr)) {
      await assets.ensureWarmedFor(dpr);
    }
    if (!mounted) return;
    setState(() => _markersWarmed = true);
    final DeliveryOrder? order = ref
        .read<ActiveDeliveryController>(activeDeliveryControllerProvider)
        .current;
    if (order != null) {
      _applyOrderToMap(order);
    }
    _bindRiderNotifier();
  }

  void _bindRiderNotifier() {
    final ValueNotifier<GeoPoint?> notifier =
        ref.read<ValueNotifier<GeoPoint?>>(riderLocationNotifierProvider);
    if (identical(_riderNotifier, notifier)) return;
    _detachRiderNotifier();
    _riderNotifier = notifier;
    _riderListener = _onRiderPositionChanged;
    notifier.addListener(_riderListener!);
    final GeoPoint? seed = notifier.value;
    if (seed != null) {
      ref
          .read<ActiveDeliveryMapController>(activeDeliveryMapControllerProvider)
          .updateRiderPosition(seed);
    }
  }

  void _detachRiderNotifier() {
    final ValueNotifier<GeoPoint?>? n = _riderNotifier;
    final void Function()? l = _riderListener;
    if (n != null && l != null) {
      n.removeListener(l);
    }
    _riderNotifier = null;
    _riderListener = null;
  }

  void _onRiderPositionChanged() {
    if (!mounted) return;
    final GeoPoint? next = _riderNotifier?.value;
    if (next == null) return;
    final ActiveDeliveryMapController map = ref
        .read<ActiveDeliveryMapController>(activeDeliveryMapControllerProvider);
    map.updateRiderPosition(next);
    unawaited(_maybeAutoFit());
  }

  void _applyOrderToMap(DeliveryOrder order) {
    final ActiveDeliveryMapController map = ref
        .read<ActiveDeliveryMapController>(activeDeliveryMapControllerProvider);
    final StoreInfo? store =
        ref.read<AsyncValue<StoreInfo>>(storeInfoProvider).value;
    final List<DeliveryOrder> batch = ref
        .read<ActiveDeliveryController>(activeDeliveryControllerProvider)
        .batch;
    map.applyOrder(order, store, batch: batch);
  }

  @override
  void dispose() {
    _detachRiderNotifier();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Camera autopilot
  // ---------------------------------------------------------------------------

  void _onUserPan() {
    final CameraDirector director =
        ref.read<CameraDirector>(cameraDirectorProvider);
    director.onUserPan();
    ref
        .read<ActiveDeliveryMapController>(activeDeliveryMapControllerProvider)
        .setShowRecenterButton(true);
  }

  Future<void> _onRecenterPressed() async {
    final CameraDirector director =
        ref.read<CameraDirector>(cameraDirectorProvider);
    final ActiveDeliveryMapController map = ref
        .read<ActiveDeliveryMapController>(activeDeliveryMapControllerProvider);
    final GeoBounds? bounds = map.phaseBounds;
    if (bounds == null) return;
    if (!_mapReady) return;
    await director.recenter(controller: _mapController, bounds: bounds);
    if (!mounted) return;
    map.setShowRecenterButton(false);
  }

  Future<void> _maybeAutoFit() async {
    if (!_mapReady) return;
    final ActiveDeliveryMapController map = ref
        .read<ActiveDeliveryMapController>(activeDeliveryMapControllerProvider);
    final GeoBounds? bounds = map.phaseBounds;
    if (bounds == null) return;
    final CameraDirector director =
        ref.read<CameraDirector>(cameraDirectorProvider);
    await director.maybeFitBounds(
      controller: _mapController,
      bounds: bounds,
      now: DateTime.now(),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ActiveDeliveryController activeDelivery = ref
        .watch<ActiveDeliveryController>(activeDeliveryControllerProvider);
    final DeliveryOrder? order = activeDelivery.current;

    if (order == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.go(AppRoutes.home);
      });
      return const _ActiveDeliveryGoneScreen();
    }

    if (!_markersWarmed) {
      return const Scaffold(
        backgroundColor: AppColors.white,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.charcoal),
        ),
      );
    }

    final Set<String> inTransitIds = activeDelivery.batch
        .where((DeliveryOrder o) => o.assignmentStatus == AssignmentStatus.inTransit)
        .map((DeliveryOrder o) => o.orderId)
        .toSet();
    final bool otherStopsChanged = !setEquals(_appliedInTransitIds, inTransitIds);

    if (order.orderId != _appliedOrderId ||
        order.assignmentStatus != _appliedStatus ||
        otherStopsChanged) {
      final bool phaseChanged = _appliedOrderId == order.orderId &&
          _appliedStatus != order.assignmentStatus;
      _appliedOrderId = order.orderId;
      _appliedStatus = order.assignmentStatus;
      _appliedInTransitIds = inTransitIds;
      if (phaseChanged) {
        ref.read<CameraDirector>(cameraDirectorProvider).resetPhaseFit();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _applyOrderToMap(order);
        if (phaseChanged) {
          unawaited(_maybeAutoFit());
        }
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeShowCompletionSummary(order);
    });

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        context.go(AppRoutes.home);
      },
      child: Scaffold(
        backgroundColor: AppColors.white,
        body: Column(
          children: <Widget>[
            // Map + overlay controls fill all available space above the panel.
            Expanded(
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: _MapLayer(
                      order: order,
                      mapController: _mapController,
                      onMapReady: () {
                        _mapReady = true;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          unawaited(_maybeAutoFit());
                        });
                      },
                      onUserPan: _onUserPan,
                    ),
                  ),
                  Positioned(
                    top: MediaQuery.viewPaddingOf(context).top + 12,
                    left: 16,
                    right: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _NavTopBar(status: order.assignmentStatus),
                        const SizedBox(height: 8),
                        const _StopsStrip(),
                      ],
                    ),
                  ),
                  // Floating recenter button — bottom-right, clear of panel.
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: _RecenterButton(onPressed: _onRecenterPressed),
                  ),
                ],
              ),
            ),
            // Fixed step-action panel anchored to the bottom.
            _StepActionPanel(order: order),
          ],
        ),
      ),
    );
  }

  void _maybeShowCompletionSummary(DeliveryOrder order) {
    if (_summaryVisible) return;
    if (order.assignmentStatus != AssignmentStatus.delivered) return;
    if (_summaryShownForOrderId == order.orderId) return;
    _summaryShownForOrderId = order.orderId;
    _summaryVisible = true;
    final BuildContext rootContext = context;
    final double totalToday = ref
            .read(homeDashboardControllerProvider)
            .earningsToday
            ?.totalEarnings ??
        order.riderEarning;
    unawaited(
      showCompletionSummarySheet(
        rootContext,
        orderId: order.orderId,
        earnedAmount: order.riderEarning,
        customerName: order.customerAddress.name.isNotEmpty
            ? order.customerAddress.name
            : order.customerAddress.address,
        orderNumber: order.orderNumber,
        totalEarningsToday: totalToday,
      ).whenComplete(() {
        _summaryVisible = false;
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Map layer
// ---------------------------------------------------------------------------

class _MapLayer extends ConsumerWidget {
  const _MapLayer({
    required this.order,
    required this.mapController,
    required this.onMapReady,
    required this.onUserPan,
  });

  final DeliveryOrder order;
  final MapController mapController;
  final VoidCallback onMapReady;
  final VoidCallback onUserPan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ValueNotifier<GeoPoint?> rider =
        ref.read<ValueNotifier<GeoPoint?>>(riderLocationNotifierProvider);

    return ValueListenableBuilder<GeoPoint?>(
      valueListenable: rider,
      builder: (BuildContext context, GeoPoint? riderPos, _) {
        return _MapStateBuilder(
          order: order,
          riderPos: riderPos,
          mapController: mapController,
          onMapReady: onMapReady,
          onUserPan: onUserPan,
        );
      },
    );
  }
}

class _MapStateBuilder extends ConsumerWidget {
  const _MapStateBuilder({
    required this.order,
    required this.riderPos,
    required this.mapController,
    required this.onMapReady,
    required this.onUserPan,
  });

  final DeliveryOrder order;
  final GeoPoint? riderPos;
  final MapController mapController;
  final VoidCallback onMapReady;
  final VoidCallback onUserPan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ActiveDeliveryMapController map = ref
        .watch<ActiveDeliveryMapController>(activeDeliveryMapControllerProvider);
    final CachedTileProvider tileProvider =
        ref.watch<CachedTileProvider>(cachedTileProviderProvider);
    final Env env = ref.watch<Env>(envProvider);

    final GeoPoint seed = riderPos ?? map.storePosition ?? _defaultTarget;

    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: seed.toLatLng(),
        initialZoom: 14,
        minZoom: 3,
        maxZoom: 18,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.pinchZoom |
              InteractiveFlag.drag |
              InteractiveFlag.doubleTapZoom |
              InteractiveFlag.flingAnimation,
        ),
        onMapReady: onMapReady,
        onPositionChanged: (MapCamera camera, bool hasGesture) {
          if (hasGesture) {
            onUserPan();
          }
        },
      ),
      children: <Widget>[
        TileLayer(
          urlTemplate: env.tileUrlTemplate,
          userAgentPackageName: 'com.grolin.rider',
          tileProvider: tileProvider,
          maxNativeZoom: 18,
          maxZoom: 19,
        ),
        PolylineLayer(polylines: map.polylines),
        MarkerLayer(markers: map.markerWidgets),
        const RichAttributionWidget(
          alignment: AttributionAlignment.bottomLeft,
          attributions: <SourceAttribution>[
            TextSourceAttribution('OpenStreetMap contributors'),
          ],
        ),
      ],
    );
  }
}

const GeoPoint _defaultTarget = GeoPoint(12.9716, 77.5946);

// ---------------------------------------------------------------------------
// Top navigation bar (status + ETA card)
// ---------------------------------------------------------------------------

/// Combined top bar: phase status pill on the left, road-snapped
/// ETA / distance card on the right. Glass-morphism look:
/// translucent white surface, soft shadow, rounded corners.
class _NavTopBar extends ConsumerWidget {
  const _NavTopBar({required this.status});

  final AssignmentStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ActiveDeliveryMapController map = ref
        .watch<ActiveDeliveryMapController>(activeDeliveryMapControllerProvider);

    final (String label, Color dotColor) = switch (status) {
      AssignmentStatus.assigned => ('New offer', AppColors.warning),
      AssignmentStatus.accepted => ('Heading to store', AppColors.mapBlue),
      AssignmentStatus.inTransit => ('Heading to customer', AppColors.success),
      AssignmentStatus.delivered => ('Delivered', AppColors.success),
      AssignmentStatus.cancelled => ('Cancelled', AppColors.danger),
    };

    final double? meters = map.distanceMeters;
    final int? etaMin = map.etaMinutes;
    final String distanceLabel;
    if (meters == null) {
      distanceLabel = '—';
    } else if (meters < 1000) {
      distanceLabel = '${meters.round()} m';
    } else {
      distanceLabel = '${(meters / 1000).toStringAsFixed(1)} km';
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: _GlassCard(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.label
                        .copyWith(color: AppColors.charcoal),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (meters != null && etaMin != null)
          _GlassCard(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  Icons.directions_outlined,
                  size: 16,
                  color: AppColors.mapBlue,
                ),
                const SizedBox(width: 6),
                Text(
                  '$distanceLabel · ${etaMin}m',
                  style: AppTypography.label
                      .copyWith(color: AppColors.charcoal),
                ),
              ],
            ),
          ),
        const SizedBox(width: 8),
        _RefreshButton(
          onPressed: () => ref
              .read<DeliverySocketController>(deliverySocketControllerProvider)
              .refreshOrders(),
        ),
      ],
    );
  }
}

/// Manually re-syncs the batch against the server — a rider-visible
/// escape hatch for when an admin-side change (cancellation, status
/// update) hasn't yet reached this device live, so the order doesn't
/// stay stuck until the rider force-closes and reopens the app.
class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      customBorder: const CircleBorder(),
      child: _GlassCard(
        child: const Icon(Icons.refresh, size: 18, color: AppColors.charcoal),
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border, width: 0.5),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Stops strip — every in-transit batch order at once, ranked by
// distance (item 8/9: "map inside both order show, calculate which
// closest and which longest").
// ---------------------------------------------------------------------------

class _StopsStrip extends ConsumerWidget {
  const _StopsStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<DeliveryStopInfo> stops = ref
        .watch<ActiveDeliveryMapController>(activeDeliveryMapControllerProvider)
        .stops;
    // Nothing to compare when there's only one (or zero) stop — the
    // normal single-destination map/panel already covers that case.
    if (stops.length < 2) return const SizedBox.shrink();

    final List<DeliveryStopInfo> sorted = List<DeliveryStopInfo>.of(stops)
      ..sort((DeliveryStopInfo a, DeliveryStopInfo b) => a.rank.compareTo(b.rank));

    return SizedBox(
      height: 40,
      child: ListView.separated(
        // A fresh controller each build means this always renders from
        // scroll offset 0 — without it, Flutter's PageStorage restores
        // whatever offset this Scrollable last had (e.g. from an earlier
        // 3+ stop batch), clipping the closest stop's badge/prefix under
        // the left edge on the very first frame.
        controller: ScrollController(),
        scrollDirection: Axis.horizontal,
        itemCount: sorted.length,
        separatorBuilder: (BuildContext context, int index) => const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final DeliveryStopInfo stop = sorted[index];
          return _StopChip(
            stop: stop,
            onTap: stop.isFocused
                ? null
                : () => ref
                    .read<ActiveDeliveryController>(activeDeliveryControllerProvider)
                    .focusOrder(stop.order.orderId),
          );
        },
      ),
    );
  }
}

class _StopChip extends StatelessWidget {
  const _StopChip({required this.stop, required this.onTap});

  final DeliveryStopInfo stop;
  final VoidCallback? onTap;

  static String _distanceLabel(double? meters) {
    if (meters == null) return '';
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  @override
  Widget build(BuildContext context) {
    final String distance = _distanceLabel(stop.distanceMeters);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: _GlassCard(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 18,
                height: 18,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: stop.isFocused ? AppColors.black : AppColors.offWhite,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${stop.rank}',
                  style: AppTypography.micro.copyWith(
                    color: stop.isFocused ? AppColors.white : AppColors.charcoal,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                distance.isEmpty
                    ? '#${stop.order.orderNumber}'
                    : '#${stop.order.orderNumber} · $distance',
                style: AppTypography.micro.copyWith(color: AppColors.charcoal),
              ),
              if (stop.order.quickDeliverySelected) ...<Widget>[
                const SizedBox(width: 4),
                const Icon(Icons.flash_on, size: 12, color: AppColors.warning),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RecenterButton extends ConsumerWidget {
  const _RecenterButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: AppColors.white,
      shape: const CircleBorder(),
      elevation: 6,
      shadowColor: const Color(0x33000000),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: const SizedBox(
          width: 48,
          height: 48,
          child: Icon(Icons.my_location, color: AppColors.black, size: 22),
        ),
      ),
    );
  }
}

class _ActiveDeliveryGoneScreen extends StatelessWidget {
  const _ActiveDeliveryGoneScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.white,
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No active delivery',
            style: AppTypography.body,
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Fixed step-action panel (replaces DraggableScrollableSheet)
// ---------------------------------------------------------------------------

/// A fixed panel anchored to the bottom of the screen that shows the
/// current delivery step and the primary CTA for that step.
///
/// Layout (top → bottom inside the panel):
///   • Step progress bar — pill showing ACCEPTED → IN_TRANSIT → DELIVERED
///   • Order header  — order number + rider earning
///   • Phase body    — address card + action buttons for the current step
///   • Bottom safe-area inset
class _StepActionPanel extends StatelessWidget {
  const _StepActionPanel({required this.order});

  final DeliveryOrder order;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 20,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: 12),
          _StepProgressBar(status: order.assignmentStatus),
          _PanelHeader(order: order),
          _PhaseBody(order: order),
          SizedBox(
            height: MediaQuery.viewPaddingOf(context).bottom + 16,
          ),
        ],
      ),
    );
  }
}

/// Three-step progress pill: Pickup → Deliver → Done.
class _StepProgressBar extends StatelessWidget {
  const _StepProgressBar({required this.status});

  final AssignmentStatus status;

  @override
  Widget build(BuildContext context) {
    final bool pickupDone = status == AssignmentStatus.inTransit ||
        status == AssignmentStatus.delivered;
    final bool deliverDone = status == AssignmentStatus.delivered;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: <Widget>[
          _StepDot(
            active: true,
            done: pickupDone,
            label: 'Pickup',
          ),
          Expanded(child: _StepLine(active: pickupDone)),
          _StepDot(
            active: pickupDone,
            done: deliverDone,
            label: 'Deliver',
          ),
          Expanded(child: _StepLine(active: deliverDone)),
          _StepDot(
            active: deliverDone,
            done: deliverDone,
            label: 'Done',
          ),
        ],
      ),
    );
  }
}

class _StepDot extends StatelessWidget {
  const _StepDot({
    required this.active,
    required this.done,
    required this.label,
  });

  final bool active;
  final bool done;
  final String label;

  @override
  Widget build(BuildContext context) {
    final Color dotColor = done
        ? AppColors.success
        : active
            ? AppColors.black
            : AppColors.border;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
          ),
          child: done
              ? const Icon(Icons.check, size: 12, color: AppColors.white)
              : null,
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: AppTypography.micro.copyWith(
            color: active ? AppColors.charcoal : AppColors.muted,
            fontWeight:
                active ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ],
    );
  }
}

class _StepLine extends StatelessWidget {
  const _StepLine({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 2,
      margin: const EdgeInsets.only(bottom: 16),
      color: active ? AppColors.success : AppColors.border,
    );
  }
}

class _PanelHeader extends ConsumerWidget {
  const _PanelHeader({required this.order});

  final DeliveryOrder order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool commissionEnabled =
        ref.watch(riderProfileProvider).asData?.value.commissionEnabled ??
            true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '#${order.orderNumber}',
                  style: AppTypography.micro.copyWith(color: AppColors.muted),
                ),
                const SizedBox(height: 2),
                Text(
                  commissionEnabled
                      ? '₹${order.riderEarning.toStringAsFixed(0)}'
                      : 'In progress',
                  style:
                      AppTypography.title.copyWith(color: AppColors.black),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: AppColors.charcoal),
            tooltip: 'Back to home',
            onPressed: () => context.go(AppRoutes.home),
          ),
        ],
      ),
    );
  }
}


class _ApproximateLocationBanner extends StatelessWidget {
  const _ApproximateLocationBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.offWhite,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Customer location unavailable - cannot navigate',
              style: AppTypography.body.copyWith(color: AppColors.charcoal),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhaseBody extends ConsumerWidget {
  const _PhaseBody({required this.order});

  final DeliveryOrder order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool customerApprox = ref.watch<ActiveDeliveryMapController>(
      activeDeliveryMapControllerProvider,
    ).customerLocationApproximate;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (order.assignmentStatus == AssignmentStatus.inTransit &&
              customerApprox)
            const _ApproximateLocationBanner(),
          switch (order.assignmentStatus) {
            AssignmentStatus.assigned ||
            AssignmentStatus.accepted =>
              _AcceptedSheet(order: order),
            AssignmentStatus.inTransit => _InTransitSheet(order: order),
            AssignmentStatus.delivered => _DeliveredSheet(order: order),
            AssignmentStatus.cancelled => const SizedBox.shrink(),
          },
        ],
      ),
    );
  }
}

class _AcceptedSheet extends ConsumerWidget {
  const _AcceptedSheet({required this.order});

  final DeliveryOrder order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DeliveryAddress addr = order.storeAddress;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _AddressCard(tag: 'Pickup', title: addr.name, subtitle: addr.address),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              if (addr.phone != null && addr.phone!.isNotEmpty) ...<Widget>[
                Expanded(
                  child: AppButton(
                    label: 'Call store',
                    variant: AppButtonVariant.secondary,
                    leadingIcon: Icons.call_outlined,
                    onPressed: () => _onCall(ref, addr.phone!),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: AppButton(
                  label: 'Navigate',
                  variant: AppButtonVariant.secondary,
                  leadingIcon: Icons.navigation_outlined,
                  onPressed: addr.lat != null && addr.lng != null
                      ? () => _onNavigate(ref, addr.lat!, addr.lng!)
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          AppButton(
            label: 'Mark as picked up',
            onPressed: () => _onPickedUp(context),
          ),
        ],
      ),
    );
  }

  Future<void> _onNavigate(WidgetRef ref, double lat, double lng) async {
    final ExternalNavigationLauncher launcher =
        ref.read<ExternalNavigationLauncher>(externalNavLauncherProvider);
    await launcher.openDrivingDirections(destLat: lat, destLng: lng);
  }

  Future<void> _onCall(WidgetRef ref, String phone) async {
    final UrlLauncherDelegate launcher =
        ref.read<UrlLauncherDelegate>(urlLauncherDelegateProvider);
    final Uri uri = Uri(scheme: 'tel', path: phone);
    if (await launcher.canLaunch(uri)) {
      await launcher.launch(uri, mode: ul.LaunchMode.externalApplication);
    }
  }

  Future<void> _onPickedUp(BuildContext context) async {
    await showPickupSheet(context, order);
  }
}

class _InTransitSheet extends ConsumerWidget {
  const _InTransitSheet({required this.order});

  final DeliveryOrder order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DeliveryAddress addr = order.customerAddress;
    final bool showDemo = ref.watch<Env>(envProvider).enableDevAffordances;
    final List<DeliveryStopInfo> stops = ref
        .watch<ActiveDeliveryMapController>(activeDeliveryMapControllerProvider)
        .stops;
    final ActiveDeliveryController deliveryController =
        ref.watch<ActiveDeliveryController>(activeDeliveryControllerProvider);
    final bool isCod = order.paymentMethod.toUpperCase() == 'COD';
    final CollectedPayment? collected =
        deliveryController.collectedPaymentFor(order.orderId);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _AddressCard(
            tag: 'Drop',
            title: addr.name.isEmpty ? addr.address : addr.name,
            subtitle: addr.landmark != null && addr.landmark!.isNotEmpty
                ? '${addr.address} • ${addr.landmark}'
                : addr.address,
            paymentMethod: order.paymentMethod,
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              if (addr.phone != null && addr.phone!.isNotEmpty) ...<Widget>[
                Expanded(
                  child: AppButton(
                    label: 'Call customer',
                    variant: AppButtonVariant.secondary,
                    leadingIcon: Icons.call_outlined,
                    onPressed: () => _onCall(ref, addr.phone!),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: AppButton(
                  label: 'Navigate',
                  variant: AppButtonVariant.secondary,
                  leadingIcon: Icons.navigation_outlined,
                  onPressed: addr.lat != null && addr.lng != null
                      ? () => _onNavigate(ref, stops, addr.lat!, addr.lng!)
                      : null,
                ),
              ),
            ],
          ),
          if (isCod) ...<Widget>[
            const SizedBox(height: 8),
            AppButton(
              label: collected == null
                  ? 'Collect payment'
                  : 'Payment collected · Edit',
              variant: collected == null
                  ? AppButtonVariant.primary
                  : AppButtonVariant.secondary,
              leadingIcon: collected == null
                  ? Icons.qr_code_outlined
                  : Icons.check_circle_outline,
              onPressed: () => _onCollectPayment(context, ref),
            ),
          ],
          const SizedBox(height: 8),
          AppButton(
            label: 'Deliver',
            onPressed: (!isCod || collected != null)
                ? () => _onDeliver(context, collected, ref)
                : null,
          ),
          if (deliveryController.batch.length > 1) ...<Widget>[
            const SizedBox(height: 8),
            AppButton(
              label: 'Skip for now',
              variant: AppButtonVariant.secondary,
              leadingIcon: Icons.skip_next_outlined,
              onPressed: () => deliveryController.skip(order.orderId),
            ),
          ],
          if (showDemo) ...<Widget>[
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => _onDemoComplete(context, ref),
              child: Text(
                'Demo complete',
                style: AppTypography.label.copyWith(color: AppColors.muted),
              ),
            ),
          ],
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => _onCancelDelivery(context, ref),
            child: Text(
              'Cancel delivery',
              style: AppTypography.label.copyWith(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }

  /// Opens external navigation. When the rider has more than one stop
  /// left, hands Google Maps the *whole* planned route (item: "if user
  /// navigation press, that time also multi-order... routing system")
  /// instead of just this one destination — same sequence the map
  /// itself is already following ([ActiveDeliveryMapController.stops]).
  /// Falls back to a single-destination link for the common one-order
  /// trip, unchanged from before.
  Future<void> _onNavigate(
    WidgetRef ref,
    List<DeliveryStopInfo> stops,
    double lat,
    double lng,
  ) async {
    final ExternalNavigationLauncher launcher =
        ref.read<ExternalNavigationLauncher>(externalNavLauncherProvider);
    if (stops.length > 1) {
      final List<DeliveryStopInfo> sorted = List<DeliveryStopInfo>.of(stops)
        ..sort((DeliveryStopInfo a, DeliveryStopInfo b) => a.rank.compareTo(b.rank));
      await launcher.openMultiStopDirections(
        sorted.map((DeliveryStopInfo s) => s.position).toList(growable: false),
      );
      return;
    }
    await launcher.openDrivingDirections(destLat: lat, destLng: lng);
  }

  Future<void> _onCall(WidgetRef ref, String phone) async {
    final UrlLauncherDelegate launcher =
        ref.read<UrlLauncherDelegate>(urlLauncherDelegateProvider);
    final Uri uri = Uri(scheme: 'tel', path: phone);
    if (await launcher.canLaunch(uri)) {
      await launcher.launch(uri, mode: ul.LaunchMode.externalApplication);
    }
  }

  /// Opens the payment-collection sheet (UPI QR + cash/UPI amount entry)
  /// and records the result on [ActiveDeliveryController] so the "Deliver"
  /// button un-disables. Only reachable for COD orders — see the `isCod`
  /// gate in [build].
  Future<void> _onCollectPayment(BuildContext context, WidgetRef ref) async {
    final CollectedPayment? payment =
        await showCollectPaymentSheet(context, order);
    if (payment == null) return;
    ref
        .read<ActiveDeliveryController>(activeDeliveryControllerProvider)
        .recordCollectedPayment(order.orderId, payment);
  }

  Future<void> _onDeliver(
    BuildContext context,
    CollectedPayment? collected,
    WidgetRef ref,
  ) async {
    final ScaffoldMessengerState? messenger =
        ScaffoldMessenger.maybeOf(context);

    final DeliveryResult result = await ref
        .read<ActiveDeliveryController>(activeDeliveryControllerProvider)
        .deliverDirect(
          order.orderId,
          cashCollected: collected?.cashCollected,
          upiCollected: collected?.upiCollected,
        );
    switch (result) {
      case DeliveryResultSuccess():
        return;
      case DeliveryResultStale(message: final String message):
      case DeliveryResultFailure(message: final String message):
      case DeliveryResultInvalidOtp(message: final String message):
      case DeliveryResultOtpExpired(message: final String message):
      case DeliveryResultProofFailed(message: final String message):
        messenger?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _onDemoComplete(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState? messenger =
        ScaffoldMessenger.maybeOf(context);
    final Env env = ref.read<Env>(envProvider);
    final DeliveryOutcome outcome =
        await showDemoCompleteSheet(context, order, env: env);
    switch (outcome) {
      case DeliveryOutcomeDelivered():
      case DeliveryOutcomeCancelled():
        return;
      case DeliveryOutcomeFailed(message: final String message):
        messenger?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Cancels the delivery when the customer refuses the order or can't
  /// be reached at the drop location. Once the controller clears the
  /// active delivery, the screen-level watcher auto-redirects to home.
  Future<void> _onCancelDelivery(BuildContext context, WidgetRef ref) async {
    final CancelDeliveryReason? reason = await showCancelDeliverySheet(context);
    if (reason == null) return;
    if (!context.mounted) return;

    final ScaffoldMessengerState? messenger =
        ScaffoldMessenger.maybeOf(context);
    final ActiveDeliveryController controller =
        ref.read<ActiveDeliveryController>(activeDeliveryControllerProvider);
    final bool cancelled =
        await controller.cancelDelivery(order.orderId, reason.wire);
    if (!cancelled) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Could not cancel delivery. Try again')),
      );
    }
  }
}

class _DeliveredSheet extends ConsumerWidget {
  const _DeliveredSheet({required this.order});

  final DeliveryOrder order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool commissionEnabled =
        ref.watch(riderProfileProvider).asData?.value.commissionEnabled ??
            true;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.offWhite,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Delivered',
                  style:
                      AppTypography.heading.copyWith(color: AppColors.black),
                ),
                if (commissionEnabled) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    'You earned',
                    style:
                        AppTypography.micro.copyWith(color: AppColors.muted),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '₹${order.riderEarning.toStringAsFixed(0)}',
                    style: AppTypography.display
                        .copyWith(color: AppColors.black),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          AppButton(
            label: 'Back to home',
            onPressed: () {
              context.go(AppRoutes.home);
            },
          ),
        ],
      ),
    );
  }
}

class _AddressCard extends StatelessWidget {
  const _AddressCard({
    required this.tag,
    required this.title,
    required this.subtitle,
    this.paymentMethod,
  });

  final String tag;
  final String title;
  final String subtitle;

  /// Raw `payment_method` wire value (`COD`, `ONLINE`, `WALLET`, ...).
  /// When non-null, a small payment-status pill renders below the address.
  final String? paymentMethod;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.black,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              tag,
              style: AppTypography.micro.copyWith(color: AppColors.white),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: AppTypography.heading.copyWith(color: AppColors.charcoal),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: AppTypography.body.copyWith(color: AppColors.muted),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          if (paymentMethod != null && paymentMethod!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            _PaymentMethodPill(paymentMethod: paymentMethod!),
          ],
        ],
      ),
    );
  }
}

/// Small pill showing the order's payment method — amber for Cash on
/// Delivery (money still needs collecting), green for anything already
/// paid (`ONLINE`, `WALLET`).
class _PaymentMethodPill extends StatelessWidget {
  const _PaymentMethodPill({required this.paymentMethod});

  final String paymentMethod;

  @override
  Widget build(BuildContext context) {
    final String upper = paymentMethod.toUpperCase();
    final bool isCod = upper == 'COD';
    final String label = switch (upper) {
      'COD' => 'Cash on Delivery',
      'ONLINE' => 'Paid online',
      'WALLET' => 'Paid via wallet',
      _ => paymentMethod,
    };
    final Color color = isCod ? AppColors.warning : AppColors.success;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            isCod ? Icons.payments_outlined : Icons.check_circle_outline,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppTypography.micro.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

// `ll` is imported above; the screen does not directly construct
// `latlong2.LatLng` values, but the import keeps the link to the
// geometry layer explicit for future maintenance.
// ignore: unused_element
typedef _MapLatLng = ll.LatLng;
