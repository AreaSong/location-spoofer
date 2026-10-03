#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

usage() {
  cat <<'USAGE'
Usage: ./build.sh [--test]

Builds dist/PaopaoLocationSpoofer-unsigned.ipa without signing it.

Options:
  --test  After the unsigned IPA is created, run iOS Simulator unit tests.
USAGE
}

require_command() {
  local command_name="$1"
  local install_hint="$2"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    echo "$install_hint" >&2
    exit 1
  fi
}

run_simulator_tests() {
  local simulator_destination
  simulator_destination="$(resolve_simulator_destination)"

  for output in build/SimulatorTests build/SimulatorTests.xcresult; do
    if [ -L "$output" ]; then
      echo "Simulator test output must not be a symlink: $output" >&2
      return 1
    fi
  done
  rm -rf build/SimulatorTests.xcresult
  echo "Simulator destination: $simulator_destination"

  xcodebuild \
    -project PaopaoLocationSpoofer.xcodeproj \
    -scheme PaopaoLocationSpoofer \
    -destination "$simulator_destination" \
    -destination-timeout 60 \
    -derivedDataPath build/SimulatorTests \
    -resultBundlePath build/SimulatorTests.xcresult \
    test
}

resolve_simulator_destination() {
  if [ -n "${SIMULATOR_DESTINATION:-}" ]; then
    printf '%s\n' "$SIMULATOR_DESTINATION"
    return
  fi

  # 完整消费 simctl JSON，保留管道失败；按运行时和 UUID 消歧同名设备。
  xcrun simctl list --json | python3 -c '
import json, sys, uuid
data = json.load(sys.stdin)
runtimes = sorted(
    (r for r in data["runtimes"] if r.get("isAvailable") is True
     and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")),
    key=lambda r: (tuple(int(n) for n in r["version"].split(".")), r["identifier"]),
    reverse=True,
)
destination = None
for runtime in runtimes:
    devices = sorted(
        (d for d in data["devices"].get(runtime["identifier"], [])
         if d.get("isAvailable") is True and d.get("deviceTypeIdentifier", "").startswith(
             "com.apple.CoreSimulator.SimDeviceType.iPhone-")),
        key=lambda d: (d["name"], d["udid"]),
    )
    if devices:
        destination = devices[0]["udid"]
        uuid.UUID(destination)  # 只校验，不改变 simctl 原始大小写；xcodebuild 按原值匹配。
        break
if destination is None:
    sys.exit("No available iPhone simulator/runtime. Set SIMULATOR_DESTINATION explicitly.")
print("platform=iOS Simulator,id=" + destination)
'
}

run_tests=0
case "${1:-}" in
  '')
    ;;
  --test)
    run_tests=1
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

require_command xcrun "Install Xcode and its Command Line Tools."
require_command xcodebuild "Install Xcode and select it with xcode-select."
require_command xcodegen "Install XcodeGen: brew install xcodegen"
require_command go "Select Go >= 1.23.0 explicitly; see docs/BUILD.md. Automatic toolchain download is disabled."
require_command python3 "IPA verification requires Python 3 (standard library only)."

"$ROOT/Scripts/build-unsigned-ipa.sh"

IPA="$ROOT/dist/PaopaoLocationSpoofer-unsigned.ipa"
test -s "$IPA"
echo "Unsigned IPA created: $IPA"

if [ "$run_tests" -eq 1 ]; then
  run_simulator_tests
fi

echo "Next: sign with Impactor (https://github.com/claration/Impactor) and install on device."
