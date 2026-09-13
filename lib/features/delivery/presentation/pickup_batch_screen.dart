import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/location/rider_location_provider.dart';
import '../../../core/maps/geo_point.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/app_logger.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/error_state.dart';
import '../../../shared/widgets/skeleton_loader.dart';
import '../../../shared/widgets/status_chip.dart';
import '../application/active_delivery_controller.dart';
import '../application/pickup_session_controller.dart';
import '../data/delivery_repository.dart';
import '../domain/assignment_status.dart';
import '../domain/delivery_order.dart';
import '../domain/pickup_batch.dart';
import 'pickup_checklist_sheet.dart';

/// The rider's pickup-at-store overview (item 6): "X of Y collected"
/// progress, one row per assigned order with its scan status, a "Scan
/// Order" action opening [QrScanScreen], and "Start Deliveries" once at
/// least one order has been picked up.
class PickupBatchScreen extends ConsumerStatefulWidget {
  /// Const constructor.
  const PickupBatchScreen({super.key});

  @override
  ConsumerState<PickupBatchScreen> createState() => _PickupBatchScreenState();
}

class _PickupBatchScreenState extends ConsumerState<PickupBatchScreen> {
  bool _loading = true;
  String? _error;
  // TEMP DIAGNOSTIC — remove once the stuck-order investigation is closed.
  String _debugInfo = '(no refresh yet)';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_refresh()));
  }

  /// Pulls the rider's current orders straight from the backend so the
  /// batch is fresh the moment this screen opens, independent of
  /// whatever the background socket reconciliation has caught up to yet.
  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final StringBuffer dbg = StringBuffer();
    dbg.writeln('refresh @ ${DateTime.now().toIso8601String()}');
    try {
      final DeliveryRepository repository = ref.read(deliveryRepositoryProvider);
      final List<DeliveryOrder> orders = await repository.getOrders();
      dbg.writeln('fetched: ${orders.length} -> ${orders.map((o) => '${o.orderId.substring(0, 8)}:${o.assignmentStatus}').join(', ')}');
      final ActiveDeliveryController active = ref.read(activeDeliveryControllerProvider);
      dbg.writeln('batch BEFORE: ${active.batch.length} -> ${active.batch.map((o) => o.orderId.substring(0, 8)).join(', ')}');
      final Set<String> freshIds = <String>{};
      for (final DeliveryOrder order in orders) {
        if (order.assignmentStatus == AssignmentStatus.accepted ||
            order.assignmentStatus == AssignmentStatus.inTransit) {
          active.addOrUpdate(order);
          freshIds.add(order.orderId);
        }
      }
      // /delivery/orders only lists orders still open for this rider — a
      // cancelled/delivered order simply stops appearing in it. The loop
      // above only ever adds/updates, so without this, an order that went
      // terminal (e.g. an admin dashboard action) while this screen
      // already had it loaded stays here forever — pull-to-refresh
      // included, since it re-runs this same loop. This is the screen
      // the rider is looking at during pickup, so it's the one place a
      // stuck "NEEDS SCAN" card was actually being seen.
      int pruned = 0;
      for (final DeliveryOrder order in active.batch.toList()) {
        if (!freshIds.contains(order.orderId)) {
          active.remove(order.orderId);
          pruned++;
        }
      }
      dbg.writeln('pruned: $pruned, batch AFTER: ${active.batch.length}');
      final PickupSessionController session = ref.read(pickupSessionControllerProvider);
      session.syncFromBatch(active.batch);
      await _reconcilePendingScans(active.batch, session, repository);
      dbg.writeln('batch FINAL: ${active.batch.length}');
    } catch (e, stack) {
      dbg.writeln('EXCEPTION: $e');
      AppLogger.warn(LogTopic.delivery, 'Pickup batch refresh failed', error: e, stackTrace: stack);
      if (mounted) setState(() => _error = 'Could not load your orders. Pull to retry.');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _debugInfo = dbg.toString();
        });
      }
    }
  }

  /// After a killed/restarted app (or a second device), [PickupSessionController]'s
  /// local tracking has no memory of a scan that already succeeded
  /// server-side — [PickupSessionController.syncFromBatch] can only infer
  /// "needs scan" vs. "picked up" from `assignmentStatus`, which stays
  /// `ACCEPTED` for both "never scanned" and "scanned but not yet
  /// confirmed." This checks each apparently-unscanned order against the
  /// backend once so a genuinely-pending confirmation surfaces as
  /// "Verified — tap to confirm" instead of a misleading "Needs scan"
  /// that would just get rejected as ALREADY_VERIFIED on rescan.
  Future<void> _reconcilePendingScans(
    List<DeliveryOrder> batch,
    PickupSessionController session,
    DeliveryRepository repository,
  ) async {
    final List<DeliveryOrder> candidates = batch
        .where((DeliveryOrder o) => session.statusFor(o.orderId) == PickupScanStatus.needsScan)
        .toList(growable: false);
    for (final DeliveryOrder order in candidates) {
      try {
        final PickupVerification verification =
            await repository.getPendingChecklist(order.orderId);
        session.markVerified(order.orderId, verification);
      } on ApiException catch (e, stack) {
        if (e.backendCode != 'NO_PENDING_CHECKLIST') {
          AppLogger.warn(
            LogTopic.delivery,
            'Pending-checklist reconciliation failed for ${order.orderId}',
            error: e,
            stackTrace: stack,
          );
        }
        // Genuinely never scanned (or another unexpected error) — leave
        // it as needsScan rather than failing the whole refresh over one
        // order's reconciliation check.
      }
    }
  }

  void _scanNext() {
    unawaited(context.push(AppRoutes.qrScan));
  }

  /// Reopens the checklist for an already-[PickupScanStatus.verified]
  /// order — the recovery path for when the checklist sheet closed
  /// (system back-gesture, accidental tap, app backgrounded mid-review)
  /// before the rider pressed "Confirm Pickup". Without this, a verified
  /// order with no confirmed pickup was a dead end: nothing to scan
  /// (already verified), and "Start Deliveries" stays disabled forever
  /// since it requires at least one order actually picked up.
  Future<void> _reviewChecklist(DeliveryOrder order) async {
    final PickupSessionController session = ref.read(pickupSessionControllerProvider);
    PickupVerification? verification = session.verificationFor(order.orderId);
    if (verification == null) {
      // Local cache lost (app restarted between scan and confirm, or a
      // second device) — re-fetch from the backend rather than assuming
      // it needs a rescan.
      try {
        final DeliveryRepository repository = ref.read(deliveryRepositoryProvider);
        verification = await repository.getPendingChecklist(order.orderId);
        session.markVerified(order.orderId, verification);
      } on ApiException {
        // Nothing pending server-side either — only remaining option is
        // a fresh scan.
        _scanNext();
        return;
      }
    }
    if (!mounted) return;
    await showPickupChecklistSheet(context, order.orderId, verification);
  }

  void _startDeliveries() {
    final ActiveDeliveryController active = ref.read(activeDeliveryControllerProvider);
    final PickupSessionController session = ref.read(pickupSessionControllerProvider);

    // Focus the first stop of the real nearest-neighbor route (item
    // 8/9): Express orders before standard/scheduled ones, then
    // whichever is actually closest to the rider right now — not just
    // whichever happens to be first in the batch.
    final GeoPoint? riderPosition =
        ref.read<ValueNotifier<GeoPoint?>>(riderLocationNotifierProvider).value;
    final List<DeliveryOrder> readyToDeliver = active.batch
        .where((DeliveryOrder o) => o.assignmentStatus == AssignmentStatus.inTransit)
        .toList();
    final List<DeliveryOrder> sequenced =
        DeliveryOrder.sequenceRoute(readyToDeliver, riderPosition);
    if (sequenced.isNotEmpty) {
      active.focusOrder(sequenced.first.orderId);
    }
    session.reset();
    context.go(AppRoutes.active);
  }

  @override
  Widget build(BuildContext context) {
    final ActiveDeliveryController active = ref.watch(activeDeliveryControllerProvider);
    final PickupSessionController session = ref.watch(pickupSessionControllerProvider);
    final List<DeliveryOrder> batch = active.batch;
    final int pickedUp =
        batch.where((DeliveryOrder o) => o.assignmentStatus == AssignmentStatus.inTransit).length;
    final bool canStartDeliveries = pickedUp > 0;

    return Scaffold(
      backgroundColor: AppColors.offWhite,
      appBar: AppBar(
        backgroundColor: AppColors.white,
        elevation: 0,
        title: Text(
          batch.isEmpty ? 'Pickup' : '$pickedUp of ${batch.length} collected',
          style: AppTypography.heading.copyWith(color: AppColors.charcoal),
        ),
      ),
      body: Column(
        children: <Widget>[
          // TEMP DIAGNOSTIC — remove once the stuck-order investigation
          // is closed.
          Container(
            width: double.infinity,
            color: Colors.yellow.shade100,
            padding: const EdgeInsets.all(8),
            child: Text(
              _debugInfo,
              style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: _buildBody(batch, session),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: <Widget>[
              Expanded(
                child: AppButton(
                  label: 'Scan Order',
                  variant: AppButtonVariant.secondary,
                  leadingIcon: Icons.qr_code_scanner,
                  onPressed: _scanNext,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AppButton(
                  label: 'Start Deliveries',
                  onPressed: canStartDeliveries ? _startDeliveries : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(List<DeliveryOrder> batch, PickupSessionController session) {
    if (_loading && batch.isEmpty) {
      return ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: 3,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, _) => Skeleton.box(height: 88),
      );
    }
    if (_error != null && batch.isEmpty) {
      return ErrorState(title: 'Could not load orders', body: _error, onRetry: _refresh);
    }
    if (batch.isEmpty) {
      return const EmptyState(
        icon: Icons.inventory_2_outlined,
        title: 'No orders to pick up',
        body: 'New assignments will appear here automatically.',
      );
    }
    // Displayed in delivery-priority order (item 8/9) — Express first,
    // then earliest promised/placed time within a tier — so the list the
    // rider sees while scanning already reads as their eventual route,
    // not just pickup/scan order.
    final List<DeliveryOrder> sorted = List<DeliveryOrder>.of(batch)
      ..sort(DeliveryOrder.compareDeliveryPriority);
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: sorted.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) {
        final DeliveryOrder order = sorted[index];
        return _BatchOrderRow(
          stopNumber: index + 1,
          order: order,
          status: session.statusFor(order.orderId),
          onScan: _scanNext,
          onReviewChecklist: () => unawaited(_reviewChecklist(order)),
        );
      },
    );
  }
}

class _BatchOrderRow extends StatelessWidget {
  const _BatchOrderRow({
    required this.stopNumber,
    required this.order,
    required this.status,
    required this.onScan,
    required this.onReviewChecklist,
  });

  /// This order's position in delivery-priority order (item 8/9) — shown
  /// as a plain "Stop N" marker so the rider sees the sequence, not just
  /// a flat list.
  final int stopNumber;

  final DeliveryOrder order;
  final PickupScanStatus status;
  final VoidCallback onScan;

  /// Reopens the checklist for a [PickupScanStatus.verified] row — the
  /// only status that's scanned-but-not-yet-confirmed, and therefore the
  /// only one that needs a way back into the checklist.
  final VoidCallback onReviewChecklist;

  (String, StatusTone) _statusVisual() {
    switch (status) {
      case PickupScanStatus.needsScan:
        return ('Needs scan', StatusTone.pending);
      case PickupScanStatus.verified:
        return ('Verified — tap to confirm', StatusTone.info);
      case PickupScanStatus.pickedUp:
        return ('Picked up', StatusTone.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (String label, StatusTone tone) = _statusVisual();
    final bool reviewable = status == PickupScanStatus.verified;

    final Widget card = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: reviewable ? AppColors.mapBlue : AppColors.border,
        ),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: AppColors.offWhite,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$stopNumber',
              style: AppTypography.micro.copyWith(
                color: AppColors.charcoal,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        '#${order.orderNumber}',
                        style: AppTypography.label.copyWith(color: AppColors.charcoal),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (order.quickDeliverySelected) ...<Widget>[
                      const SizedBox(width: 6),
                      const StatusChip(label: 'Express', tone: StatusTone.pending, showDot: false),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  order.customerAddress.address,
                  style: AppTypography.body.copyWith(color: AppColors.muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          StatusChip(label: label, tone: tone),
          if (status == PickupScanStatus.needsScan) ...<Widget>[
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.qr_code_scanner, color: AppColors.charcoal),
              onPressed: onScan,
            ),
          ],
          if (reviewable) ...<Widget>[
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: AppColors.mapBlue),
          ],
        ],
      ),
    );

    if (!reviewable) return card;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onReviewChecklist,
        child: card,
      ),
    );
  }
}
