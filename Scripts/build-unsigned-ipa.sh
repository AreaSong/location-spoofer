#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required for IPA verification" >&2; exit 1; }
for directory in build dist; do
  if [ -L "$directory" ]; then
    echo "构建输出父目录不得为符号链接: $directory" >&2
    exit 1
  fi
done

"$ROOT/Scripts/build-core.sh"
command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate
python3 -B "$ROOT/Scripts/deployment_targets.py" --project "$ROOT/PaopaoLocationSpoofer.xcodeproj"

rm -rf build/UnsignedIPA build/DerivedData
xcodebuild \
  -project PaopaoLocationSpoofer.xcodeproj \
  -scheme PaopaoLocationSpoofer \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

APP="build/DerivedData/Build/Products/Release-iphoneos/PaopaoLocationSpoofer.app"
if [ ! -d "$APP" ]; then
  echo "App bundle not found" >&2
  exit 1
fi

mkdir -p build/UnsignedIPA/Payload dist
ditto "$APP" "build/UnsignedIPA/Payload/PaopaoLocationSpoofer.app"

# 临时产物与目标位于同一文件系统；失败只清理本次拥有的目录，保留上次成功 IPA。
PACKAGE_DIR="$(mktemp -d "$ROOT/dist/.unsigned-ipa.XXXXXX")"
trap 'rm -rf -- "$PACKAGE_DIR"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
IPA="$ROOT/dist/PaopaoLocationSpoofer-unsigned.ipa"
if [ -d "$IPA" ] || [ -L "$IPA" ]; then
  echo "IPA 目标必须为普通文件或尚不存在" >&2
  exit 1
fi
cd build/UnsignedIPA
zip -qry "$PACKAGE_DIR/candidate.ipa" Payload
"$ROOT/Scripts/verify-ipa.sh" --unsigned --macho "$PACKAGE_DIR/candidate.ipa"
mv -f -- "$PACKAGE_DIR/candidate.ipa" "$IPA"
echo "Output: dist/PaopaoLocationSpoofer-unsigned.ipa"
