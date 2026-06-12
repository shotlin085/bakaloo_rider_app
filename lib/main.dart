import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/bootstrap.dart';
import 'app/router.dart';
import 'core/theme/app_theme.dart';

/// Entry point for the Grolin Rider App.
///
/// All real wiring (system chrome, Riverpod scope, error capture, env
/// resolution) lives in [bootstrap]; `main` is intentionally a thin shim
/// so future bootstrap changes don't ripple into the platform-specific
/// flavor entry points.
Future<void> main() async {
  await bootstrap(() async => const GrolinRiderApp());
}

/// Root widget of the Grolin Rider App.
///
/// Wires the shared [AppTheme] and the GoRouter built from
/// [buildAppRouter] (which observes the `SessionController` for redirect
/// decisions).
class GrolinRiderApp extends ConsumerWidget {
  /// Const constructor so the bootstrap can use `const GrolinRiderApp()`.
  const GrolinRiderApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = buildAppRouter(ref);
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'Grolin Rider',
      theme: AppTheme.light(),
      routerConfig: router,
    );
  }
}
