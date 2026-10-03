#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

TIP_VIEWS="$ROOT/App/TipViews.swift"
grep -Fq 'Label("还是无法生效？"' "$TIP_VIEWS" || fail "activation help must use the requested retry heading"
grep -Fq 'Label("还是无法取消？"' "$TIP_VIEWS" || fail "deactivation help must use a mode-specific retry heading"
grep -q 'frame(maxWidth: .infinity, alignment: .leading)' "$TIP_VIEWS" \
  || fail "tip detail copy must align to the leading edge"

MAP_HOME_MAIN="$ROOT/App/MapHomeView.swift"
MAP_STATE="$ROOT/App/MapLocationState.swift"
MAP_BRIDGE="$ROOT/App/MapViewRepresentable.swift"
REALTIME="$ROOT/App/RealtimeLocationManager.swift"
SETUP="$ROOT/App/SetupCoordinator.swift"
PROXY="$ROOT/App/ProxyManager.swift"
SETTINGS_NAVIGATOR="$ROOT/App/SystemSettingsNavigator.swift"
DIAGNOSTICS="$ROOT/App/DiagnosticsView.swift"
CONTENT="$ROOT/App/ContentView.swift"
CONVERTER="$ROOT/Shared/CoordinateConverter.swift"
PROBE="$ROOT/Shared/MapCoordinateSystemProbe.swift"
NETWORK_MONITOR="$ROOT/Shared/NetworkMonitor.swift"

MAP_HOME="$(mktemp)"
SETTINGS_VIEW="$(mktemp)"
FIRST_SETUP="$(mktemp)"
trap 'rm -f "$MAP_HOME" "$SETTINGS_VIEW" "$FIRST_SETUP"' EXIT
cat "$MAP_HOME_MAIN" > "$MAP_HOME"
for extra in "$ROOT"/App/MapHomeView+*.swift "$ROOT"/App/MapHomeBottomCard.swift "$ROOT"/App/MapHomeCoordinateLine.swift "$ROOT"/App/MapHomeSpotSections.swift; do
  [ -f "$extra" ] && cat "$extra" >> "$MAP_HOME"
done
cat "$ROOT/App/SettingsView.swift" > "$SETTINGS_VIEW"
for extra in "$ROOT"/App/SettingsView+*.swift; do
  [ -f "$extra" ] && cat "$extra" >> "$SETTINGS_VIEW"
done
cat "$ROOT/App/FirstSetupView.swift" > "$FIRST_SETUP"
for extra in "$ROOT"/App/FirstSetupView+*.swift; do
  [ -f "$extra" ] && cat "$extra" >> "$FIRST_SETUP"
done

for file in "$MAP_HOME_MAIN" "$MAP_STATE" "$MAP_BRIDGE" "$REALTIME" "$SETUP" "$PROXY" "$SETTINGS_NAVIGATOR" "$DIAGNOSTICS" "$CONTENT" "$CONVERTER" "$PROBE" "$NETWORK_MONITOR"; do
  test -f "$file" || fail "missing required refactor file: $file"
done

! grep -q 'draftCoordinate' "$MAP_HOME" || fail "MapHomeView must not keep the old draftCoordinate authority"
! grep -q 'needsZoom' "$MAP_HOME" || fail "MapHomeView must use camera commands instead of needsZoom"
! grep -q '@Binding var coordinate' "$MAP_BRIDGE" || fail "map bridge must not write a coordinate Binding"
grep -q 'showsUserLocation = true' "$MAP_BRIDGE" || fail "MapKit native user location must be visible"
grep -q 'didUpdate userLocation' "$MAP_BRIDGE" || fail "MapKit native user location must feed realtime state"
grep -q 'coordinate: userLocation.coordinate' "$MAP_BRIDGE" || fail "visible MapKit blue-point samples must use MKUserLocation.coordinate"
! grep -Eq 'userLocation\.location\??\.coordinate' "$MAP_BRIDGE" || fail "MapKit blue-point samples must not use the underlying Core Location coordinate"
grep -q 'MapCameraCommand' "$MAP_BRIDGE" || fail "map bridge must consume MapCameraCommand"
grep -q 'let initialViewportMeters:' "$MAP_BRIDGE" || fail "map bridge must receive initial viewport from MapLocationState"
! grep -q 'ViewportStore.loadOrDefault()' "$MAP_BRIDGE" || fail "map bridge must not bypass MapLocationState for initial viewport"
grep -q 'activeCameraCommandID' "$MAP_BRIDGE" || fail "programmatic map callbacks must be associated with the active camera command"
grep -q 'UIPanGestureRecognizer' "$MAP_BRIDGE" || fail "map panning must be recognized explicitly"
grep -q 'UIPinchGestureRecognizer' "$MAP_BRIDGE" || fail "pinch zoom must not be treated as a selected-center pan"
! grep -q 'RealtimeLocationAnnotation' "$MAP_BRIDGE" || fail "custom realtime point must be removed in favor of MKUserLocation"
grep -q 'selectionRevision' "$MAP_STATE" || fail "map state must reject stale async results by revision"
grep -q 'isApproximatelyEqual(to: coordinate)' "$MAP_STATE" || fail "pure viewport changes must not replace an unchanged selection"
grep -q 'displayName(viewportMeters:' "$MAP_STATE" || fail "place labels must depend on viewport size"
grep -q 'var road:' "$MAP_STATE" || fail "place labels must keep road granularity separate from doorplate details"
grep -q 'district: placemark.subLocality' "$MAP_HOME" || fail "Chinese-style sub-locality must feed the district zoom level"
grep -Eq '@Published private\(set\) var location' "$REALTIME" || fail "realtime location must be read-only outside its manager"
grep -q 'CLLocationCoordinate2DIsValid' "$REALTIME" || fail "realtime manager must reject invalid coordinates"
grep -q 'horizontalAccuracy >= 0' "$REALTIME" || fail "realtime manager must reject invalid accuracy samples"
grep -q 'kCLErrorDomain' "$REALTIME" || fail "denied Core Location errors must be terminal"
grep -q 'case awaitingAuthorization' "$REALTIME" || fail "location requests must wait for authorization before requesting a sample"
grep -q 'var location: CLLocation?' "$REALTIME" || fail "Core Location driver must expose its cached native sample"
grep -q 'oneShotTimeoutNanoseconds' "$REALTIME" || fail "one-shot and fallback timeouts must be independent"
! grep -q 'pendingContinuation' "$REALTIME" || fail "unversioned pendingContinuation must be removed"
grep -q 'applyVerified' "$ROOT/App/SpoofSession.swift" || fail "verified location commits must be synchronous after revision validation"
grep -q 'selectionRevision == services.selectionRevision()' "$ROOT/App/SpoofSession.swift" \
  || fail "APP verification must be discarded when the map selection changes"
