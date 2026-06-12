#!/bin/bash
# Probes state-changing endpoints. Uses the seed rider phone +919999999999.
set -u
export PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/sbin:/sbin:${PATH:-}"
BASE='https://grolin.shotlin.in/api/v1'
PHONE='+919999999999'

SEND_RESP=$(curl -s -X POST "$BASE/auth/send-otp" -H "Content-Type: application/json" -d "{\"phone\":\"$PHONE\"}")
OTP=$(echo "$SEND_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['otp'])")
VERIFY=$(curl -s -X POST "$BASE/auth/verify-otp" -H "Content-Type: application/json" -d "{\"phone\":\"$PHONE\",\"otp\":\"$OTP\",\"role\":\"RIDER\"}")
TOKEN=$(echo "$VERIFY" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['accessToken'])")
REFRESH=$(echo "$VERIFY" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['refreshToken'])")
echo "logged in"

echo
echo '=== PATCH /delivery/toggle-online (true while not approved) ==='
curl -s -X PATCH "$BASE/delivery/toggle-online" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"isOnline":true}'
echo

echo
echo '=== PATCH /delivery/location ==='
curl -s -X PATCH "$BASE/delivery/location" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"latitude":22.5726,"longitude":88.3639}'
echo

echo
echo '=== POST /auth/refresh-token ==='
curl -s -X POST "$BASE/auth/refresh-token" \
  -H "Content-Type: application/json" \
  -d "{\"refreshToken\":\"$REFRESH\"}"
echo

echo
echo '=== PATCH /delivery/orders/<bogus>/accept (not found path) ==='
curl -s -X PATCH "$BASE/delivery/orders/00000000-0000-0000-0000-000000000000/accept" \
  -H "Authorization: Bearer $TOKEN"
echo

echo
echo '=== PATCH /delivery/orders/<bogus>/reject ==='
curl -s -X PATCH "$BASE/delivery/orders/00000000-0000-0000-0000-000000000000/reject" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"reason":"TOO_FAR"}'
echo

echo
echo '=== PATCH /delivery/orders/<bogus>/pickup ==='
curl -s -X PATCH "$BASE/delivery/orders/00000000-0000-0000-0000-000000000000/pickup" \
  -H "Authorization: Bearer $TOKEN"
echo

echo
echo '=== PATCH /delivery/orders/<bogus>/deliver (otp) ==='
curl -s -X PATCH "$BASE/delivery/orders/00000000-0000-0000-0000-000000000000/deliver" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"otp":"1234"}'
echo

echo
echo '=== PATCH /delivery/orders/<bogus>/deliver (demoMode) ==='
curl -s -X PATCH "$BASE/delivery/orders/00000000-0000-0000-0000-000000000000/deliver" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"demoMode":true}'
echo

echo
echo '=== Re-fetch profile (after toggle/location attempts) ==='
curl -s "$BASE/delivery/profile" -H "Authorization: Bearer $TOKEN"
echo
