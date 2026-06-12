import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../../core/providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/action_failure_watcher.dart';
import '../../../core/utils/external_nav_launcher.dart';
import '../../../shared/widgets/app_bottom_sheet.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/diagnostic_expander.dart';
import '../../home/application/home_dashboard_controller.dart';
import '../application/active_delivery_controller.dart';
import '../domain/delivery_item.dart';
import '../domain/delivery_order.dart';

/// Presents the pickup-at-store bottom sheet for [order] (R13).
///
/// Layout (top → bottom):
/// - Drag handle (rendered by [AppSheetScaffold]).
/// - "Picking up" title row.
/// - Store name + address card.
/// - "Call store" button using `tel:` URI.
/// - Items list (each row formatted as `quantity × name`, e.g.
///   "2 × Bread").
/// - 3-toggle checklist (R13.2): "Reached store",
///   "Collected packed order", "Matched item count".
/// - "Mark as picked up" primary button — disabled until all three
///   toggles are on.
///
/// Returns `true` when the pickup REST call succeeded and the
/// assignment transitioned `ACCEPTED -> IN_TRANSIT`. Returns `false`
/// when the rider dismissed the sheet without confirming, or when the
/// action failed (the failure UI is rendered inside the sheet via
/// snackbar before it pops).
///
/// On `ORDER_NOT_AVAILABLE` / `ApiConflictException`: surfaces the
/// snack "Order is no longer in the right state. Refreshing", refetches
/// `/delivery/orders` (R13.5), and dismisses with `false`.
Future<bool> showPickupSheet(BuildContext context, DeliveryOrder order) async {
  final bool? result = await showAppBottomSheet<bool>(
    context,
    initialChildSize: 0.82,
    builder: (BuildContext sheetContext) => _PickupSheetBody(order: order),
  );
  return result ?? false;
}

class _PickupSheetBody extends ConsumerStatefulWidget {
  const _PickupSheetBody({required this.order});

  final DeliveryOrder order;

  @override
  ConsumerState<_PickupSheetBody> createState() => _PickupSheetBodyState();
}

class _PickupSheetBodyState extends ConsumerState<_PickupSheetBody> {
  bool _reached = false;
  bool _collected = false;
  bool _matched = false;

  bool get _allChecked => _reached && _collected && _matched;

  /// Tracks consecutive pickup failures for R27.5.
  final ActionFailureWatcher _failureWatcher = ActionFailureWatcher();

  /// Whether to render the diagnostic expander below the CTA.
  bool _showDiagnostic = false;

  /// Rows shown inside the diagnostic expander.
  List<MapEntry<String, String>> _diagnosticRows =
      const <MapEntry<String, String>>[];

  Future<void> _onConfirm() async {
    final ActiveDeliveryController controller =
        ref.read<ActiveDeliveryController>(activeDeliveryControllerProvider);
    final NavigatorState navigator = Navigator.of(context);
    final ScaffoldMessengerState? messenger =
        ScaffoldMessenger.maybeOf(context);

    final DeliveryResult result =
        await controller.markPickedUp(widget.order.orderId);

    if (!navigator.mounted) return;
    switch (result) {
      case DeliveryResultSuccess():
        // Reset failure counter on success.
        _failureWatcher.reset(widget.order.orderId);
        navigator.pop<bool>(true);
      case DeliveryResultStale(message: final String message):
        // R13.5: re-fetch /delivery/orders so the dashboard reconciles.
        unawaited(
          ref
              .read<HomeDashboardController>(homeDashboardControllerProvider)
              .refreshOrders(),
        );
        if (!navigator.mounted) return;
        messenger?.showSnackBar(SnackBar(content: Text(message)));
        navigator.pop<bool>(false);
      case DeliveryResultFailure(message: final String message):
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
        messenger?.showSnackBar(SnackBar(content: Text(message)));
      case DeliveryResultInvalidOtp():
      case DeliveryResultOtpExpired():
      case DeliveryResultProofFailed():
        // Not produced by markPickedUp; treat as generic failure.
        messenger?.showSnackBar(
          const SnackBar(content: Text('Could not mark as picked up')),
        );
    }
  }

