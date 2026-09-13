import 'package:url_launcher/url_launcher.dart' as ul;

import '../maps/geo_point.dart';
import 'app_logger.dart';

/// Pluggable backend for [ExternalNavigationLauncher] so widget and
/// unit tests can record `launchUrl` calls without touching the
/// platform.
///
/// Production wiring uses [DefaultUrlLauncherDelegate] which delegates
/// straight to the `url_launcher` package.
abstract class UrlLauncherDelegate {
  /// Returns whether the platform can handle [uri].
  Future<bool> canLaunch(Uri uri);

  /// Launches [uri] in [mode]. Returns `true` on a successful launch.
  Future<bool> launch(Uri uri, {required ul.LaunchMode mode});
}

/// Production [UrlLauncherDelegate] backed by `url_launcher`.
class DefaultUrlLauncherDelegate implements UrlLauncherDelegate {
  /// Const constructor so the provider can return a singleton.
  const DefaultUrlLauncherDelegate();

  @override
  Future<bool> canLaunch(Uri uri) => ul.canLaunchUrl(uri);

  @override
  Future<bool> launch(Uri uri, {required ul.LaunchMode mode}) =>
      ul.launchUrl(uri, mode: mode);
}

/// Launches Google Maps driving directions from the rider's current
/// position to a delivery destination (R12.8).
///
/// **Side-effect invariant (R30.4)**: this class MUST NOT touch
/// session, socket, or location subsystems. Its only side effect is
/// calling the underlying [UrlLauncherDelegate]. The thin delegate
/// surface lets tests record exactly which URLs are launched and
/// confirm no other state is mutated.
class ExternalNavigationLauncher {
  /// Constructs a launcher backed by [delegate]. Production code
  /// passes [DefaultUrlLauncherDelegate]; tests pass a recording
  /// double.
  const ExternalNavigationLauncher({
    UrlLauncherDelegate delegate = const DefaultUrlLauncherDelegate(),
  }) : _delegate = delegate;

  final UrlLauncherDelegate _delegate;

  /// Opens Google Maps driving directions to ([destLat], [destLng])
  /// using the canonical universal URL:
  ///
  /// ```text
  /// https://www.google.com/maps/dir/?api=1
  ///   &destination=<lat>,<lng>
  ///   &travelmode=driving
  /// ```
  ///
  /// First tries [ul.LaunchMode.externalApplication] so an installed
  /// Google Maps / Apple Maps app takes over. If that path fails (no
  /// app, the platform reports it cannot launch, or the launch
  /// throws), falls back to [ul.LaunchMode.platformDefault] which
  /// typically opens the URL in the default browser.
  Future<bool> openDrivingDirections({
    required double destLat,
    required double destLng,
  }) {
    final Uri uri = buildGoogleMapsDirectionsUrl(
      destLat: destLat,
      destLng: destLng,
    );
    return _launchWithFallback(uri);
  }

  /// Opens Google Maps **multi-stop** driving directions through every
  /// stop in [orderedStops], in order — the same "premium" route the
  /// map screen itself plans (item 8/9: nearest-neighbor sequencing),
  /// handed off to Google Maps' own multi-stop optimizer so the rider
  /// can use turn-by-turn navigation for the whole trip instead of
  /// re-opening Maps for each delivery individually.
  ///
  /// [orderedStops] must have at least one entry; a single entry
  /// degrades to the same URL shape [openDrivingDirections] would
  /// build. No `origin` is set — Maps uses the device's live GPS
  /// position, matching [openDrivingDirections]'s existing behaviour.
  Future<bool> openMultiStopDirections(List<GeoPoint> orderedStops) {
    assert(orderedStops.isNotEmpty, 'orderedStops must not be empty');
    final Uri uri = buildGoogleMapsMultiStopDirectionsUrl(orderedStops);
    return _launchWithFallback(uri);
  }

