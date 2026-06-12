import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router.dart';
import '../../../core/location/location_display_provider.dart';
import '../../../core/location/location_lifecycle_manager.dart';
import '../../../core/maps/geo_point.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/error_state.dart';
import '../../../shared/widgets/skeleton_loader.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../delivery/application/active_delivery_controller.dart';
import '../../delivery/application/offers_controller.dart';
import '../../delivery/domain/assignment_status.dart';
import '../../delivery/domain/delivery_order.dart';
import '../../delivery/domain/rider_earnings.dart';
import '../../delivery/domain/rider_profile.dart';
import '../../delivery/domain/rider_stats.dart';
import '../../delivery/presentation/delivery_offer_sheet.dart';
import '../application/home_dashboard_controller.dart';
import '../application/online_toggle_controller.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static final NumberFormat _money = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );

  final Set<String> _shownOfferIds = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_ensureLocationIfOnline());
    });
  }

  Future<void> _ensureLocationIfOnline() async {
    if (!mounted) return;
    await ref
        .read<HomeDashboardController>(homeDashboardControllerProvider)
        .refresh();
    if (!mounted) return;
    final RiderProfile? profile =
        ref.read<HomeDashboardController>(homeDashboardControllerProvider).profile;
    final bool isOnline = profile?.isOnline ?? false;
    await ref
        .read<LocationLifecycleManager>(locationLifecycleManagerProvider)
        .ensureRunningIfOnline(isOnline: isOnline);
  }

  Future<void> _handleToggle({required bool goOnline}) async {
    final OnlineToggleController toggle =
        ref.read<OnlineToggleController>(onlineToggleControllerProvider);
    final LocationLifecycleManager locationManager =
        ref.read<LocationLifecycleManager>(locationLifecycleManagerProvider);

    if (goOnline) {
      await toggle.goOnline();
    } else {
      await toggle.goOffline();
    }
    if (!mounted) return;

    final OnlineToggleState s = toggle.state;
    if (s.routeToApproval) {
      toggle.clearTransientFlags();
      context.go(AppRoutes.approval);
      return;
    }
    if (s.serviceDisabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Turn on location services to go online')),
      );
      toggle.clearTransientFlags();
      return;
    }
    if (s.permissionEducationNeeded) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Location permission is required to go online'),
        ),
      );
      toggle.clearTransientFlags();
      return;
    }
    if (s.errorMessage != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.errorMessage!)));
      toggle.clearTransientFlags();
      return;
    }

    if (s.isOnline) {
      unawaited(locationManager.onWentOnline());
    } else {
      unawaited(locationManager.onWentOffline());
    }

    unawaited(
      ref
          .read<HomeDashboardController>(homeDashboardControllerProvider)
          .refresh(),
    );
  }

  Future<void> _autoPresentOfferIfNeeded(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final OffersController offers =
        ref.read<OffersController>(offersControllerProvider);
    final ActiveDeliveryController active =
        ref.read<ActiveDeliveryController>(activeDeliveryControllerProvider);
    if (active.current != null) return;
    for (final DeliveryOrder offer in offers.offers) {
      if (_shownOfferIds.contains(offer.orderId)) continue;
      _shownOfferIds.add(offer.orderId);
      unawaited(showDeliveryOfferSheet(context, offer));
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final HomeDashboardController dashboard =
        ref.watch<HomeDashboardController>(homeDashboardControllerProvider);
    final OnlineToggleController toggle =
        ref.watch<OnlineToggleController>(onlineToggleControllerProvider);
    final OffersController offers =
        ref.watch<OffersController>(offersControllerProvider);
    final ActiveDeliveryController active =
        ref.watch<ActiveDeliveryController>(activeDeliveryControllerProvider);
    final LocationDisplay? locationDisplay =
        ref.watch(locationDisplayProvider).value;

    final RiderProfile? profile = dashboard.profile;
    if (profile != null && profile.isApproved) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read<OnlineToggleController>(onlineToggleControllerProvider)
            .syncFromProfile(isOnline: profile.isOnline);
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_autoPresentOfferIfNeeded(context, ref));
    });

    final DeliveryOrder? activeOrder = active.current;

    return Scaffold(
      backgroundColor: AppColors.offWhite,
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.black,
          onRefresh: () => dashboard.refresh(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
            children: <Widget>[
              // ── Greeting ──────────────────────────────────────────────
              _Greeting(
                profile: profile,
                profileLoading: dashboard.profileLoading,
              ),
              const SizedBox(height: 16),

              // ── Online hero card ───────────────────────────────────────
              _OnlineStatusCard(
                profile: profile,
                profileLoading: dashboard.profileLoading,
                toggleState: toggle.state,
                locationDisplay: locationDisplay,
                onToggle: (bool wantOnline) =>
                    _handleToggle(goOnline: wantOnline),
              ),
              const SizedBox(height: 16),

              // ── Active delivery banner ─────────────────────────────────
              if (activeOrder != null) ...<Widget>[
                _ActiveDeliveryCard(order: activeOrder),
                const SizedBox(height: 16),
              ],

              // ── Stats row ─────────────────────────────────────────────
              _StatsRow(
                stats: dashboard.stats,
                earningsToday: dashboard.earningsToday,
                profile: profile,
                statsLoading: dashboard.statsLoading,
                statsError: dashboard.statsError,
                earningsLoading: dashboard.earningsLoading,
                earningsError: dashboard.earningsError,
                onRetry: () => unawaited(dashboard.refresh()),
              ),
              const SizedBox(height: 16),

              // ── Offers / empty state ───────────────────────────────────
              _OffersSection(
                offers: offers.offers,
                ordersLoading: dashboard.ordersLoading,
                ordersError: dashboard.ordersError,
                isOnline: toggle.state.isOnline,
                onRetry: () => unawaited(dashboard.refresh()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String formatRupees(double value) => _money.format(value);
}

// ─────────────────────────────────────────────────────────────────────────────
// Greeting
// ─────────────────────────────────────────────────────────────────────────────

class _Greeting extends StatelessWidget {
  const _Greeting({required this.profile, required this.profileLoading});

  final RiderProfile? profile;
  final bool profileLoading;

  @override
  Widget build(BuildContext context) {
    if (profileLoading && profile == null) {
      return Skeleton.line(height: 28, width: 200);
    }
    final String name = (profile?.name?.isNotEmpty ?? false)
        ? profile!.name!.split(' ').first
        : 'Rider';
    return Text(
      'Hi $name 👋',
      style: AppTypography.title.copyWith(color: AppColors.charcoal),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Online status hero card
// ─────────────────────────────────────────────────────────────────────────────

class _OnlineStatusCard extends StatelessWidget {
  const _OnlineStatusCard({
    required this.profile,
    required this.profileLoading,
    required this.toggleState,
    required this.locationDisplay,
    required this.onToggle,
  });

  final RiderProfile? profile;
  final bool profileLoading;
  final OnlineToggleState toggleState;
  final LocationDisplay? locationDisplay;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    if (profileLoading && profile == null) {
      return Skeleton.box(height: 160, radius: 20);
    }

    final bool isOnline = toggleState.isOnline;
    final bool busy = toggleState.isBusy;

    return AnimatedContainer(
      duration: AppMotion.normal,
      curve: AppMotion.easing,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isOnline ? AppColors.black : AppColors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isOnline ? AppColors.black : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // Status chip + spinner
          Row(
            children: <Widget>[
              StatusChip(
                label: isOnline ? 'ONLINE' : 'OFFLINE',
                tone: isOnline ? StatusTone.online : StatusTone.offline,
              ),
              const Spacer(),
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppColors.muted),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),

          // Status description
          Text(
            isOnline
                ? 'You are online. Looking for nearby orders.'
                : 'You are offline. Tap below to start receiving orders.',
            style: AppTypography.body.copyWith(
              color: isOnline ? AppColors.white : AppColors.charcoal,
            ),
          ),
          const SizedBox(height: 14),

          // Toggle button
          AppButton(
            label: isOnline ? 'Go offline' : 'Go online',
            isLoading: busy,
            variant: isOnline
                ? AppButtonVariant.secondary
                : AppButtonVariant.success,
            onPressed: busy ? null : () => onToggle(!isOnline),
          ),

          // ── Location row ──────────────────────────────────────────────
          if (locationDisplay != null) ...<Widget>[
            const SizedBox(height: 14),
            _LocationRow(
              display: locationDisplay!,
              isOnline: isOnline,
            ),
          ],
        ],
      ),
    );
  }
}

/// Compact location row shown inside the online card.
class _LocationRow extends StatelessWidget {
  const _LocationRow({required this.display, required this.isOnline});

  final LocationDisplay display;
  final bool isOnline;

  @override
  Widget build(BuildContext context) {
    final Color iconColor =
        isOnline ? AppColors.white.withValues(alpha: 0.55) : AppColors.muted;
    final Color nameColor =
        isOnline ? AppColors.white.withValues(alpha: 0.9) : AppColors.charcoal;
    final Color coordColor =
        isOnline ? AppColors.white.withValues(alpha: 0.5) : AppColors.muted;

    final GeoPoint pos = display.position;
    final String latLng =
        '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.location_on_outlined, size: 14, color: iconColor),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (display.areaName != null)
                Text(
                  display.areaName!,
                  style: AppTypography.label.copyWith(color: nameColor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              Text(
                latLng,
                style: AppTypography.micro.copyWith(color: coordColor),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Active delivery banner
// ─────────────────────────────────────────────────────────────────────────────

class _ActiveDeliveryCard extends StatelessWidget {
  const _ActiveDeliveryCard({required this.order});

  final DeliveryOrder order;

  @override
  Widget build(BuildContext context) {
    final bool inTransit =
        order.assignmentStatus == AssignmentStatus.inTransit;
    final String label = inTransit ? 'IN TRANSIT' : 'TO STORE';
    final StatusTone tone =
        inTransit ? StatusTone.info : StatusTone.pending;

    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => context.push(AppRoutes.active),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.offWhite,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.delivery_dining,
                  size: 24,
                  color: AppColors.charcoal,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Active delivery',
                      style: AppTypography.label
                          .copyWith(color: AppColors.charcoal),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '#${order.orderNumber}',
                      style: AppTypography.micro
                          .copyWith(color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              StatusChip(label: label, tone: tone),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right,
                  size: 20, color: AppColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stats row — redesigned to prevent truncation
// ─────────────────────────────────────────────────────────────────────────────

class _StatsRow extends StatelessWidget {
  const _StatsRow({
    required this.stats,
    required this.earningsToday,
    required this.profile,
    required this.statsLoading,
    required this.statsError,
    required this.earningsLoading,
    required this.earningsError,
    required this.onRetry,
  });

  final RiderStats? stats;
  final RiderEarnings? earningsToday;
  final RiderProfile? profile;
  final bool statsLoading;
  final String? statsError;
  final bool earningsLoading;
  final String? earningsError;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (statsError != null && earningsError != null && stats == null) {
      return ErrorState(
        title: 'Could not load stats',
        body: statsError,
        onRetry: onRetry,
      );
    }
    if ((statsLoading && stats == null) ||
        (earningsLoading && earningsToday == null)) {
      return Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Skeleton.box(height: 88)),
              const SizedBox(width: 12),
              Expanded(child: Skeleton.box(height: 88)),
            ],
          ),
          const SizedBox(height: 12),
          Skeleton.box(height: 88),
        ],
      );
    }

    final double earningsValue = earningsToday?.totalEarnings ?? 0;
    final int delivered = stats?.deliveredToday ?? 0;
    final double rating =
        (profile?.rating ?? stats?.rating ?? 0).toDouble();

    // Use a 2-column top row + full-width bottom card layout so
    // values never get truncated on narrow screens.
    return Column(
      children: <Widget>[
        // Top row: Earnings (wider) + Delivered
        Row(
          children: <Widget>[
            // Earnings — given more space (flex 3) so ₹1,234 fits
            Expanded(
              flex: 3,
              child: _StatTile(
                label: 'Today\'s Earnings',
                value: _HomeScreenState.formatRupees(earningsValue),
                icon: Icons.payments_outlined,
                iconColor: AppColors.success,
              ),
            ),
            const SizedBox(width: 12),
            // Delivered
            Expanded(
              flex: 2,
              child: _StatTile(
                label: 'Delivered',
                value: delivered.toString(),
                icon: Icons.local_shipping_outlined,
                iconColor: AppColors.charcoal,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Bottom: Rating full width
        _StatTile(
          label: 'Rating',
          value: rating > 0 ? rating.toStringAsFixed(1) : '—',
          icon: Icons.star_rounded,
          iconColor: AppColors.warning,
          fullWidth: true,
        ),
      ],
    );
  }
}

/// Individual stat tile — replaces the old `StatCard` on the home screen
/// with a layout that never truncates values.
class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.iconColor,
    this.fullWidth = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color iconColor;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  style: AppTypography.micro.copyWith(color: AppColors.muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                // FittedBox scales the value down gracefully if needed
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: AppTypography.heading
                        .copyWith(color: AppColors.charcoal),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Offers section
// ─────────────────────────────────────────────────────────────────────────────

class _OffersSection extends StatelessWidget {
  const _OffersSection({
    required this.offers,
    required this.ordersLoading,
    required this.ordersError,
    required this.isOnline,
    required this.onRetry,
  });

  final List<DeliveryOrder> offers;
  final bool ordersLoading;
  final String? ordersError;
  final bool isOnline;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (ordersLoading && offers.isEmpty) {
      return Column(
        children: <Widget>[
          Skeleton.box(height: 96),
          const SizedBox(height: 8),
          Skeleton.box(height: 96),
        ],
      );
    }
    if (ordersError != null && offers.isEmpty) {
      return ErrorState(
        title: 'Could not load orders',
        body: ordersError,
        onRetry: onRetry,
      );
    }
    if (offers.isEmpty) {
      return EmptyState(
        icon: isOnline ? Icons.hourglass_empty : Icons.delivery_dining,
        title: isOnline ? 'Looking for orders' : 'You are offline',
        body: isOnline
            ? 'You are online. Waiting for orders near your store.'
            : 'You are offline. Go online to receive orders.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'NEW OFFERS',
          style: AppTypography.micro.copyWith(color: AppColors.muted),
        ),
        const SizedBox(height: 8),
        for (final DeliveryOrder offer in offers) ...<Widget>[
          _OfferRow(offer: offer),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _OfferRow extends StatelessWidget {
  const _OfferRow({required this.offer});

  final DeliveryOrder offer;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => unawaited(showDeliveryOfferSheet(context, offer)),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.offWhite,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.delivery_dining,
                  size: 22,
                  color: AppColors.charcoal,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _HomeScreenState.formatRupees(offer.riderEarning),
                      style: AppTypography.heading
                          .copyWith(color: AppColors.charcoal),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      offer.storeAddress.name,
                      style: AppTypography.body
                          .copyWith(color: AppColors.charcoal),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      offer.customerAddress.name.isNotEmpty
                          ? offer.customerAddress.name
                          : offer.customerAddress.address,
                      style: AppTypography.micro
                          .copyWith(color: AppColors.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right,
                  size: 20, color: AppColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}