grep -q 'func applyVerificationResult' "$SETUP" || fail "verification results must have one setup-state reducer"
grep -q 'case .success:' "$SETUP" || fail "successful verification must converge setup state"
grep -q 'case .certNotTrusted:' "$SETUP" || fail "certificate failure must converge setup state"
grep -q 'setupStep = .proxy' "$SETUP" || fail "proxy failure must converge setup state"
grep -q 'realtimeRequestTask' "$MAP_HOME" || fail "realtime button requests must be synchronously serialized"
grep -q 'RealtimeLocationRequestContext' "$MAP_HOME" || fail "a realtime button tap must retarget an in-flight startup request instead of being ignored"
grep -q 'CLError.network' "$MAP_HOME" || fail "reverse geocoding network failures must use bounded retry"
grep -q 'SystemSettingsNavigator' "$MAP_HOME" || fail "settings actions must use the shared navigator"
grep -q '复制全部日志' "$DIAGNOSTICS" || fail "diagnostics must show a standalone copy button"
grep -q '清空日志' "$DIAGNOSTICS" || fail "diagnostics must show a standalone clear button"
grep -q '日志自动清理，仅保留近 3 天' "$DIAGNOSTICS" || fail "diagnostics must disclose the three-day retention policy"
grep -q 'retentionInterval: TimeInterval = 3 \* 24 \* 60 \* 60' "$ROOT/Shared/RuntimeLog.swift" || fail "runtime logs must retain only three days"
if grep -q 'logEvent("CONNECT " + host + " -> passthrough")' "$ROOT/Core/proxy.go"; then
    fail "proxy diagnostics must not log unrelated passthrough CONNECT hosts"
fi
grep -q 'enum SystemSettingsNavigator' "$SETTINGS_NAVIGATOR" || fail "shared settings navigator is missing"
grep -q 'await CoordinateConverter.resolveInitialMapCoordinateSystem()' "$CONTENT" || fail "map type must resolve before MapHomeView construction"
grep -q 'refreshRuntimeMapCoordinateSystem(reason:' "$PROBE" || fail "fixed-anchor map type must support runtime refresh"
grep -q '固定锚点名称未列入白名单' "$PROBE" || fail "unknown fixed-anchor names must not be classified as WGS-84"
grep -q 'forFixedAnchorFirstResultName name: String) -> MapCoordinateSystem?' "$PROBE" || fail "fixed-anchor name mapping must return nil for unknown names"
grep -q 'scheduleBluePointMapCoordinateSystemRefresh()' "$MAP_HOME" || fail "native blue-point samples must trigger runtime map-type refresh while spoofing"
! grep -A3 'func scheduleBluePointMapCoordinateSystemRefresh' "$MAP_HOME" | grep -q 'spoofState == .active' || fail "blue-point map-type refresh must also detect the return to physical location"
grep -q 'awaitCoordinatedMapCoordinateSystemRefresh(reason: "点击实时定位")' "$MAP_HOME" || fail "realtime button must await the coordinated map-type refresh"
grep -q 'favorites.selectMatching(coordinatePair: pair)' "$MAP_HOME" || fail "realtime selection must restore a matching favorite selection"
grep -q 'awaitCoordinatedMapCoordinateSystemRefresh(reason: "保存收藏")' "$MAP_HOME" || fail "favorite save must await the coordinated map-type refresh"
grep -q 'awaitCoordinatedMapCoordinateSystemRefresh(reason: "App回到前台")' "$MAP_HOME" || fail "foreground recovery must reuse the coordinated map-type refresh"
grep -q '地图坐标标准运行期检测结果已过期，取消写入' "$PROBE" || fail "cancelled runtime probes must not mutate the global map type"
! grep -q 'source == .coreLocation.*correctMapCoordinateSystemUsingRealtime' "$MAP_HOME" || fail "runtime Core Location samples must not infer MapKit type"
grep -q 'clearRealtimeLocationForMapCoordinateSystemChange' "$MAP_HOME" || fail "map-type changes must discard superseded blue-point samples"
grep -q '地图坐标类型已变化' "$MAP_HOME" || fail "map-type changes must emit an explicit searchable business log"
grep -q '图钉已按新类型重设' "$MAP_HOME" || fail "map-type change log must report pin reprojection"
grep -q 'struct MapHomeCoordinateLine' "$ROOT/App/MapHomeCoordinateLine.swift" \
  || fail "current selection must share one switchable coordinate row"
