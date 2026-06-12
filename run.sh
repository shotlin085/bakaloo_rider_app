#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run.sh — convenience wrapper so you can just type `./run.sh` instead of
# remembering the full flutter run command with flavor flags.
#
# Usage:
#   ./run.sh              → debug on the first available device (dev flavor)
#   ./run.sh -d <id>      → debug on a specific device
#   ./run.sh release      → release build on first device
#   ./run.sh staging      → dev build with staging flavor
# ---------------------------------------------------------------------------

set -euo pipefail

FLAVOR="dev"
MODE="debug"
EXTRA_ARGS=()

for arg in "$@"; do
  case "$arg" in
    release)  MODE="release" ;;
    staging)  FLAVOR="staging" ;;
    prod)     FLAVOR="prod"; MODE="release" ;;
    *)        EXTRA_ARGS+=("$arg") ;;
  esac
done

echo "▶  flutter run --flavor $FLAVOR --dart-define=FLAVOR=$FLAVOR --$MODE ${EXTRA_ARGS[*]:-}"
flutter run \
  --flavor "$FLAVOR" \
  --dart-define="FLAVOR=$FLAVOR" \
  "--$MODE" \
  "${EXTRA_ARGS[@]:-}"
