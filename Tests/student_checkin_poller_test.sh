#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

POLLER="$ROOT/tools/student-checkin-poller"
test -f "$POLLER/poller.py" || fail "student check-in poller is missing"
test -f "$POLLER/config.example.json" || fail "poller example config is missing"
! grep -q 'gs-loc.apple.com' "$POLLER/poller.py" || fail "check-in poller must not touch WLOC interception"
! grep -q 'wloc' "$POLLER/poller.py" || fail "check-in poller must not modify WLOC modules"

python3 -m unittest discover -s "$POLLER" -p 'test_*.py' || fail "student check-in poller tests failed"

echo "PASS: student check-in poller"
