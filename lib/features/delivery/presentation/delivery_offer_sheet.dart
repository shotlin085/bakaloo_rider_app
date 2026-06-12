import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/action_failure_watcher.dart';
import '../../../shared/widgets/app_bottom_sheet.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/diagnostic_expander.dart';
import '../application/offers_controller.dart';
import '../data/delivery_api.dart' show RejectReason;
import '../domain/delivery_order.dart';
import 'reject_reason_sheet.dart';

/// Outcome of [showDeliveryOfferSheet].
enum OfferSheetOutcome {
  /// Rider tapped Accept and the network call succeeded.
  accepted,

  /// Rider tapped Decline and chose a reason; the reject call has been
  /// dispatched.
  declined,

  /// Rider dismissed the sheet without acting (or accept/decline failed
  /// in a way that should leave the offer in the list).
  dismissed,
}

/// Result returned from [showDeliveryOfferSheet].
@immutable
class OfferSheetResult {
  /// Constructs a result explicitly.
  const OfferSheetResult(this.outcome, {this.message});

  /// Convenience: dismissed without action.
  const OfferSheetResult.dismissed()
      : outcome = OfferSheetOutcome.dismissed,
        message = null;

  /// What the rider did.
  final OfferSheetOutcome outcome;

  /// Optional user-facing message (e.g. "Order was already taken").
  final String? message;
}

/// Presents the new-offer bottom sheet for [order].
///
/// Layout (top to bottom):
/// - 4 dp drag handle.
/// - "New delivery offer" title.
/// - Big earning amount in [AppTypography.display].
/// - Distance + ETA chips.
/// - Store mini-card (name + address).
/// - Customer mini-card (area + landmark).
/// - Item-count badge.
/// - Payment-method tag.
/// - Primary black "Accept" full-width button.
/// - Secondary outlined "Decline" button.
///
/// Returns an [OfferSheetResult] describing what the rider did.
Future<OfferSheetResult> showDeliveryOfferSheet(
  BuildContext context,
  DeliveryOrder order,
) async {
  final OfferSheetResult? result = await showAppBottomSheet<OfferSheetResult>(
    context,
    initialChildSize: 0.48,
    builder: (BuildContext sheetContext) =>
        _DeliveryOfferSheetBody(order: order),
  );
  return result ?? const OfferSheetResult.dismissed();
}

class _DeliveryOfferSheetBody extends ConsumerStatefulWidget {
  const _DeliveryOfferSheetBody({required this.order});

  final DeliveryOrder order;

  @override
  ConsumerState<_DeliveryOfferSheetBody> createState() =>
      _DeliveryOfferSheetBodyState();
}

