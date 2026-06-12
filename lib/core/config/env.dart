import 'package:flutter/foundation.dart';

import 'flavor.dart';

/// Immutable environment value object.
///
/// Encapsulates everything that varies (or could vary) per flavor, even
/// though for Grolin all three flavors currently point at the same live
/// backend. Keeping it on a value object means feature code can depend on
/// `Env` without caring how the flavor was resolved.
///
/// Resolve the active environment via [Env.current], which reads
/// `--dart-define=FLAVOR=...` (defaulting to `dev` when unset).
@immutable
class Env {
  /// Constructs an [Env] explicitly. Most call sites should use
  /// [Env.forFlavor] or [Env.current].
  const Env({
    required this.apiBaseUrl,
    required this.socketBaseUrl,
    required this.flavor,
    required this.enableDevAffordances,
    this.tileUrlTemplate = _defaultTileUrlTemplate,
  });

  /// Builds the canonical [Env] for [flavor].
  ///
  /// Both REST and Socket.IO point at the live SHOTLIN grocery backend at
  /// `https://grolin.shotlin.in`. There is no localhost or staging variant:
  /// the QA flavor exists for app-side gating, not transport switching.
  factory Env.forFlavor(AppFlavor flavor) {
    return Env(
      apiBaseUrl: _liveApiBaseUrl,
      socketBaseUrl: _liveSocketBaseUrl,
      flavor: flavor,
      enableDevAffordances: flavor.isDev,
      tileUrlTemplate: _defaultTileUrlTemplate,
    );
  }

  /// OSM raster tile URL template used by the on-device tile cache.
  /// Free public OSM endpoint; replaceable per flavor.
  final String tileUrlTemplate;

  /// Default OpenStreetMap raster tile endpoint.
  static const String _defaultTileUrlTemplate =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// REST API root, e.g. `https://grolin.shotlin.in/api/v1`.
  ///
  /// All authenticated and unauthenticated calls go through this base.
  final String apiBaseUrl;

  /// Socket.IO endpoint root, e.g. `https://grolin.shotlin.in`.
  ///
  /// The Socket.IO client is configured with `transports: ['websocket']`
  /// against this URL.
  final String socketBaseUrl;

  /// Active build flavor.
  final AppFlavor flavor;

  /// Whether to render developer-only affordances (demo complete button,
  /// OTP echo on the OTP screen, verbose state logs).
  ///
  /// True iff [flavor] is [AppFlavor.dev]. Production builds MUST never
  /// surface these affordances regardless of backend response shape.
  final bool enableDevAffordances;

  // Live backend constants — pointing at the Bakaloo production API.
  static const String _liveApiBaseUrl = 'https://api.bakaloo.in/api/v1';
  static const String _liveSocketBaseUrl = 'https://api.bakaloo.in';

  /// Raw `FLAVOR` token passed via `--dart-define=FLAVOR=...`.
  ///
  /// Resolved at compile time so tree-shaking can eliminate dev-only
  /// branches from production builds.
  static const String _flavorRaw = String.fromEnvironment(
    'FLAVOR',
    defaultValue: 'dev',
  );

  /// The resolved environment for this build.
  ///
  /// Computed once on first access and memoized.
  static final Env current = Env.forFlavor(AppFlavor.parse(_flavorRaw));

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Env &&
        other.apiBaseUrl == apiBaseUrl &&
        other.socketBaseUrl == socketBaseUrl &&
        other.flavor == flavor &&
        other.enableDevAffordances == enableDevAffordances &&
        other.tileUrlTemplate == tileUrlTemplate;
  }

  @override
  int get hashCode => Object.hash(
        apiBaseUrl,
        socketBaseUrl,
        flavor,
        enableDevAffordances,
        tileUrlTemplate,
      );

  @override
  String toString() {
    return 'Env('
        'flavor=${flavor.name}, '
        'apiBaseUrl=$apiBaseUrl, '
        'socketBaseUrl=$socketBaseUrl, '
        'enableDevAffordances=$enableDevAffordances'
        ')';
  }
}
