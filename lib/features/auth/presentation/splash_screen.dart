import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../application/session_controller.dart';

/// Splash + AuthGate screen.
///
/// On first frame it triggers [SessionController.restore]. Once a
/// session phase resolves, the GoRouter redirect rule navigates the
/// rider to login / approval / home.
class SplashScreen extends ConsumerStatefulWidget {
  /// Const constructor so the route can use `const SplashScreen()`.
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    // Defer to a microtask so we don't run async work in initState
    // synchronously and so the providers are fully built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final SessionController controller =
          ref.read<SessionController>(sessionControllerProvider);
      // Only kick off restore when we are still in the unknown phase;
      // otherwise the rider is just transiting through splash.
      if (!controller.state.isResolved) {
        controller.restore();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('Bakaloo Rider', style: AppTypography.display),
              const SizedBox(height: 12),
              Text(
                'Setting things up…',
                style: AppTypography.body.copyWith(color: AppColors.muted),
              ),
              const SizedBox(height: 32),
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.charcoal),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
