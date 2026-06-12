#!/bin/bash
set -u
export PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/sbin:/sbin:${PATH:-}"
BASE='https://grolin.shotlin.in/api/v1'
PHONE='+919999999999'

SEND_RESP=$(curl -s -X POST "$BASE/auth/send-otp" -H "Content-Type: application/json" -d "{\"phone\":\"$PHONE\"}")
OTP=$(echo "$SEND_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['otp'])")
VERIFY=$(curl -s -X POST "$BASE/auth/verify-otp" -H "Content-Type: application/json" -d "{\"phone\":\"$PHONE\",\"otp\":\"$OTP\",\"role\":\"RIDER\"}")
TOKEN=$(echo "$VERIFY" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['accessToken'])")

echo '=== accept with empty {} body ==='
curl -s -X PATCH "$BASE/delivery/orders/00000000-0000-0000-0000-000000000000/accept" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'
echo
echo

echo '=== pickup with empty {} body ==='
curl -s -X PATCH "$BASE/delivery/orders/00000000-0000-0000-0000-000000000000/pickup" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'
echo
echo

echo '=== verify-otp with bad phone ==='
curl -s -X POST "$BASE/auth/verify-otp" \
  -H "Content-Type: application/json" \
  -d '{"phone":"+919999999999","otp":"000000","role":"RIDER"}'
echo
echo

echo '=== verify-otp with non-RIDER role ==='
curl -s -X POST "$BASE/auth/verify-otp" \
  -H "Content-Type: application/json" \
  -d "{\"phone\":\"$PHONE\",\"otp\":\"$OTP\",\"role\":\"CUSTOMER\"}"
echo
echo

echo '=== logout ==='
curl -s -X POST "$BASE/auth/logout" \
  -H "Authorization: Bearer $TOKEN"
echo
echo

echo '=== send-otp 6th time within 5 min (rate-limit) ==='
for i in 1 2 3 4 5 6; do
  RESP=$(curl -s -i -X POST "$BASE/auth/send-otp" \
    -H "Content-Type: application/json" \
    -d "{\"phone\":\"$PHONE\"}" | head -1)
  echo "  attempt $i: $RESP"
done