  /// Shared launch sequence for every nav method: try the installed
  /// Maps app first, fall back to the platform default (typically a
  /// browser) if that fails for any reason.
  Future<bool> _launchWithFallback(Uri uri) async {
    try {
      if (await _delegate.canLaunch(uri)) {
        final bool ok = await _delegate.launch(
          uri,
          mode: ul.LaunchMode.externalApplication,
        );
        if (ok) return true;
      }
    } catch (e, stack) {
      AppLogger.warn(
        LogTopic.state,
        'ExternalNavigationLauncher: external app launch failed; '
        'falling back to platformDefault',
        error: e,
        stackTrace: stack,
      );
    }

    try {
      return await _delegate.launch(uri, mode: ul.LaunchMode.platformDefault);
    } catch (e, stack) {
      AppLogger.warn(
        LogTopic.state,
        'ExternalNavigationLauncher: platformDefault launch also failed',
        error: e,
        stackTrace: stack,
      );
      return false;
    }
  }
}

/// Builds the canonical Google Maps directions URL used by
/// [ExternalNavigationLauncher.openDrivingDirections]. Surfaced as a
/// top-level function so tests can assert on the exact URL shape
/// (R12.8, R30.4).
///
/// The `destination` query param keeps the literal `lat,lng` form (no
/// URL-encoded comma) because Google Maps' deep link expects it
/// unencoded. Trailing zeros on coordinate fractions are trimmed so
/// the URL stays compact (`12.5` instead of `12.5000000`).
Uri buildGoogleMapsDirectionsUrl({
  required double destLat,
  required double destLng,
}) {
  final String dest = '${_fmt(destLat)},${_fmt(destLng)}';
  return Uri.parse(
    'https://www.google.com/maps/dir/?api=1'
    '&destination=$dest'
    '&travelmode=driving',
  );
}

/// Builds a **multi-stop** Google Maps directions URL used by
/// [ExternalNavigationLauncher.openMultiStopDirections]. Surfaced as a
/// top-level function so tests can assert on the exact URL shape.
///
/// The last entry in [orderedStops] becomes `destination`; every stop
/// before it becomes a pipe-separated `waypoints` entry — this is
/// Google Maps' documented shape for a multi-destination trip
/// (`https://developers.google.com/maps/documentation/urls/get-started#directions-action`),
/// the same deep link Maps itself uses when a user adds several stops
/// to one trip. Maps applies its own waypoint-order optimization on
/// top of the order we hand it, so this doesn't need to be a perfect
/// route — just a sane starting sequence, which [DeliveryOrder.sequenceRoute]
/// already provides.
Uri buildGoogleMapsMultiStopDirectionsUrl(List<GeoPoint> orderedStops) {
  assert(orderedStops.isNotEmpty, 'orderedStops must not be empty');
  final GeoPoint destination = orderedStops.last;
  final List<GeoPoint> waypoints = orderedStops.sublist(0, orderedStops.length - 1);

  final StringBuffer url = StringBuffer('https://www.google.com/maps/dir/?api=1')
    ..write('&destination=${_fmt(destination.latitude)},${_fmt(destination.longitude)}')
    ..write('&travelmode=driving');

  if (waypoints.isNotEmpty) {
    // Same unencoded `lat,lng` convention as `destination` above (Maps'
    // deep link expects the comma literal); entries are pipe-separated,
    // matching Google's documented multi-stop URL shape exactly.
    final String joined = waypoints
        .map((GeoPoint p) => '${_fmt(p.latitude)},${_fmt(p.longitude)}')
        .join('|');
    url.write('&waypoints=$joined');
  }

  return Uri.parse(url.toString());
}

/// Formats a coordinate with up to 7 decimal places (~ 1 cm) and
/// trims trailing zeros / a dangling decimal point.
String _fmt(double v) {
  String s = v.toStringAsFixed(7);
  if (s.contains('.')) {
    int end = s.length;
    while (end > 0 && s[end - 1] == '0') {
      end--;
    }
    if (end > 0 && s[end - 1] == '.') end--;
    s = s.substring(0, end);
  }
  return s;
}