grep -q 'struct MapHomeTopInfoBar' "$ROOT/App/MapHomeCoordinateLine.swift" \
  || fail "map home must keep a collapsible coordinate strip under search"
grep -q 'struct MapChromeIconButton' "$ROOT/App/AppStyle.swift" \
  || fail "map chrome icon buttons must be a dedicated control, not a Menu overlay"
grep -q 'MapChromeIconButton(systemImage: "list.bullet.rectangle", accessibilityLabel: "日志")' "$MAP_HOME_MAIN" \
  || fail "logs must open from a direct top-right button"
grep -q 'MapChromeIconButton(systemImage: "gearshape", accessibilityLabel: "设置")' "$MAP_HOME_MAIN" \
  || fail "settings must open from a direct top-right button"
if awk '/var topControls: some View/{flag=1} flag{print; if (/MapHomeTopInfoBar/) exit}' "$MAP_HOME_MAIN" | grep -q 'Menu {'; then
  fail "home logs and settings must not sit in a Menu over the map"
fi
grep -q 'headingChip' "$ROOT/App/MapHomeCoordinateLine.swift" \
  || fail "walk heading must sit in the trailing chip of the search-bar info strip"
if grep -q 'placeName' "$ROOT/App/MapHomeCoordinateLine.swift"; then
  fail "the search-bar info strip must not use the place name as the trailing chip"
fi
grep -q 'quickActions' "$ROOT/App/MapHomeBottomCard.swift" \
  || fail "collapsed bottom card must keep walk shortcuts outside the expanded lists"
grep -q 'Toggle("初始指向"' "$ROOT/App/MapHomeView+PhysicalWalk.swift" \
  || fail "custom heading must be a dedicated toggle, defaulting off"
grep -q 'Toggle("真实走动"' "$ROOT/App/MapHomeView+PhysicalWalk.swift" \
  || fail "physical walk toggle must sit in the heading angle row"
grep -q 'isCustomHeadingEnabled' "$ROOT/Shared/PhysicalWalkStore.swift" \
  || fail "custom heading on/off must persist separately from physical walking"
grep -q 'latestMapHeadingDegrees' "$ROOT/App/PhysicalWalkSensors.swift" \
  || fail "default heading must follow the map compass, not the custom instrument"
grep -q 'xMagneticNorthZVertical' "$ROOT/App/PhysicalWalkSensors.swift" \
  || fail "default heading must use a north-referenced attitude frame so the fan matches the original map"
grep -q 'realtimeCoordinate' "$ROOT/App/MapHomeView+PhysicalWalk.swift" \
  || fail "the heading puck must appear from launch using the realtime coordinate before spoofing"
grep -q 'headingMode: PhysicalWalkHeadingMode = .followCompass' "$ROOT/App/PhysicalWalkController.swift" \
  || fail "connecting or launching must not auto-enable custom heading"
grep -q 'labeledDegrees' "$ROOT/App/MapHomeView+PhysicalWalk.swift" \
  || fail "heading angle row must show the current heading to the left of the walk toggle"
if grep -q 'PhysicalWalkSpotControl' "$ROOT/App/MapHomeView.swift"; then
  fail "bottom card must not keep a duplicate physical walk toggle"
fi
grep -Fq 'paletteColors: [.systemRed, .white]' "$ROOT/App/MapViewRepresentable.swift" \
  || fail "map-center selection pin must render as a red pin, not a white pin"
grep -q 'enum PhysicalWalkHeadingPicker' "$ROOT/Shared/PhysicalWalkDisplacement.swift" \
  || fail "heading chips must stay collapsed after the walk direction is chosen"
grep -q 'Button("−15°")' "$ROOT/App/MapHomeView+PhysicalWalk.swift" \
  || fail "heading controls must expose a labeled 15-degree nudge"
if grep -q 'Button("罗盘")' "$ROOT/App/MapHomeView+PhysicalWalk.swift"; then
  fail "heading controls must not keep a compass chip after manual angle adjustment"
fi
if grep -q 'PhysicalWalkHeadingLock.cardinals' "$ROOT/App/MapHomeView+PhysicalWalk.swift"; then
  fail "heading controls must not keep N/E/S/W chips after manual angle adjustment"
fi
grep -q 'applyNativeUserLocationVisibility' "$ROOT/App/WalkHeadingHud.swift" \
  || fail "walk heading must hide the native user-location dot while the spoofed puck is shown"
grep -q 'walkPuckCoordinate' "$ROOT/App/MapViewRepresentable.swift" \
  || fail "walk heading puck must follow the active spoofed coordinate, not the map-center pin"
grep -q 'walkPuckMapCoordinate' "$ROOT/App/MapHomeView+PhysicalWalk.swift" \
  || fail "home must convert the written WGS-84 coordinate onto the map for the walk puck"
grep -q 'enum WalkPuckMapPlacement' "$ROOT/Shared/PhysicalWalkDisplacement.swift" \
  || fail "walk puck placement must stay on the written spoof coordinate"
