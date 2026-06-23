import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/application/session_controller.dart';
import '../features/auth/application/session_state.dart';
import '../features/auth/presentation/otp_screen.dart';
import '../features/auth/presentation/phone_login_screen.dart';
import '../features/auth/presentation/splash_screen.dart';
import '../features/delivery/application/active_delivery_controller.dart';
import '../features/delivery/presentation/active_delivery_map_screen.dart';
import '../features/earnings/presentation/earnings_screen.dart';
import '../features/earnings/presentation/payout_history_screen.dart';
import '../features/history/presentation/delivery_history_screen.dart';
import '../features/home/presentation/rider_shell.dart';
import '../features/onboarding/presentation/rider_approval_screen.dart';
import '../features/profile/presentation/edit_profile_screen.dart';
import '../features/profile/presentation/profile_screen.dart';
import '../features/profile/presentation/settings_screen.dart';
import '../core/providers.dart';

/// Path constants used by the rider app.
abstract final class AppRoutes {
  /// Splash + auth gate.
  static const String splash = '/';

  /// Phone OTP login start.
  static const String login = '/login';

  /// OTP entry screen.
  static const String otp = '/otp';

  /// Rider approval screen (unverified rider).
  static const String approval = '/approval';

  /// Home shell (approved rider).
  static const String home = '/home';

  /// Active delivery (map + action sheets).
  static const String active = '/active';

  /// Earnings screen.
  static const String earnings = '/earnings';

  /// Payout history screen.
  static const String payoutHistory = '/payout-history';

  /// Delivery history screen.
  static const String history = '/history';

  /// Profile screen.
  static const String profile = '/profile';

  /// Settings screen.
  static const String settings = '/settings';

  /// Edit profile screen.
  static const String editProfile = '/edit-profile';
}

/// Builds the global [GoRouter] used by the app, wired to the
/// [SessionController] so navigation tracks session changes.
GoRouter buildAppRouter(WidgetRef ref) {
  final SessionController session =
      ref.read<SessionController>(sessionControllerProvider);
  final ActiveDeliveryController active =
      ref.read<ActiveDeliveryController>(activeDeliveryControllerProvider);
  // Listenable that fires whenever either the session or the active
  // delivery changes so the redirect rule re-evaluates.
  final Listenable refresh = Listenable.merge(<Listenable>[session, active]);
  return GoRouter(
    initialLocation: AppRoutes.splash,
    refreshListenable: refresh,
    redirect: (BuildContext context, GoRouterState state) {
      final SessionState s = session.state;
      final String location = state.matchedLocation;

      // While we don't yet know the session, keep the splash screen.
      if (!s.isResolved) {
        return location == AppRoutes.splash ? null : AppRoutes.splash;
      }

      final bool onAuthScreen =
          location == AppRoutes.login ||
          location == AppRoutes.otp;

      if (s.isUnauthenticated) {
        return onAuthScreen ? null : AppRoutes.login;
      }
      if (s.isUnverified) {
        return location == AppRoutes.approval ? null : AppRoutes.approval;
      }
      if (s.isApproved) {
        // Active-delivery rule (R26.2): when the rider has an
        // active delivery (ACCEPTED / IN_TRANSIT), keep them on the
        // active-delivery screen. From any non-/active screen we
        // bounce to /active so a hot restart, push notification, or
        // tab switch never lands on /home with a live delivery
        // running in the background.
        final bool hasActive = active.current != null;
        if (hasActive && location != AppRoutes.active) {
          return AppRoutes.active;
        }
        if (onAuthScreen ||
            location == AppRoutes.splash ||
            location == AppRoutes.approval) {
          return AppRoutes.home;
        }
        return null;
      }
      return null;
    },
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.splash,
        builder: (BuildContext context, GoRouterState state) =>
            const SplashScreen(),
      ),
      GoRoute(
        path: AppRoutes.login,
        builder: (BuildContext context, GoRouterState state) =>
            const PhoneLoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.otp,
        builder: (BuildContext context, GoRouterState state) =>
            const OtpScreen(),
      ),
      GoRoute(
        path: AppRoutes.approval,
        builder: (BuildContext context, GoRouterState state) =>
            const RiderApprovalScreen(),
      ),
      GoRoute(
        path: AppRoutes.home,
        builder: (BuildContext context, GoRouterState state) =>
            const RiderShell(),
      ),
      GoRoute(
        path: AppRoutes.active,
        builder: (BuildContext context, GoRouterState state) =>
            const ActiveDeliveryMapScreen(),
      ),
      GoRoute(
        path: AppRoutes.earnings,
        builder: (BuildContext context, GoRouterState state) =>
            const EarningsScreen(),
      ),
      GoRoute(
        path: AppRoutes.payoutHistory,
        builder: (BuildContext context, GoRouterState state) =>
            const PayoutHistoryScreen(),
      ),
      GoRoute(
        path: AppRoutes.history,
        builder: (BuildContext context, GoRouterState state) =>
            const DeliveryHistoryScreen(),
      ),
      GoRoute(
        path: AppRoutes.profile,
        builder: (BuildContext context, GoRouterState state) =>
            const ProfileScreen(),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (BuildContext context, GoRouterState state) =>
            const SettingsScreen(),
      ),
      GoRoute(
        path: AppRoutes.editProfile,
        builder: (BuildContext context, GoRouterState state) =>
            const EditProfileScreen(),
      ),
    ],
  );
}
