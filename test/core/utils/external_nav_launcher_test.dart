import 'package:flutter_test/flutter_test.dart';
import 'package:bakaloo_rider_app/core/maps/geo_point.dart';
import 'package:bakaloo_rider_app/core/utils/external_nav_launcher.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../helpers/recording_url_launcher.dart';

/// Verifies the side-effect surface of [ExternalNavigationLauncher]:
///
/// 1. **URL shape (R12.8)**: launches the canonical
///    `https://www.google.com/maps/dir/?api=1&destination=<lat>,<lng>&travelmode=driving`
///    URI with [LaunchMode.externalApplication].
///
/// 2. **Side-effect invariant (R30.4)**: the launcher only talks to
///    its [UrlLauncherDelegate]. The recorder captures every
///    [UrlLauncherDelegate.canLaunch] / [UrlLauncherDelegate.launch]
///    call, and we confirm those are the *only* recorded
///    interactions — the launcher cannot reach session, socket, or
///    location state from its constructor / call signature.
void main() {
  group('ExternalNavigationLauncher.openDrivingDirections', () {
    test(
      'launches the canonical Google Maps URL with the destination '
      'coordinates and travelmode=driving',
      () async {
        final RecordingUrlLauncher launcher = RecordingUrlLauncher();
        final ExternalNavigationLauncher nav =
            ExternalNavigationLauncher(delegate: launcher);

        final bool ok = await nav.openDrivingDirections(
          destLat: 12.971599,
          destLng: 77.594566,
        );

        expect(ok, isTrue);
        expect(launcher.launchCalls, hasLength(1));
        final CapturedLaunch call = launcher.launchCalls.single;
        expect(call.mode, LaunchMode.externalApplication);
        expect(
          call.uri.toString(),
          'https://www.google.com/maps/dir/?api=1'
          '&destination=12.971599,77.594566'
          '&travelmode=driving',
        );
      },
    );

    test('side-effects are limited to the launcher (R30.4)', () async {
      final RecordingUrlLauncher launcher = RecordingUrlLauncher();
      final ExternalNavigationLauncher nav =
          ExternalNavigationLauncher(delegate: launcher);

      await nav.openDrivingDirections(destLat: 1, destLng: 2);

      // Every recorded interaction is on the launcher; the launcher
      // is the only collaborator the launcher knows about, so any
      // side effect into session / socket / location would have to
      // happen via Riverpod or a global, neither of which is
      // accessible here.
      expect(launcher.canLaunchCalls, hasLength(1));
      expect(launcher.launchCalls, hasLength(1));
    });

    test(
      'falls back to platformDefault when the external app launch '
      'throws (browser fallback path)',
      () async {
        final RecordingUrlLauncher launcher =
            RecordingUrlLauncher(throwOnExternal: true);
        final ExternalNavigationLauncher nav =
            ExternalNavigationLauncher(delegate: launcher);

        final bool ok = await nav.openDrivingDirections(
          destLat: 1,
          destLng: 2,
        );

        expect(ok, isTrue);
        expect(launcher.launchCalls, hasLength(1));
        expect(launcher.launchCalls.single.mode, LaunchMode.platformDefault);
      },
    );

    test(
      'falls back to platformDefault when canLaunch returns false',
      () async {
        final RecordingUrlLauncher launcher =
            RecordingUrlLauncher(canLaunchResult: false);
        final ExternalNavigationLauncher nav =
            ExternalNavigationLauncher(delegate: launcher);

        final bool ok = await nav.openDrivingDirections(
          destLat: 1,
          destLng: 2,
        );

        expect(ok, isTrue);
        expect(launcher.launchCalls, hasLength(1));
        expect(launcher.launchCalls.single.mode, LaunchMode.platformDefault);
      },
    );
  });

  group('buildGoogleMapsDirectionsUrl', () {
    test('emits the expected scheme + host + path + query', () {
      final Uri uri = buildGoogleMapsDirectionsUrl(
        destLat: 22.5726,
        destLng: 88.3639,
      );
      expect(uri.scheme, 'https');
      expect(uri.host, 'www.google.com');
      expect(uri.path, '/maps/dir/');
      expect(uri.queryParameters['api'], '1');
      expect(uri.queryParameters['destination'], '22.5726,88.3639');
      expect(uri.queryParameters['travelmode'], 'driving');
    });

    test('trims trailing zeros from coordinate formatting', () {
      final Uri uri = buildGoogleMapsDirectionsUrl(
        destLat: 12.5,
        destLng: 77.0,
      );
      expect(uri.toString(), contains('destination=12.5,77'));
    });
  });

  group('ExternalNavigationLauncher.openMultiStopDirections', () {
    test(
      'launches a Google Maps URL with waypoints for every stop before '
      'the last, and the last stop as the destination',
      () async {
        final RecordingUrlLauncher launcher = RecordingUrlLauncher();
        final ExternalNavigationLauncher nav =
            ExternalNavigationLauncher(delegate: launcher);

        final bool ok = await nav.openMultiStopDirections(const <GeoPoint>[
          GeoPoint(22.51, 88.31),
          GeoPoint(22.52, 88.32),
          GeoPoint(22.53, 88.33),
        ]);

        expect(ok, isTrue);
        expect(launcher.launchCalls, hasLength(1));
        final CapturedLaunch call = launcher.launchCalls.single;
        expect(call.mode, LaunchMode.externalApplication);
        // Dart's Uri percent-encodes the `|` separator on serialization
        // (%7C) — a valid, equivalent form; queryParameters below confirms
        // it decodes back to the original unencoded shape.
        expect(
          call.uri.toString(),
          'https://www.google.com/maps/dir/?api=1'
          '&destination=22.53,88.33'
          '&travelmode=driving'
          '&waypoints=22.51,88.31%7C22.52,88.32',
        );
        expect(call.uri.queryParameters['waypoints'], '22.51,88.31|22.52,88.32');
      },
    );

    test('a single stop degrades to the same shape as openDrivingDirections', () async {
      final RecordingUrlLauncher launcher = RecordingUrlLauncher();
      final ExternalNavigationLauncher nav =
          ExternalNavigationLauncher(delegate: launcher);

      await nav.openMultiStopDirections(const <GeoPoint>[GeoPoint(12.97, 77.59)]);

      expect(
        launcher.launchCalls.single.uri.toString(),
        'https://www.google.com/maps/dir/?api=1'
        '&destination=12.97,77.59'
        '&travelmode=driving',
      );
    });

    test('falls back to platformDefault when the external app launch throws', () async {
      final RecordingUrlLauncher launcher = RecordingUrlLauncher(throwOnExternal: true);
      final ExternalNavigationLauncher nav =
          ExternalNavigationLauncher(delegate: launcher);

      final bool ok = await nav.openMultiStopDirections(const <GeoPoint>[
        GeoPoint(1, 2),
        GeoPoint(3, 4),
      ]);

      expect(ok, isTrue);
      expect(launcher.launchCalls.single.mode, LaunchMode.platformDefault);
    });
  });

  group('buildGoogleMapsMultiStopDirectionsUrl', () {
    test('emits waypoints (pipe-separated) then the final destination', () {
      final Uri uri = buildGoogleMapsMultiStopDirectionsUrl(const <GeoPoint>[
        GeoPoint(22.51, 88.31),
        GeoPoint(22.52, 88.32),
        GeoPoint(22.53, 88.33),
      ]);

      expect(uri.scheme, 'https');
      expect(uri.host, 'www.google.com');
      expect(uri.queryParameters['destination'], '22.53,88.33');
      expect(uri.queryParameters['waypoints'], '22.51,88.31|22.52,88.32');
      expect(uri.queryParameters['travelmode'], 'driving');
    });

    test('omits the waypoints param entirely for a single stop', () {
      final Uri uri =
          buildGoogleMapsMultiStopDirectionsUrl(const <GeoPoint>[GeoPoint(12.97, 77.59)]);

      expect(uri.queryParameters.containsKey('waypoints'), isFalse);
      expect(uri.queryParameters['destination'], '12.97,77.59');
    });
  });
}
