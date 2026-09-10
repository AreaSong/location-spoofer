#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

MODE="$ROOT/Shared/ProxyRuntimeMode.swift"
MANAGER="$ROOT/Shared/ThirdPartyProxyManager.swift"
CONTENT="$ROOT/App/ContentView.swift"
SETUP="$ROOT/App/FirstSetupView.swift"
SETTINGS="$ROOT/App/SettingsView.swift"

grep -q 'return "APP模式"' "$MODE" || fail "APP mode display name is missing"
grep -q 'return "第三方代理模式"' "$MODE" || fail "third-party mode display name is missing"
grep -q 'hasSelectedMode' "$MODE" || fail "first-launch mode selection must be persisted"
grep -q 'guard runtimeMode.hasSelectedMode else' "$CONTENT" || fail "mode selection must gate startup"
grep -q 'phase = .setup' "$CONTENT" || fail "first launch must enter setup before map construction"
grep -q 'case thirdPartyClient' "$SETUP" || fail "third-party client selection step is missing"
grep -q 'case thirdPartyImport' "$SETUP" || fail "third-party import step is missing"
! grep -q 'case thirdPartyTest' "$SETUP" || fail "third-party connection test must be part of the import page"
! grep -q '生成并导入配置文件' "$SETUP" || fail "setup must not offer file generation/import"
grep -q '复制模块订阅地址' "$SETUP" || fail "module subscription URL copy action is missing"
grep -Fq 'Label("打开 \(client.name)"' "$SETUP" || fail "setup must expose a client launch action"
grep -Fq 'Label("打开 \(client.name)"' "$SETUP" \
  || fail "the import page must expose the selected client launch action"
grep -Fq 'Label("打开 \(thirdPartyClient.selectedClient.name)"' "$SETTINGS" || fail "Settings must expose a client launch action"
! grep -q '在浏览器打开模块文件' "$SETTINGS" || fail "Settings must not open the module URL as the primary client action"
grep -q 'DisclosureGroup("高级")' "$SETUP" \
  || fail "setup module source switching must live under Advanced"
grep -q 'static let configurationEndpoint' "$MANAGER" \
  || fail "the third-party configuration endpoint must have one shared owner"
grep -q 'randomRadius: Double? = nil' "$MANAGER" \
  || fail "third-party save must allow route playback to force randomRadius 0"
grep -q 'DisclosureGroup("第三方客户端适配说明")' "$SETUP" \
  || fail "client selection must expose the third-party integration contract"
grep -Fq '查询：GET ?action=query' "$SETUP" \
  || fail "client integration guidance must document the query action"
grep -Fq '保存：GET ?lon=<经度>&lat=<纬度>&acc=<精度>' "$SETUP" \
  || fail "client integration guidance must document WGS-84 coordinate saving"
grep -Fq '清除：GET ?action=clear' "$SETUP" \
  || fail "client integration guidance must document the clear action"

CATALOG="$ROOT/Shared/ThirdPartyModuleCatalog.swift"
SERVER="$ROOT/Shared/ThirdPartyModuleServer.swift"
grep -q 'AreaSong/location-spoofer/main/ThirdParty/WlocScripts' "$CATALOG" \
  || fail "third-party subscription must still know the vendored AreaSong module path"
grep -q 'http://127.0.0.1' "$CATALOG" \
  || fail "on-device subscription must use a loopback module server"
grep -q 'case onDevice' "$CATALOG" \
  || fail "module distribution must include on-device source"
grep -q 'enum ThirdPartyModuleRuntime' "$SERVER" \
  || fail "third-party import must start the on-device module server"
grep -q 'WlocScripts' "$ROOT/project.yml" \
  || fail "app bundle must include vendored WlocScripts"
grep -q '保持本 App 打开' "$SETUP" \
  || fail "setup must tell users to keep the app open when importing on-device modules"
grep -q 'APP 模式只支持 Wi-Fi' "$ROOT/Shared/AppModeNetworkRequirement.swift" \
  || fail "APP mode must refuse cellular-only networks"
grep -q '导出模块文件' "$SETTINGS" \
  || fail "Settings must expose on-device module export"
SCRIPTS="$ROOT/ThirdParty/WlocScripts"
test -s "$SCRIPTS/dist/v1/wloc.js" || fail "vendored wloc.js is missing"
test -s "$SCRIPTS/dist/v1/wloc-settings.js" || fail "vendored wloc-settings.js is missing"
for module in wloc.module wloc.sgmodule wloc.conf wloc.lpx wloc.stoverride; do
  test -s "$SCRIPTS/modules/$module" || fail "missing vendored module: $module"
  grep -q 'AreaSong/location-spoofer/main/ThirdParty/WlocScripts/dist/v1/' "$SCRIPTS/modules/$module" \
    || fail "$module script-path must point at vendored dist scripts"
  grep -q 'wloc-settings' "$SCRIPTS/modules/$module" \
    || fail "$module must intercept /wloc-settings/save"
  ! grep -q 'Yu9191/wloc' "$SCRIPTS/modules/$module" \
    || fail "$module must not depend on Yu9191/wloc"