if grep -q 'walkEnabled' "$ROOT/Shared/PhysicalWalkDisplacement.swift"; then
  fail "spoofed puck must appear even when physical walking is off"
fi
grep -q 'fromSteps' "$ROOT/Shared/PhysicalWalkDisplacement.swift" \
  || fail "physical walk must keep moving from steps when spoofed GPS freezes pedometer distance"
grep -q 'struct PhysicalWalkHeadingInstrument' "$ROOT/Shared/PhysicalWalkDisplacement.swift" \
  || fail "heading slider must set the instrument initial, not freeze the output"
grep -q 'xArbitraryZVertical' "$ROOT/App/PhysicalWalkSensors.swift" \
  || fail "heading must track relative phone attitude so the simulator can turn the fan"
grep -q 'initialHeadingDegrees' "$ROOT/App/MapHomeView+PhysicalWalk.swift" \
  || fail "heading slider must bind to the initial heading, not the live fan"
grep -q 'func startWalkPuckTracking' "$ROOT/App/WalkHeadingHud.swift" \
  || fail "walk puck must keep tracking the spoofed coordinate while the map moves"
grep -q 'static let puckDiameter: CGFloat = 16' "$ROOT/App/WalkHeadingHud.swift" \
  || fail "walk heading must draw a blue-dot puck on the active virtual coordinate"
grep -q 'static func fanPath' "$ROOT/App/WalkHeadingHud.swift" \
  || fail "walk heading must attach a heading wedge to the active virtual coordinate"
if grep -A6 'if visible {' "$ROOT/App/WalkHeadingHud.swift" | grep -q 'centerPin'; then
  fail "walk heading must not hide the map-center selection pin"
fi
if grep -q 'location.north.fill' "$ROOT/App/WalkHeadingHud.swift"; then
  fail "walk heading must not use a floating location.north.fill arrow"
fi
if grep -q 'compassSize' "$ROOT/App/WalkHeadingHud.swift"; then
  fail "walk heading must not draw a separate compass ring on the map"
fi
grep -q 'func startHeadingPreview' "$ROOT/App/PhysicalWalkController.swift" \
  || fail "compass heading must update before virtual location tracking starts"
grep -q 'GCJ-02(国内)' "$ROOT/App/MapHomeCoordinateLine.swift" || fail "current selection panel must label the domestic coordinate as GCJ-02"
grep -q 'WGS-84(国际)' "$ROOT/App/MapHomeCoordinateLine.swift" || fail "current selection panel must label the international coordinate as WGS-84"
grep -q 'fixedSize(horizontal: true, vertical: false)' "$MAP_HOME" || fail "coordinate labels must keep their natural single-line width"
grep -q 'minimumScaleFactor(0.72)' "$MAP_HOME" || fail "coordinate values must shrink to remain on one line"
grep -q 'phase = .map' "$CONTENT" || fail "ContentView must explicitly gate MapHomeView construction"
! grep -q 'startTileProbe' "$MAP_HOME" || fail "MapHomeView must not start a second fixed-anchor coordinate-system probe"
! grep -q 'initializeMap()' "$MAP_HOME" || fail "MapHomeView must not replay a second map initialization from onAppear"
grep -q '地图创建前请求实时定位' "$CONTENT" || fail "fresh realtime position must resolve before map construction"
! grep -q 'lastTileCheck' "$CONVERTER" "$PROBE" || fail "map coordinate-system detection must not use a time cache"
! grep -q '跳过(缓存' "$CONVERTER" "$PROBE" || fail "map coordinate-system detection must not skip using a cached result"
! grep -q '瓦片检测' "$CONVERTER" "$PROBE" || fail "coordinate-system probe logs must not claim to inspect map tiles"
grep -q 'minimumCountForSuppression = 3' Shared/AppGroup.swift || fail "automatic tip suppression must require three successful operations"
grep -q 'activeTip = .deactivation' "$MAP_HOME" || fail "manual deactivation help must use the non-suppressible generic tip sheet"
grep -q 'stabilizationNanoseconds: UInt64 = 3_000_000_000' "$MAP_HOME" || fail "Wi-Fi changes must wait three seconds before environment verification"
! grep -q 'wifiChangeReminderTipKind' "$MAP_HOME" || fail "Wi-Fi failures must not use a duplicate reminder mapping"
grep -q '当前不能使用定位修改' "$ROOT/Shared/LocationUseAvailability.swift" || fail "missing Wi-Fi must keep the map and show the unavailable prompt"
grep -q 'LocationUseBlock.title' "$MAP_HOME" || fail "the map must render the shared unavailable prompt"
grep -q 'LocationUseAvailability' "$MAP_HOME" || fail "map unavailability must use the shared location-use gate"
grep -q 'enum AppModeNetworkRequirement' "$ROOT/Shared/AppModeNetworkRequirement.swift" \
  || fail "APP mode must have a shared Wi-Fi/cellular gate"
grep -q 'usesCellular' "$NETWORK_MONITOR" \
  || fail "network monitor must publish cellular path state"
grep -q 'showAppModeNetworkAlert' "$FIRST_SETUP" \
  || fail "setup must block APP mode without Wi-Fi"
grep -q '改用第三方代理模式' "$FIRST_SETUP" \
  || fail "setup must offer switching to third-party mode when APP mode is blocked"
grep -q 'newMode == .localWiFi, let message = appModeNetworkBlockedMessage' "$SETTINGS_VIEW" \
  || fail "Settings must refuse switching to APP mode without Wi-Fi"
