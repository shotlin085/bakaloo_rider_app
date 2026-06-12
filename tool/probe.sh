#!/bin/bash
# Quick probe of the live Grolin backend to capture real response shapes.
# Used during initial implementation to pin down field casing and error envelopes.
# Not committed to production builds.
set -u
export PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/sbin:/sbin:${PATH:-}"
BASE='https://grolin.shotlin.in/api/v1'
PHONE='+919999999999'

echo '=== POST /auth/send-otp ==='
SEND_RESP=$(curl -s -X POST "$BASE/auth/send-otp" -H "Content-Type: application/json" -d "{\"phone\":\"$PHONE\"}")
echo "$SEND_RESP"
echo

OTP=$(echo "$SEND_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['otp'])")

echo '=== POST /auth/verify-otp ==='
VERIFY_RESP=$(curl -s -X POST "$BASE/auth/verify-otp" -H "Content-Type: application/json" -d "{\"phone\":\"$PHONE\",\"otp\":\"$OTP\",\"role\":\"RIDER\"}")
echo "$VERIFY_RESP"
echo

TOKEN=$(echo "$VERIFY_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['accessToken'])")

for path in \
  '/delivery/profile' \
  '/delivery/documents' \
  '/delivery/orders' \
  '/delivery/orders?status=ASSIGNED' \
  '/delivery/stats' \
  '/delivery/earnings?period=today' \
  '/delivery/earnings?period=week' \
  '/delivery/earnings?period=month' \
  '/delivery/earnings?period=all' \
  '/delivery/payouts?page=1&limit=20' \
  '/delivery/history?page=1&limit=20' \
  '/delivery/store-info' \
  ; do
  echo "=== GET $path ==="
  curl -s "$BASE$path" -H "Authorization: Bearer $TOKEN"
  echo
  echo
done
