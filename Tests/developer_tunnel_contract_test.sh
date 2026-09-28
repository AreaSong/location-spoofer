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
for extra in "$ROOT"/App/MapHomeView+*.swift "$ROOT"/App/MapHomeBottomCard.swift "$ROOT"/App/MapHomeCoordinateLine.swift "$ROOT"/App/MapHomeSpotSections.swift; do
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
grep -q 'RouteLocationChecklist(session: session)' "$SECTION" || fail "the settings section must use the shared checklist"
grep -q '恢复真实定位' "$CHECKLIST" || fail "the checklist must offer restoring real location"
grep -q '清理隧道会话' "$CHECKLIST" || fail "the checklist must offer clearing the stale tunnel session"
grep -q 'func resetTunnelCache' "$ROOT/App/RouteLocationSetupStore.swift" \
  || fail "tunnel cache reset must live in the setup store"
grep -q 'RouteLocationSettingsSection(session: session)' "$SETTINGS" || fail "Settings must include the route location section"
grep -B1 'RouteLocationSettingsSection(session: session)' "$SETTINGS" | grep -q 'developerTunnel' \
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
grep -q 'showsSpotHelp: spoofState != .idle && !routeKeepsRunningWhileSpotShown' "$MAP" \
  || fail "developer-tunnel playback must hide spot help while idle or a route keeps running"
grep -q 'struct RunningRouteSpotNotice' "$MAP" || fail "developer-tunnel playback must show a running-route notice on the spot card"
grep -q '退出会停止播放，虚拟定位留在当前点' "$MAP" || fail "exiting a playing route must ask for confirmation"
grep -q '再试一次' "$MAP" || fail "a failed developer tunnel push must offer retry"
grep -q 'recoverDeveloperTunnelIfNeeded' "$MAP" || fail "returning to the foreground must try to recover an active tunnel session"
grep -q 'tunnelRetryDelaysNanoseconds' "$ROOT/App/RouteLocationSetupStore.swift" \
  || fail "developer tunnel push must retry with backoff after LocalDevVPN drops"
grep -q 'func liveTunnelEndpoints' "$ROOT/App/LocalDevVPN.swift" \
  || fail "developer tunnel push must try discovered LocalDevVPN addresses, not only 10.7.0.1"
grep -q 'func isPrivateUnicast' "$ROOT/App/LocalDevVPN.swift" \
  || fail "developer tunnel push must accept LocalDevVPN addresses on any private subnet"
grep -q 'tunnelOnCellular' "$ROOT/Shared/RouteLocationPush.swift" \
  || fail "developer tunnel push must explain cellular-only handshake failure"
grep -q '只开流量、关掉 Wi-Fi' "$ROOT/Shared/RouteLocationPush.swift" \
  || fail "the checklist must warn that cellular-only networks cannot reach the tunnel"
grep -q 'DeveloperTunnelHelp.connectionChecksTitle' "$CHECKLIST" \
  || fail "the checklist must show tunnel troubleshooting steps"
grep -q '连不上时检查这些' "$ROOT/Shared/RouteLocationPush.swift" \
  || fail "tunnel help must keep a titled troubleshooting list"
grep -q '172.20.10' "$ROOT/Shared/RouteLocationPush.swift" \
  || fail "tunnel help must mention the personal-hotspot subnet"
grep -q 'func hostIdentity' "$PAIRING" \
  || fail "developer tunnel handshake must use the pairing-file host identity"
grep -q 'reassertIfNeeded' "$MAP" || fail "foreground recovery must not open a second simulation while one is held"
grep -q 'syncDeveloperLocationKeepAlive' "$MAP" || fail "an active developer-tunnel location must keep the process alive"
! grep -q 'abandonStaleSession' "$MAP" || fail "leaving the app must keep the live location simulation"

grep -q 'case .developerTunnel:' "$DIAGNOSTICS" || fail "diagnostics must run a developer tunnel check"
grep -q '开发者隧道环境检测' "$DIAGNOSTICS" || fail "diagnostics must log the developer tunnel check"
grep -q 'RuntimeLogLevelFilter' "$DIAGNOSTICS" || fail "diagnostics must offer a log level filter"

test -f "$STYLE" || fail "shared app style is missing"
for symbol in 'enum AppRadius' 'enum AppLayout' 'struct CapsuleChipStyle' 'struct PrimaryActionStyle' 'struct CopyButton' 'struct StatusPill'; do
  grep -q "$symbol" "$STYLE" || fail "AppStyle must define: $symbol"
done
grep -q 'DisclosureGroup("工作原理")' "$SETTINGS" || fail "工作原理 must collapse under the runtime mode section"
! grep -q 'Section("致谢")' "$SETTINGS" || fail "关于 and 致谢 must be merged into one section"

echo "PASS: developer tunnel contract"