grep -q 'LocationUseAvailability.current' "$MAP_HOME" \
  || fail "the map must block APP-mode start without Wi-Fi"
test "$(grep -c 'setup.applyVerificationResult(result' "$MAP_HOME")" -ge 2 \
  || fail "activation and Wi-Fi-change verification failures must use the shared setup reducer"
! grep -q 'activeTip = \.proxySetup' "$MAP_HOME" || fail "proxy failures must not use a duplicate tip sheet"
! grep -q 'case certificate' "$ROOT/App/TipViews.swift" || fail "generic certificate tip must not coexist with certificate setup"
! grep -q 'CertificateTipContent' "$ROOT/App/TipViews.swift" || fail "certificate failures must use the complete setup flow"
! grep -q 'case proxySetup' "$ROOT/App/TipViews.swift" || fail "proxy failures must use the complete setup flow"
! grep -q 'case rewriteFailed' "$ROOT/App/TipViews.swift" || fail "rewrite failures must use the complete setup flow"
! grep -q 'onChange(of: net.isAirplaneMode)' "$MAP_HOME" || fail "airplane recovery must not race the Wi-Fi change verifier"
grep -q 'hasReceivedInitialPath' "$NETWORK_MONITOR" || fail "initial network path must not be reported as a Wi-Fi switch"
grep -q 'lastKnownSSID' "$NETWORK_MONITOR" || fail "SSID polling must preserve a baseline across temporary nil readings"
KEEP_ALIVE="$ROOT/Shared/BackgroundKeepAlive.swift"
test -f "$KEEP_ALIVE" || fail "missing required refactor file: $KEEP_ALIVE"
grep -q '近不可闻音频' "$KEEP_ALIVE" || fail "keep-alive must not use a fully silent buffer"
grep -q '看门狗' "$KEEP_ALIVE" || fail "keep-alive must restart if the audio engine stops"
grep -q 'func isWlocPatchRequest' "$ROOT/Core/proxy.go" || fail "WLOC patching must accept /clls/wloc with a trailing slash"
grep -q 'wloc pass-through' "$ROOT/Core/proxy.go" || fail "unpatched WLOC-host POSTs must be logged"
test -f "$ROOT/Shared/LocationCoordinateOffset.swift" || fail "APP mode must offset WGS-84 with a dedicated helper"
grep -q 'Toggle("随机扰动"' "$SETTINGS_VIEW" || fail "random perturbation must be available in settings"
grep -q '定位精度' "$SETTINGS_VIEW" || fail "settings must expose a configurable location accuracy"
grep -q 'LocationAccuracyStore.shared.meters' "$MAP_HOME" || fail "map apply must stamp the accuracy store onto the current selection"
! grep -q 'accuracy: 25' "$MAP_HOME" || fail "map apply must not hardcode accuracy 25"
grep -q 'effectiveRadiusMeters' "$ROOT/Shared/AppGroup.swift" || fail "disabled random radius must write a zero offset"
grep -q '地图坐标标准' "$SETTINGS_VIEW" || fail "settings must show the current map coordinate system"
grep -q '检测未命中白名单，当前按国内标准显示' "$SETTINGS_VIEW" || fail "settings must explain the GCJ-02 fallback"
test -f "$ROOT/Shared/CoordinateTextParser.swift" || fail "coordinate search must parse typed latitude/longitude"
test -f "$ROOT/Shared/FavoriteTransfer.swift" || fail "favorite backup must use a dedicated transfer format"
grep -q 'paopao-favorites' "$ROOT/Shared/FavoriteTransfer.swift" || fail "favorite backup JSON must use the paopao-favorites format"
python3 - "$MAP_HOME" <<'PY_CHECK'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
call = re.search(r"case \.settings: SettingsView\((.*?)\n\s*\)", source, re.S)
assert call, "settings construction must exist"
for argument in ["favorites: favorites", "favoriteImport: favoriteImport", "isSettingsPresented: { activeSheet == .settings }"]:
    assert argument in call.group(1), f"settings must share map ownership: {argument}"
PY_CHECK
# 第 7 阶段将搜索结果构造移入模型，文案契约仍需保留。
grep -q '按国内标准(GCJ-02)选点' "$ROOT/App/MapSearchModel.swift" || fail "typed coordinates must offer an explicit GCJ-02 choice"
! grep -q '当前地图：' "$MAP_HOME" || fail "expanded spot must not spend a row on 当前地图"
grep -q 'bottomCardExpandedHeightFraction' "$ROOT/App/AppStyle.swift" \
  || fail "expanded bottom card must cap height against the screen"
grep -q 'questionmark.circle' "$MAP_HOME" || fail "spot help must live in the expanded header instead of a chip row"
test -f "$ROOT/App/FavoriteListView.swift" || fail "favorites must have a searchable list sheet"
test -f "$ROOT/Shared/FavoriteMapPin.swift" || fail "favorites must project map pins from the shared store"
grep -q 'FavoritePinAnnotation' "$MAP_BRIDGE" || fail "the map must render favorite pins"
grep -q 'onFavoritePinTap' "$MAP_HOME" || fail "tapping a favorite pin must reach the map home"
grep -q 'stopWalk' "$ROOT/Shared/SpotActivitySnapshot.swift" \
  || fail "physical walking must expose a Live Activity stop action"
