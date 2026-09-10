#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

EXPIRY="$ROOT/Shared/SigningExpiry.swift"
MAP="$ROOT/App/MapHomeView.swift"
SETTINGS="$ROOT/App/SettingsView.swift"

test -f "$EXPIRY" || fail "signing expiry helper is missing"
grep -q 'embedded.mobileprovision' "$EXPIRY" \
  || fail "expiry must read the installed signing profile"
grep -q 'ExpirationDate' "$EXPIRY" \
  || fail "expiry must parse ExpirationDate from the profile"
grep -q 'freeSigningWindowDays = 7' "$EXPIRY" \
  || fail "free Apple ID window must stay 7 days"
grep -q 'mapBannerDays = 2' "$EXPIRY" \
  || fail "the map banner must stay limited to the last two days"
grep -q '免费签名' "$EXPIRY" \
  || fail "free-signing reminder copy must exist"
grep -q 'signingExpiryStatus.settingsMessage' "$SETTINGS" \
  || fail "Settings must surface the free-signing reminder"
grep -q '今天不再提示' "$MAP" \
  || fail "the map banner must be dismissible for the current day"
grep -q 'signingExpiryBannerView' "$MAP" \
  || fail "the map must render a dedicated signing-expiry banner"
grep -q 'private func beginLocationOperation' "$MAP" \
  || fail "beginLocationOperation is missing"
! grep -A40 'private func beginLocationOperation' "$MAP" | grep -q 'SigningExpiry' \
  || fail "signing expiry must not block starting a location operation"
! grep -q '错误代码' "$EXPIRY" "$MAP" "$SETTINGS" \
  || fail "signing expiry copy must not mention error codes"
! grep -q 'firstLaunch\|installDate\|首次启动' "$EXPIRY" \
  || fail "expiry must not guess from first launch"

echo "PASS: signing expiry contract"
