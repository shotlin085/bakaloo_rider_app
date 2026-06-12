# Grolin Rider App – Demo Smoke Test Checklist

Backend: https://grolin.shotlin.in
Seed rider: +919999999999 (OTP: auto-displayed in dev flavor)

## Steps

1. [ ] App launches → splash → routes to login
2. [ ] Enter +919999999999 → "Send OTP" → OTP screen, dev OTP shown
3. [ ] Enter OTP → verify → routes to approval screen (seed rider is not approved)
4. [ ] Tap "Check approval status" → profile re-fetched
5. [ ] (After admin approves) → routes to home dashboard
6. [ ] Toggle online → location permission prompted → GPS acquired → online
7. [ ] Socket connects → green dot in status pill
8. [ ] New offer arrives (backend auto-assign) → offer sheet shown
9. [ ] Tap Accept → map screen → store marker, rider marker
10. [ ] Tap "Mark as picked up" → route switches to customer
11. [ ] Tap Deliver → OTP sheet → enter OTP / use demoMode
12. [ ] Completion summary → earnings updated
13. [ ] Earnings tab → today earnings shown
14. [ ] History tab → completed delivery listed
15. [ ] Profile tab → rider name, rating, deliveries
16. [ ] Settings tab → toggles visible
17. [ ] Logout → routes to login

## Edge cases to verify

- [ ] Kill app during active delivery → reopen → resumes on map screen
- [ ] Toggle airplane mode → offline banner appears → reconnects on restore
- [ ] Enter wrong OTP → error shown, can retry
- [ ] Reject an offer → toast "Order declined", stays online
- [ ] Two rapid failures on Accept → diagnostic expander appears