done
grep -q 'wloc.sgmodule' "$MANAGER" || fail "Surge/Egern module mapping is missing"
grep -q 'wloc.stoverride' "$MANAGER" || fail "Stash must use .stoverride directly"
grep -q 'shadowrocket://' "$MANAGER" || fail "Shadowrocket launch URL is missing"
for scheme in surge quantumult-x loon stash egern; do
  grep -q "${scheme}://" "$MANAGER" || fail "$scheme launch URL is missing"
done
grep -q '复制解密域名' "$SETUP" || fail "all clients must expose the MITM hostname copy action"
grep -q '配置时请复制下方全部解密域名' "$SETUP" \
  || fail "setup guidance must direct users to copy all Apple location hostnames"
grep -q 'ThirdPartyProxyManager.interceptionHostnamesText' "$SETUP" \
  || fail "setup hostname copy actions must use the shared interception hostname value"
grep -q 'ThirdPartyProxyManager.interceptionHostnamesText' "$SETTINGS" \
  || fail "Settings must expose the shared interception hostname copy action"
grep -q '配置 → 模块' "$SETUP" || fail "Shadowrocket module import guidance is missing"
grep -q 'HTTPS 解密' "$SETUP" || fail "Shadowrocket HTTPS decryption guidance is missing"
! grep -q '当前可测试' "$SETUP" || fail "Shadowrocket must not show the obsolete current-test label"
! grep -q '当前可测试' "$SETTINGS" || fail "Settings must not show the obsolete current-test label"
grep -q 'thirdPartyTestFailure = ThirdPartyConnectionTestFailure' "$SETUP" \
  || fail "third-party connection failures must render inline on the import page"
grep -q 'testResultView(' "$SETUP" || fail "APP and third-party tests must share the same result component"
grep -q 'showsVerificationResult = false' "$SETUP" \
  || fail "switching setup pages must hide the shared APP verification result"
grep -q 'showsThirdPartyFailureLog = false' "$SETUP" \
  || fail "switching setup pages must hide the shared third-party test log"
grep -q 'Label("查看诊断日志"' "$SETUP" \
  || fail "third-party connection failure must expose the diagnostics action"
! grep -q 'setupActionError = error.localizedDescription' "$SETUP" \
  || fail "third-party connection failure must not use the generic failure alert"
grep -q 'let response = try await thirdPartyProxy.query()' "$SETUP" \
  || fail "the import page must validate the save/query endpoint"
grep -A20 'let response = try await thirdPartyProxy.query()' "$SETUP" | grep -q 'onComplete()' \
  || fail "a successful third-party connection test must close setup immediately"
grep -q 'components.queryItems = \[URLQueryItem(name: "action", value: "query")\]' "$MANAGER" \
  || fail "the connection test must preserve the established save?action=query contract"
grep -B4 'Toggle("运动状态模拟"' "$SETTINGS" | grep -q 'runtimeMode.mode == .localWiFi' \
  || fail "the motion-state toggle must only appear in APP mode"
grep -q 'Toggle("随机扰动"' "$SETTINGS" \
  || fail "the random-perturbation toggle must remain in Settings"
! grep -q 'validateVersion\|refreshAdvancedFeatureAvailability\|moduleUpdateRecommended' \
    "$SETUP" "$SETTINGS" "$MANAGER" \
  || fail "script version detection must be removed from the app"
! grep -q 'thirdPartyTestResult?.success' "$SETUP" \
  || fail "a successful third-party test must not leave a separate completion state"
grep -q 'setupStep = \.thirdPartyImport' "$ROOT/App/SetupCoordinator.swift" \
  || fail "third-party import guide must remain available from setup"
grep -q '当前不能使用定位修改' "$ROOT/Shared/LocationUseAvailability.swift" \
  || fail "third-party runtime failures must stay on the map with a large unavailable prompt"
grep -q 'LocationUseBlock.title' "$ROOT/App/MapHomeView.swift" \
  || fail "the map must render the shared unavailable prompt title"
grep -q 'LocationUseBlock.openSettingsTitle' "$ROOT/App/MapHomeView.swift" \
  || fail "the unavailable prompt must open Settings"
! grep -q 'setup.requestThirdPartySetup' "$ROOT/App/MapHomeView.swift" \
  || fail "third-party coordinate sync failures must not cover the map with setup"