class _DeliveryOfferSheetBodyState
    extends ConsumerState<_DeliveryOfferSheetBody> {
  /// Tracks consecutive accept failures for R27.5.
  final ActionFailureWatcher _failureWatcher = ActionFailureWatcher();

  /// Whether to render the diagnostic expander below the CTA.
  bool _showDiagnostic = false;

  /// Rows shown inside the diagnostic expander (updated on each failure).
  List<MapEntry<String, String>> _diagnosticRows =
      const <MapEntry<String, String>>[];

  @override
  Widget build(BuildContext context) {
    final OffersController controller =
        ref.watch<OffersController>(offersControllerProvider);
    final bool busy = controller.isBusy(widget.order.orderId);
    final ScrollController? primary = PrimaryScrollController.maybeOf(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SheetHandle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Text(
            'New delivery offer',
            style: AppTypography.heading.copyWith(color: AppColors.charcoal),
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            controller: primary,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '₹${widget.order.riderEarning.toStringAsFixed(0)}',
                  style: AppTypography.display.copyWith(
                    color: AppColors.black,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Your earning',
                  style:
                      AppTypography.micro.copyWith(color: AppColors.muted),
                ),
                const SizedBox(height: 16),

                // Distance + ETA chips
                Row(
                  children: <Widget>[
                    _MetricChip(
                      icon: Icons.directions_bike_outlined,
                      label: widget.order.estimatedDistance != null
                          ? '${widget.order.estimatedDistance!.toStringAsFixed(1)} km'
                          : 'Distance N/A',
                    ),
                    const SizedBox(width: 8),
                    _MetricChip(
                      icon: Icons.timer_outlined,
                      label: '${widget.order.estimatedDuration} min',
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                _MiniCard(
                  icon: Icons.storefront_outlined,
                  title: widget.order.storeAddress.name,
                  subtitle: widget.order.storeAddress.address,
                  tag: 'Pickup',
                ),
                const SizedBox(height: 8),

                _MiniCard(
                  icon: Icons.location_on_outlined,
                  title: widget.order.customerAddress.address,
                  subtitle: widget.order.customerAddress.landmark ??
                      widget.order.customerAddress.name,
                  tag: 'Drop',
                ),
                const SizedBox(height: 16),

                Row(
                  children: <Widget>[
                    _Badge(
                      label:
                          '${widget.order.items.length} item${widget.order.items.length == 1 ? '' : 's'}',
                    ),
                    const SizedBox(width: 8),
                    _Badge(label: widget.order.paymentMethod),
                    const Spacer(),
                    Text(
                      '₹${widget.order.totalAmount.toStringAsFixed(0)}',
                      style: AppTypography.label
                          .copyWith(color: AppColors.charcoal),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                AppButton(
                  label: 'Accept',
                  isLoading: busy,
                  onPressed: busy ? null : () => _onAccept(context),
                ),
                const SizedBox(height: 12),
                AppButton(
                  label: 'Decline',
                  variant: AppButtonVariant.secondary,
                  onPressed: busy ? null : () => _onDecline(context),
                ),

                // R27.5: show diagnostic expander after 2+ failures within 10s.
                if (_showDiagnostic) ...<Widget>[
                  const SizedBox(height: 12),
                  DiagnosticExpander(
                    summary: 'Show error details',
                    rows: _diagnosticRows,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _onAccept(BuildContext context) async {
    final OffersController controller =
        ref.read<OffersController>(offersControllerProvider);
    final NavigatorState navigator = Navigator.of(context);
    final OfferActionResult result =
        await controller.acceptOffer(widget.order.orderId);
    if (!navigator.mounted) return;
    switch (result) {
      case OfferActionSuccess():
        // Reset failure counter on success.
        _failureWatcher.reset(widget.order.orderId);
        navigator.pop<OfferSheetResult>(
          const OfferSheetResult(OfferSheetOutcome.accepted),
        );
      case OfferAlreadyTaken(message: final String message):
        navigator.pop<OfferSheetResult>(
          OfferSheetResult(
            OfferSheetOutcome.dismissed,
            message: message,
          ),
        );
      case OfferActionFailure(message: final String message):
        _failureWatcher.record(widget.order.orderId, message);
        final bool showDiag = _failureWatcher.shouldShowDiagnostic(
          widget.order.orderId,
        );
        setState(() {
          _showDiagnostic = showDiag;
          _diagnosticRows = _failureWatcher.diagnosticRows(
            widget.order.orderId,
          );
        });
        ScaffoldMessenger.maybeOf(navigator.context)?.showSnackBar(
          SnackBar(content: Text(message)),
        );
    }
  }

  Future<void> _onDecline(BuildContext context) async {
    final RejectReason? reason = await showRejectReasonSheet(context);
    if (reason == null) return;
    if (!context.mounted) return;
    final OffersController controller =
        ref.read<OffersController>(offersControllerProvider);
    final NavigatorState navigator = Navigator.of(context);
    final OfferActionResult result =
        await controller.rejectOffer(widget.order.orderId, reason);
    if (!navigator.mounted) return;
    switch (result) {
      case OfferActionSuccess():
        navigator.pop<OfferSheetResult>(
          const OfferSheetResult(
            OfferSheetOutcome.declined,
            message: 'Order declined',
          ),
        );
      case OfferAlreadyTaken(message: final String message):
        navigator.pop<OfferSheetResult>(
          OfferSheetResult(
            OfferSheetOutcome.dismissed,
            message: message,
          ),
        );
      case OfferActionFailure(message: final String message):
        ScaffoldMessenger.maybeOf(navigator.context)?.showSnackBar(
          SnackBar(content: Text(message)),
        );
    }
  }
}

/// Standardised 4 dp top handle used inside the offer sheet. Mirrors
/// the handle drawn by [AppSheetScaffold] but inlined here so the
/// sheet can place it above a [Flexible] scroll region without
/// fighting the column's min-size constraint.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 8, bottom: 4),
      child: Center(
        child: SizedBox(
          width: 40,
          height: 4,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.all(Radius.circular(2)),
            ),
          ),
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.offWhite,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 16, color: AppColors.charcoal),
          const SizedBox(width: 6),
          Text(
            label,
            style: AppTypography.label.copyWith(color: AppColors.charcoal),
          ),
        ],
      ),
    );
  }
}

class _MiniCard extends StatelessWidget {
  const _MiniCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tag,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String tag;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20, color: AppColors.charcoal),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.black,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        tag,
                        style: AppTypography.micro
                            .copyWith(color: AppColors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  title,
                  style: AppTypography.body
                      .copyWith(color: AppColors.charcoal),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: AppTypography.micro.copyWith(color: AppColors.muted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.offWhite,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: AppTypography.micro.copyWith(color: AppColors.charcoal),
      ),
    );
  }
}
