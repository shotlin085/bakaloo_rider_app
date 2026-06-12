# Grolin Rider App

Flutter delivery-partner app for the Grolin grocery platform.

## Backend

The app talks to the live Grolin backend over HTTPS:

- REST: `https://grolin.shotlin.in/api/v1`
- Socket.IO: `https://grolin.shotlin.in`

There is no localhost or staging environment for this build; all flavors
target the live host. Cleartext traffic is disallowed everywhere.

## Running the demo

```bash
# 1. Start the emulator
flutter emulators --launch Medium_Phone_API_36.1

# 2. Run the dev flavor
flutter run --flavor dev --dart-define=FLAVOR=dev

# 3. Seed rider: +919999999999 (OTP is shown on-screen in dev builds)
```

The seed rider is pre-created on the live backend. Approval must be granted by an admin before the home dashboard is accessible.

## Build flavors

Three Android product flavors are configured. They share the same backend
and only differ in app id suffix, app name, and dev affordances.

```bash
# Run against the dev flavor on a connected device or emulator
flutter run --flavor dev --dart-define=FLAVOR=dev

# Run against staging (same backend, dev affordances off, staging label)
flutter run --flavor staging --dart-define=FLAVOR=staging

# Production build
flutter build apk --flavor prod --dart-define=FLAVOR=prod --release
```

## Project layout

The `lib/` tree follows feature-first clean architecture:

```text
lib/
  app/                  # router, bootstrap, top-level shell
  core/                 # config, network, realtime, storage,
                        # location, notifications, theme, utils
  features/
    auth/               # phone OTP login, session restore
    onboarding/         # rider approval + document upload
    home/               # rider shell + dashboard
    delivery/           # offers, accept/reject, active delivery, map
    earnings/           # today/week/month earnings + payouts
    history/            # paginated delivery history
    profile/            # profile + settings + logout
  shared/widgets/       # design-system widgets
```

See `.kiro/specs/grolin-rider-app/design.md` for the full architecture.

## Running the demo

```bash
# 1. Start the emulator
flutter emulators --launch Medium_Phone_API_36.1

# 2. Run the dev flavor
flutter run --flavor dev --dart-define=FLAVOR=dev

# 3. Seed rider: +919999999999 (OTP is shown on-screen in dev builds)
```

The seed rider is pre-created on the live backend. Approval must be granted by an admin before the home dashboard is accessible.

See `tool/smoke_test_checklist.md` for the full manual verification flow.

## Tests

```bash
flutter analyze
flutter test
```

Property-based tests for the five correctness properties live under
`test/properties/` and use [`glados`](https://pub.dev/packages/glados).

## Google Maps API key

The active-delivery map screen renders Google Maps tiles, so the build
needs a Google Maps API key for each platform. The repo intentionally
does not ship a key — provide your own per the steps below.

### Android

The Android Maps SDK reads its key from the `MAPS_API_KEY` manifest
placeholder. `android/app/build.gradle.kts` looks the value up in this
priority order:

1. The `MAPS_API_KEY` Gradle property (e.g. set in `android/local.properties`).
2. The `MAPS_API_KEY` environment variable.
3. Empty string (Maps tiles will refuse to render).

Pick whichever knob fits your workflow:

```bash
# Local dev: persist in android/local.properties so every build picks it up
echo "MAPS_API_KEY=AIza..." >> android/local.properties

# One-off build via env var
MAPS_API_KEY=AIza... flutter run --flavor dev --dart-define=FLAVOR=dev

# CI: pass it through gradle property
flutter build apk --flavor prod --dart-define=FLAVOR=prod \
  -PMAPS_API_KEY=$MAPS_API_KEY
```

The placeholder is substituted into
`android/app/src/main/AndroidManifest.xml` as the
`<meta-data android:name="com.google.android.geo.API_KEY">` value.

### iOS

The iOS Maps SDK is initialised via `GMSServices.provideAPIKey(...)`
inside `ios/Runner/AppDelegate.swift`. The committed source uses a
literal placeholder (`YOUR_IOS_KEY`) — swap it for your own key locally
or via a build-time substitution that lives outside the repo.