grep -q '检测到第三方代理连接异常，请检查模块、MITM 和代理连接后重新检测' "$SETUP" \
  || fail "runtime repair must explain why the import guide opened"
test "$(grep -c 'title: \"接口连接失败\"' "$SETUP")" -eq 1 \
  || fail "third-party failure details must render in one shared result area"
grep -Fq '当前客户端：\(client.name)' "$SETUP" \
  || fail "third-party failure logs must identify the selected client"
grep -q 'HStack(spacing: 12)' "$SETUP" || fail "setup footer actions must share one horizontal row"
grep -q 'Spacer(minLength: 12)' "$SETUP" || fail "setup footer actions must stay at opposite edges"
grep -q 'ScrollViewReader' "$SETUP" || fail "setup must keep failure results reachable after insertion"
grep -q 'scrollProxy.scrollTo("thirdPartyFailureLog"' "$SETUP" \
  || fail "third-party failure must scroll to the detailed log"
grep -q '======== 第三方代理连接检测 ========' "$SETUP" \
  || fail "third-party inline diagnostics must include a structured test log"
grep -Fq '原因：\(diagnosis.title)' "$SETUP" \
  || fail "third-party failure logs must show a human-readable cause"
! grep -q '错误类型：' "$SETUP" \
  || fail "third-party failure logs must not expose Swift error types"
! grep -q '错误详情：' "$SETUP" \
  || fail "third-party failure logs must not dump raw error details"
! grep -q '错误代码' "$SETUP" "$SETTINGS" "$ROOT/App/MapHomeView.swift" "$ROOT/App/DiagnosticsView.swift" \
  || fail "user-facing third-party errors must not show error codes"
grep -q 'case certificateUntrusted' "$MANAGER" \
  || fail "certificate trust failures must be classified separately"
grep -q 'case proxyNotConnected' "$MANAGER" \
  || fail "proxy connectivity failures must be classified separately"
grep -Fq 'Label("第 2 步：完成 \(client.name) 配置"' "$SETUP" \
  || fail "unverified clients must use a two-step import and configuration guide"
grep -Fq 'Text("请在 \(client.name) 中完成相应配置。")' "$SETUP" \
  || fail "unverified client configuration guidance must avoid unverified menu details"
! grep -q '进入模块、重写或覆写订阅入口' "$SETUP" \
  || fail "unverified clients must not claim untested menu locations"
grep -q '"当前客户端": client.name' "$SETUP" \
  || fail "third-party runtime diagnostics must identify the selected client"
for asset in ShadowrocketModuleImport ShadowrocketConfigDetails ShadowrocketHTTPSDecryption ShadowrocketHTTPSCA; do
  test -s "$ROOT/Resources/Assets.xcassets/$asset.imageset/Contents.json" \
    || fail "missing Shadowrocket onboarding image asset: $asset"
  grep -q '\.jpg' "$ROOT/Resources/Assets.xcassets/$asset.imageset/Contents.json" \
    || fail "Shadowrocket onboarding derivatives must use an Asset Catalog-supported JPEG: $asset"
  grep -q "$asset" "$SETUP" || fail "setup does not reference onboarding image asset: $asset"
done
config_line="$(grep -n 'assetName: "ShadowrocketConfigDetails"' "$SETUP" | head -n 1 | cut -d: -f1)"
module_line="$(grep -n 'assetName: "ShadowrocketModuleImport"' "$SETUP" | head -n 1 | cut -d: -f1)"
test "$config_line" -lt "$module_line" || fail "Shadowrocket setup must show the configuration page before the module page"
! grep -q 'GeometryReader' "$SETUP" || fail "onboarding image markers must be baked into assets, not positioned at runtime"
test -s "$ROOT/docs/onboarding-screenshots/shadowrocket/shadowrocket-module-import.jpg" \
  || fail "unannotated Shadowrocket source screenshots must be retained by client"
! grep -q 'ToolbarItem(placement: .navigationBarLeading)' "$SETUP" || fail "setup must not show a top-left navigation action"
grep -q 'presentSuccessfulOperationTip(.activation)' "$ROOT/App/MapHomeView.swift" || fail "third-party save must present the activation tip"
grep -q 'presentSuccessfulOperationTip(.deactivation)' "$ROOT/App/MapHomeView.swift" || fail "third-party clear must present the deactivation tip"
grep -q 'if spoofState == .active' "$ROOT/App/MapHomeView.swift" || fail "manual help must follow the shared spoof state"
grep -q 'MARKETING_VERSION: "1.0.6"' "$ROOT/project.yml" || fail "marketing version must be 1.0.6"
grep -q 'CURRENT_PROJECT_VERSION: "7"' "$ROOT/project.yml" || fail "build version must be 7"

echo "PASS: third-party proxy mode contract"
