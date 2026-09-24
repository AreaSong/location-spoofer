#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

MODE="$ROOT/Shared/ProxyRuntimeMode.swift"
AVAILABILITY="$ROOT/Shared/RuntimeModeAvailability.swift"
CHECKLIST="$ROOT/App/RouteLocationChecklist.swift"
SECTION="$ROOT/App/RouteLocationSettingsSection.swift"
PAIRING="$ROOT/Shared/RoutePairingStore.swift"
DIAGNOSTICS="$ROOT/App/DiagnosticsView.swift"
STYLE="$ROOT/App/AppStyle.swift"
TESTS="$ROOT/Tests/PaopaoLocationSpooferTests/RuntimeModeAvailabilityTests.swift"

SETUP="$(mktemp)"
SETTINGS="$(mktemp)"
MAP="$(mktemp)"
trap 'rm -f "$SETUP" "$SETTINGS" "$MAP"' EXIT
cat "$ROOT/App/FirstSetupView.swift" > "$SETUP"
for extra in "$ROOT"/App/FirstSetupView+*.swift; do
  [ -f "$extra" ] && cat "$extra" >> "$SETUP"
done
cat "$ROOT/App/SettingsView.swift" > "$SETTINGS"
for extra in "$ROOT"/App/SettingsView+*.swift; do
  [ -f "$extra" ] && cat "$extra" >> "$SETTINGS"
done
cat "$ROOT/App/MapHomeView.swift" > "$MAP"
for extra in "$ROOT"/App/MapHomeView+*.swift "$ROOT"/App/MapHomeBottomCard.swift; do
  [ -f "$extra" ] && cat "$extra" >> "$MAP"
done

grep -q 'return "开发者隧道模式"' "$MODE" || fail "developer tunnel mode display name is missing"

test -f "$AVAILABILITY" || fail "runtime mode availability helper is missing"
grep -q 'enum RuntimeModeAvailability' "$AVAILABILITY" || fail "RuntimeModeAvailability must be a pure helper"
grep -q 'static func status(for mode: ProxyRuntimeMode, iOSMajor: Int)' "$AVAILABILITY" \
  || fail "availability must be decided by the iOS major version"
grep -q 'static func orderedModes(iOSMajor: Int)' "$AVAILABILITY" \
  || fail "the mode page must order modes by availability"
grep -q 'RuntimeModeAvailability.orderedModes' "$SETUP" || fail "setup must render modes in the recommended order"
grep -q 'Text("推荐")' "$SETUP" || fail "the recommended mode must carry a badge"
grep -q 'thirdPartyMITMWarning' "$ROOT/App/FirstSetupView+Mode.swift" \
  || fail "the mode page must surface the iOS 27 MITM warning"
test -f "$TESTS" || fail "RuntimeModeAvailability must have unit tests"

test -f "$CHECKLIST" || fail "route location checklist is missing"
grep -q 'struct RouteLocationChecklist' "$CHECKLIST" || fail "RouteLocationChecklist must be a shared view"
grep -q 'RouteLocationChecklist()' "$SETUP" || fail "developer tunnel setup must use the shared checklist"
grep -q 'RouteLocationChecklist()' "$SECTION" || fail "the settings section must use the shared checklist"
grep -q 'RouteLocationSettingsSection()' "$SETTINGS" || fail "Settings must include the route location section"
grep -B1 'RouteLocationSettingsSection()' "$SETTINGS" | grep -q 'developerTunnel' \
  || fail "the route location section must only appear in developer tunnel mode"
grep -q 'scenePhase' "$CHECKLIST" || fail "the checklist must refresh when the app returns to the foreground"
grep -q 'fileImporter' "$CHECKLIST" || fail "the checklist must own the pairing file importer"
! grep -q 'Form {' "$ROOT/App/FirstSetupView+DeveloperTunnel.swift" \
  || fail "the developer tunnel step must not nest a Form inside the setup ScrollView"
grep -q 'DisclosureGroup("配对文件怎么生成")' "$SETUP" || fail "setup must explain how to generate the pairing file"
grep -q 'routeLocation.readiness.blockingMessage' "$ROOT/App/FirstSetupView.swift" \
  || fail "a disabled 完成 button must explain what is still missing"
grep -q 'requestDeveloperOnboarding' "$SETTINGS" || fail "developer tunnel settings must expose the onboarding guide"

grep -q 'completeFileProtectionUntilFirstUserAuthentication' "$PAIRING" \
  || fail "the pairing file must be written with file protection"
grep -q 'routeUsesDeveloperTunnel' "$MAP" || fail "map route playback must branch on developer tunnel mode"
grep -q '先连接隧道' "$MAP" || fail "the main button must guide the user to connect the tunnel first"
grep -q 'homeRuntimeStatusTone' "$MAP" || fail "the runtime status row must carry a tone"
grep -q 'showsRoutePanel' "$MAP" || fail "switching back to 定点 must collapse the route panel without clearing the route"
grep -q '退出会停止播放并清除路线' "$MAP" || fail "exiting a playing route must ask for confirmation"

grep -q 'case .developerTunnel:' "$DIAGNOSTICS" || fail "diagnostics must run a developer tunnel check"
grep -q '开发者隧道环境检测' "$DIAGNOSTICS" || fail "diagnostics must log the developer tunnel check"
grep -q 'RuntimeLogLevelFilter' "$DIAGNOSTICS" || fail "diagnostics must offer a log level filter"

test -f "$STYLE" || fail "shared app style is missing"
for symbol in 'enum AppRadius' 'struct CapsuleChipStyle' 'struct PrimaryActionStyle' 'struct CopyButton' 'struct StatusPill'; do
  grep -q "$symbol" "$STYLE" || fail "AppStyle must define: $symbol"
done
grep -q 'DisclosureGroup("工作原理")' "$SETTINGS" || fail "工作原理 must collapse under the runtime mode section"
! grep -q 'Section("致谢")' "$SETTINGS" || fail "关于 and 致谢 must be merged into one section"

echo "PASS: developer tunnel contract"