grep -q 'case .favorites' "$MAP_HOME" || fail "map home must present the favorite list sheet"
test -f "$ROOT/docs/onboarding-screenshots/README.md" \
  || fail "community tutorial originals must have a documented screenshot directory"
grep -q 'uri.amap.com' "$ROOT/Shared/MapLinkParser.swift" || fail "Amap marker links must be recognized"
grep -q 'map.baidu.com' "$ROOT/Shared/MapLinkParser.swift" || fail "Baidu map links must be recognized"
grep -q 'map.qq.com' "$ROOT/Shared/MapLinkParser.swift" || fail "Tencent map links must be recognized"
grep -q 'bd09ToGcj02' "$ROOT/Shared/CoordinateConverter.swift" \
  || fail "Baidu BD-09 coordinates must convert to GCJ-02 at the input boundary"
test -f "$ROOT/Shared/RecentSelectionStore.swift" || fail "recent discrete selections must have a dedicated store"
grep -q 'static let limit = 10' "$ROOT/Shared/RecentSelectionStore.swift" || fail "recent selections must keep at most 10 items"
grep -q 'rememberDiscreteSelection' "$MAP_HOME" || fail "discrete map selections must record recent history"
! grep -A20 'onUserCenterChanged:' "$MAP_HOME" | grep -q 'rememberDiscreteSelection' \
  || fail "panning the map must not record recent selection history"
grep -q 'Text("最近")' "$MAP_HOME" || fail "map home must show a recent-selection chip row"
grep -q '代理正常' "$MAP_HOME" || fail "map home must show keep-alive healthy status"
grep -q '保活中断' "$MAP_HOME" || fail "map home must show keep-alive interruption"
grep -q '代理未运行' "$MAP_HOME" || fail "map home must show proxy stopped status"
grep -q '模块已连接' "$MAP_HOME" || fail "map home must show third-party module connection status"
grep -q '@Published private(set) var isHealthy' "$KEEP_ALIVE" || fail "keep-alive must publish health on the main object"
grep -q 'Label("排序"' "$ROOT/App/FavoriteListView.swift" || fail "favorite list must expose a sort menu"
grep -q 'displayedFavorites' "$MAP_HOME" || fail "home favorite chips must share the sorted favorite order"
grep -q 'displayedFavorites' "$ROOT/App/FavoriteListView.swift" || fail "favorite list must share the sorted favorite order"
grep -q 'setSortOrder' "$ROOT/Shared/FavoriteLocationStore.swift" || fail "favorite sort preference must be persistable"
grep -q 'return "出发"' "$MAP_HOME" || fail "after start and end are set, one more tap must depart without a 开始 label"
! grep -q '开始走' "$MAP_HOME" || fail "walking launch must not use 开始走"
! grep -q 'route.end == nil || !route.canPlay' "$MAP_HOME" \
  || fail "a set end pin must not keep the peek button on 设为终点"
grep -q 'if route.phase == .preparing { return false }' "$MAP_HOME" \
  || fail "walking peek must stay tappable after start and end pins are set"
grep -q 'if route.start == nil || route.end == nil { return "先设起点和终点" }' "$MAP_HOME" \
  || fail "collapsed walking caption must not say 先设起点和终点 after both pins are set"
grep -q 'Button("已存路线")' "$ROOT/App/RoutePlaybackPanel.swift" || fail "route panel must expose saved routes"
grep -q 'struct RunningRouteSpotNotice' "$MAP_HOME" || fail "spot card must use a distinct running-route notice while playback continues"
grep -q 'showsSpotHelp: spoofState != .idle && !routeKeepsRunningWhileSpotShown' "$MAP_HOME" \
  || fail "idle and running-route states must hide the spot help control"
grep -q 'if routeKeepsRunningWhileSpotShown { return .orange }' "$MAP_HOME" || fail "spot peek must use the running-route color while playback continues"
if grep -A6 'Text("回到走路")' "$MAP_HOME" | grep -q 'CapsuleChipStyle'; then
  fail "回到走路 must not reuse the help chip style"
fi
grep -A2 'if showsRoute {' "$ROOT/App/MapHomeBottomCard.swift" | grep -q 'routePanel' \
  || fail "the walking panel must layout outside the spot height cap"
if grep -A2 'if showsRoute {' "$ROOT/App/MapHomeBottomCard.swift" | grep -q 'ScrollView'; then
  fail "the walking panel must not be clipped by the spot-card height cap"
fi
! grep -q 'Label("走路"' "$MAP_HOME" || fail "route walking must not have a second entry in the top menu"
grep -q 'route.enter()' "$MAP_HOME" || fail "opening a route must not use the current real or spoofed location as the start"
grep -q 'route.load(saved)' "$MAP_HOME" || fail "saved routes must restore into the playback controller"
! grep -A8 'func load' "$ROOT/Shared/RoutePlaybackController.swift" | grep -q 'enter(' \
  || fail "loading a saved route must not go through enter() and clear the pins"
! grep -q 'routeDeparturePair' "$MAP_HOME" || fail "route start must not be derived from GPS or the active spoofed point"
grep -q '直接出现在起点' "$ROOT/Shared/RoutePlaybackController.swift" \
  || fail "playback must jump to the chosen start instead of walking from the current location"
grep -q 'route.start == nil ? "起点" : "起点已设"' "$ROOT/App/RoutePlaybackPanel.swift" \
  || fail "route panel must let the user set a start pin"
