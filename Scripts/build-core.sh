#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/Core"
BUILD="$CORE/build"
MIN_IOS_VERSION="15.0"

build_archive() {
  local sdk="$1"
  local clang_arch="$2"
  local goarch="$3"
  local min_flag="$4"
  local output="$5"
  local sdk_path cc cflags

  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" --find clang)"
  if [ "$sdk" = "iphonesimulator" ]; then
    cflags="-target ${clang_arch}-apple-ios${MIN_IOS_VERSION}-simulator -isysroot ${sdk_path}"
  else
    cflags="-arch ${clang_arch} -isysroot ${sdk_path} ${min_flag}"
  fi

  CGO_ENABLED=1 \
  CC="$cc" \
  CXX="${cc}++" \
  CGO_CFLAGS="$cflags" \
  CGO_LDFLAGS="$cflags" \
  GOOS=ios GOARCH="$goarch" \
  go build -buildmode=c-archive -ldflags="-s -w" -o "$output" .
}

assert_exported_symbol() {
  local archive="$1"
  local arch="$2"
  local symbol="$3"

  xcrun lipo -archs "$archive" | grep -qw "$arch"
  xcrun nm -arch "$arch" "$archive" 2>/dev/null | grep -q " _${symbol}$"
}

rm -rf "$BUILD"
mkdir -p "$BUILD/iphoneos" "$BUILD/iphonesimulator/slices"
cd "$CORE"
go mod download

build_archive iphoneos arm64 arm64 "-miphoneos-version-min=$MIN_IOS_VERSION" "$BUILD/iphoneos/libwloccore.a"
build_archive iphonesimulator arm64 arm64 "" "$BUILD/iphonesimulator/slices/libwloccore-arm64.a"
build_archive iphonesimulator x86_64 amd64 "" "$BUILD/iphonesimulator/slices/libwloccore-x86_64.a"

xcrun lipo -create \
  "$BUILD/iphonesimulator/slices/libwloccore-arm64.a" \
  "$BUILD/iphonesimulator/slices/libwloccore-x86_64.a" \
  -output "$BUILD/iphonesimulator/libwloccore.a"
rm -rf "$BUILD/iphonesimulator/slices"

cp "$BUILD/iphoneos/libwloccore.h" "$ROOT/Core/wloccore.h"

test -s "$BUILD/iphoneos/libwloccore.a"
test -s "$BUILD/iphonesimulator/libwloccore.a"
test -s "$ROOT/Core/wloccore.h"
assert_exported_symbol "$BUILD/iphoneos/libwloccore.a" arm64 wloccore_startproxyv2
assert_exported_symbol "$BUILD/iphonesimulator/libwloccore.a" arm64 wloccore_startproxyv2
assert_exported_symbol "$BUILD/iphonesimulator/libwloccore.a" x86_64 wloccore_startproxyv2
echo "Built device and universal simulator Core archives"