  Future<void> _onCallStore() async {
    final String? phone = widget.order.storeAddress.phone;
    if (phone == null || phone.isEmpty) return;
    final UrlLauncherDelegate launcher =
        ref.read<UrlLauncherDelegate>(urlLauncherDelegateProvider);
    final Uri uri = Uri(scheme: 'tel', path: phone);
    if (await launcher.canLaunch(uri)) {
      await launcher.launch(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ScrollController? primary = PrimaryScrollController.maybeOf(context);
    final ActiveDeliveryController controller =
        ref.watch<ActiveDeliveryController>(activeDeliveryControllerProvider);
    final bool busy = controller.isBusy;
    final String? phone = widget.order.storeAddress.phone;
    final bool hasPhone = phone != null && phone.isNotEmpty;

    return AppSheetScaffold(
      title: 'Picking up',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Store info card.
          _StoreCard(order: widget.order),
          const SizedBox(height: 12),

          // Call store button (R13.1 — store phone is part of the
          // pickup-sheet contract).
          AppButton(
            label: 'Call store',
            variant: AppButtonVariant.secondary,
            leadingIcon: Icons.call_outlined,
            onPressed: hasPhone && !busy ? _onCallStore : null,
          ),
          const SizedBox(height: 16),

          // Item list header.
          Row(
            children: <Widget>[
              Text(
                'Items',
                style:
                    AppTypography.label.copyWith(color: AppColors.charcoal),
              ),
              const SizedBox(width: 8),
              _CountBadge(count: widget.order.items.length),
            ],
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: SingleChildScrollView(
              controller: primary,
              physics: const BouncingScrollPhysics(),
              child: Column(
                children: <Widget>[
                  for (final DeliveryItem item in widget.order.items)
                    _ItemRow(item: item),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Checklist toggles (R13.2).
          _ChecklistTile(
            label: 'Reached store',
            value: _reached,
            onChanged: busy
                ? null
                : (bool v) => setState(() => _reached = v),
          ),
          _ChecklistTile(
            label: 'Collected packed order',
            value: _collected,
            onChanged: busy
                ? null
                : (bool v) => setState(() => _collected = v),
          ),
          _ChecklistTile(
            label: 'Matched item count',
            value: _matched,
            onChanged: busy
                ? null
                : (bool v) => setState(() => _matched = v),
          ),
          const SizedBox(height: 16),

          AppButton(
            label: 'Mark as picked up',
            isLoading: busy,
            onPressed:
                _allChecked && !busy ? _onConfirm : null,
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
    );
  }
}

class _StoreCard extends StatelessWidget {
  const _StoreCard({required this.order});

  final DeliveryOrder order;

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
          const Icon(
            Icons.storefront_outlined,
            size: 20,
            color: AppColors.charcoal,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  order.storeAddress.name,
                  style: AppTypography.body
                      .copyWith(color: AppColors.charcoal),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  order.storeAddress.address,
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

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.offWhite,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$count',
        style: AppTypography.micro.copyWith(color: AppColors.charcoal),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});

  final DeliveryItem item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            // "2 × Bread" format per the task spec.
            child: Text(
              '${item.quantity} × ${item.name}',
              style:
                  AppTypography.body.copyWith(color: AppColors.charcoal),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChecklistTile extends StatelessWidget {
  const _ChecklistTile({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: AppTypography.body.copyWith(
                  color: AppColors.charcoal,
                ),
              ),
            ),
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeThumbColor: AppColors.white,
              activeTrackColor: AppColors.black,
              inactiveTrackColor: AppColors.border,
            ),
          ],
        ),
      ),
    );
  }
}