grep -q 'route.end == nil ? "终点" : "终点已设"' "$ROOT/App/RoutePlaybackPanel.swift" \
  || fail "route panel must let the user set an end pin"
if grep -A18 'private func pinButton' "$ROOT/App/RoutePlaybackPanel.swift" | grep -q 'minHeight: 44'; then
  fail "start and end pin chips must not use a full 44pt visual height"
fi
grep -A18 'private func pinButton' "$ROOT/App/RoutePlaybackPanel.swift" | grep -q 'minHeight: 32' \
  || fail "start and end pin chips must match the compact capsule visual height"
grep -q 'MKDirections' "$ROOT/Shared/RouteDirections.swift" || fail "route playback must request along-road directions"
grep -q 'markerCoordinate' "$MAP_BRIDGE" || fail "the map must show the moving virtual location"
grep -q '正在从起点沿路走到终点' "$ROOT/Shared/RoutePlaybackController+Status.swift" \
  || fail "route playback must keep the spoofed location moving along the chosen path"
if grep -A12 'onChange(of: scenePhase)' "$MAP_HOME" | grep -q 'route.pause()'; then
  fail "leaving the app must not pause route playback"
fi
grep -q 'MKPolyline' "$MAP_BRIDGE" || fail "the map bridge must draw the route as MKPolyline"
grep -q 'func updateSpoofedWGS84' "$ROOT/App/LocationActionCoordinator.swift" \
  || fail "APP-mode route ticks must write exact WGS-84 without going through applyVerified"
grep -q 'randomRadius: offsetMeters' "$ROOT/App/SpoofSession.swift" || fail "route ticks must use the user-selected offset as third-party randomRadius"
grep -q 'speedKilometersPerHour' "$ROOT/Shared/RoutePlaybackController.swift" \
  || fail "route playback must expose a custom speed"
grep -q 'offsetMeters' "$ROOT/App/RoutePlaybackPanel.swift" \
  || fail "route panel must expose an offset slider"
grep -q 'figure.walk' "$MAP_HOME" \
  || fail "walking UI must use an iOS 15 SF Symbol"
! grep -q 'curvepath' "$MAP_HOME" "$ROOT/App/RoutePlaybackPanel.swift" \
  || fail "route UI must not use iOS 16-only curvepath symbols"
test -f "$ROOT/Shared/RoutePlayback.swift" || fail "route interpolation helper is missing"
test -f "$ROOT/Shared/RoutePlaybackController.swift" || fail "route playback controller is missing"
test -f "$ROOT/App/RoutePlaybackPanel.swift" || fail "route playback panel is missing"
test -f "$ROOT/Shared/SavedRouteStore.swift" || fail "saved routes must have a dedicated store"
test -f "$ROOT/App/SavedRouteListView.swift" || fail "saved routes must have a list sheet"
grep -q 'routeImport.start' "$ROOT/App/SavedRouteListView.swift" \
  || fail "the saved route list must start the route import coordinator"
grep -q 'Task.detached' "$ROOT/App/RouteImportCoordinator.swift" \
  || fail "route import preparation must leave the main actor"
grep -q 'RouteImportPreparation.prepare' "$ROOT/App/RouteImportCoordinator.swift" \
  || fail "route import coordinator must invoke real preparation"
! grep -q 'Data(contentsOf:' "$ROOT/App/SavedRouteListView.swift" \
  || fail "the saved route list must not read route files synchronously"
test -f "$ROOT/Shared/RouteGPX.swift" || fail "saved routes must import GPX tracks"
test -f "$ROOT/Shared/RouteKML.swift" || fail "saved routes must import KML tracks"
grep -q 'RouteGPX.decode' "$ROOT/Shared/RouteImportPreparation.swift" \
  || fail "route import preparation must decode GPX files"
grep -q 'RouteKML.decode' "$ROOT/Shared/RouteImportPreparation.swift" \
  || fail "route import preparation must decode KML files"
grep -q 'filenameExtension: ext' "$ROOT/App/SavedRouteListView.swift" \
  || fail "the saved route list must accept GPX and KML file types"
grep -q 'enum RouteRepeatMode' "$ROOT/Shared/RoutePlayback.swift" \
  || fail "route playback must expose once, round-trip, and loop modes"
grep -q 'case roundTrip' "$ROOT/Shared/RoutePlayback.swift" || fail "route playback must support round-trip"
grep -q 'case loop' "$ROOT/Shared/RoutePlayback.swift" || fail "route playback must support looping"
grep -q 'return "一次"' "$ROOT/Shared/RoutePlayback.swift" || fail "once mode must be labeled 一次"
grep -q 'return "往返"' "$ROOT/Shared/RoutePlayback.swift" || fail "round-trip mode must be labeled 往返"
grep -q 'return "循环"' "$ROOT/Shared/RoutePlayback.swift" || fail "loop mode must be labeled 循环"
grep -q 'case drive' "$ROOT/Shared/RoutePlayback.swift" || fail "route playback must support driving"
grep -q 'return "驾车"' "$ROOT/Shared/RoutePlayback.swift" || fail "drive mode must be labeled 驾车"
grep -q 'var mapKitTransportTypes' "$ROOT/Shared/RouteDirections.swift" \
  || fail "travel modes must declare MapKit transport types"
grep -q 'case .drive: return \[.automobile\]' "$ROOT/Shared/RouteDirections.swift" \
  || fail "driving must prefer automobile directions"
