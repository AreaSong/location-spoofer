#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT/build.sh"
CORE_SCRIPT="$ROOT/Scripts/build-core.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

test -x "$BUILD_SCRIPT" || fail "build.sh must be executable"
grep -qF "build-unsigned-ipa.sh" "$BUILD_SCRIPT" || fail "build.sh must call build-unsigned-ipa.sh"

test -f "$ROOT/Scripts/build-unsigned-ipa.sh" || fail "build-unsigned-ipa.sh must exist"

# Should NOT contain Tunnel references
! grep -qF "Tunnel" "$ROOT/Scripts/build-unsigned-ipa.sh" || fail "build-unsigned-ipa.sh must not reference Tunnel"
# 扩展由 Xcode target dependency 嵌入，打包应完整保留其结果。
! grep -qF "appex" "$ROOT/Scripts/build-unsigned-ipa.sh" || fail "build-unsigned-ipa.sh must not manually embed extensions"

test -f "$CORE_SCRIPT" || fail "build-core.sh must exist"
grep -q 'iphonesimulator arm64 arm64' "$CORE_SCRIPT" || fail "simulator build must include arm64"
grep -q 'iphonesimulator x86_64 amd64' "$CORE_SCRIPT" || fail "simulator build must include x86_64"
grep -q 'xcrun lipo -create' "$CORE_SCRIPT" || fail "simulator slices must be merged with lipo"
grep -q 'wloccore_startproxyv2' "$CORE_SCRIPT" || fail "simulator archive must be checked for exported symbols"

echo "PASS: root build script contract"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/Tests/build_scripts_behavior_test.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/Tests/verify_ipa_test.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/Tests/deployment_targets_test.py"