grep -q 'RouteRepeatMode' "$ROOT/App/RoutePlaybackPanel.swift" || fail "route panel must expose repeat modes"
grep -q 'Button("保存")' "$ROOT/App/RoutePlaybackPanel.swift" || fail "route panel must let the user save a route"
grep -q 'case .savedRoutes' "$MAP_HOME" || fail "map home must present the saved route list sheet"
grep -q 'playbackOrigin = Date()' "$ROOT/Shared/RoutePlaybackController.swift" \
  || fail "reversing a route leg must reset the playback clock"
grep -q 'headingForward' "$ROOT/Shared/RoutePlaybackController.swift" \
  || fail "round-trip and loop playback must track heading"
grep -q 'static let maxViaCount = 10' "$ROOT/Shared/RoutePlaybackController.swift" \
  || fail "routes must allow ten via points"
grep -q 'static let limit = 50' "$ROOT/Shared/SavedRouteStore.swift" \
  || fail "saved routes must keep fifty entries"
test -f "$ROOT/Shared/MapDisplayStyle.swift" || fail "map layers must have a persisted display style"
grep -q 'mapDisplayStyle' "$MAP_BRIDGE" || fail "the map bridge must apply the selected map layer"
grep -q 'accessibilityLabel("地图图层")' "$MAP_HOME" || fail "map layers must be switchable from the home map"
grep -q 'developerSpotWGS84' "$ROOT/App/SpoofSession.swift" \
  || fail "developer-tunnel spots must be offset before push"
grep -q 'strideMeters' "$ROOT/Shared/PhysicalWalkStore.swift" \
  || fail "physical walking must persist a step-fallback stride"
grep -q '定点推送前会偏移' "$SETTINGS_VIEW" \
  || fail "developer-tunnel settings must explain spot offset before push"
grep -q 'Button("倒着走")' "$ROOT/App/RoutePlaybackPanel.swift" || fail "route panel must let the user reverse a saved path"
grep -q 'chevron.down' "$ROOT/App/RoutePlaybackPanel.swift" || fail "speed and offset must stay collapsed by default"
grep -q 'formattedRemaining' "$ROOT/Shared/RoutePlayback.swift" || fail "playback must format remaining distance and time"
grep -q '还剩' "$ROOT/Shared/RoutePlayback.swift" || fail "walking status must show remaining distance"
grep -q 'setVisibleMapRect' "$ROOT/App/RouteMapAnnotations.swift" \
  || fail "the map must fit the whole route in view"
grep -q 'func fitRoute' "$MAP_STATE" || fail "map state must expose a fit-route camera command"
grep -q 'onChange(of: route.pathRevision)' "$MAP_HOME" || fail "fitting the route must happen when the path is ready"
if grep -q 'onChange(of: route.progress)' "$MAP_HOME"; then
  fail "playback ticks must not invalidate the home view"
fi
grep -q 'playbackClock' "$MAP_BRIDGE" || fail "map progress must follow the playback clock"
grep -q 'SpoofSelectionSwitch.needsSwitch' "$MAP_HOME" \
  || fail "switch button must compare the last written coordinate"
grep -q 'writtenLatitude: wgs.latitude' "$ROOT/App/SpoofSession.swift" \
  || fail "route writes must record the coordinate that was actually applied"
test -f "$ROOT/Shared/RoutePlaybackClock.swift" \
  || fail "playback progress must publish separately from the route structure"
grep -q 'overlayPins' "$MAP_HOME" || fail "the map must receive start, via, and end pins"
grep -q 'return "起"' "$ROOT/App/RouteMapAnnotations.swift" || fail "the start pin must be labeled 起"
grep -q 'return "终"' "$ROOT/App/RouteMapAnnotations.swift" || fail "the end pin must be labeled 终"
grep -q 'viaPoints' "$ROOT/Shared/SavedRouteStore.swift" || fail "saved routes must persist via points"
grep -q 'Button("覆盖")' "$MAP_HOME" || fail "saving an opened route must offer overwrite"
grep -q 'overwrite: true' "$MAP_HOME" || fail "overwrite must reuse the saved route identity"
grep -q 'func removeVia' "$ROOT/Shared/RoutePlaybackController.swift" \
  || fail "via points must be deletable by index"
grep -q 'onRoutePinTap' "$MAP_HOME" || fail "tapping a via pin must reach the map home"
grep -q 'didSelect' "$MAP_BRIDGE" || fail "the map must detect taps on route pins"
grep -q 'indexOfVia' "$ROOT/Shared/RoutePlaybackController.swift" \
  || fail "dropping a pin on an existing via must replace it"
test -f "$ROOT/Shared/RoutePlaybackPreferences.swift" || fail "speed and offset must persist across launches"
grep -q 'RoutePlaybackPreferenceStore' "$ROOT/Shared/RoutePlaybackController.swift" \
  || fail "route playback must remember the last speed and offset"
if grep -A12 'onChange(of: scenePhase)' "$MAP_HOME" | grep -q 'route.pause()'; then
  fail "leaving the app must not pause route playback"
fi
if grep -Rq 'RoutePlayback' "$ROOT/ThirdParty/WlocScripts"; then
  fail "straight-line route playback must not modify vendored WLOC scripts"
fi
if grep -Rq 'SavedRoute' "$ROOT/ThirdParty/WlocScripts"; then
  fail "saved routes must not modify vendored WLOC scripts"
fi

echo "PASS: map location state refactor contract"
