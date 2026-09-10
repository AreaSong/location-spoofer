#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

test -f "$ROOT/App/ProxyManager.swift" || fail "ProxyManager must exist"
test -f "$ROOT/Shared/RuntimeLog.swift" || fail "RuntimeLog must exist"
test -f "$ROOT/App/RealtimeLocationManager.swift" || fail "RealtimeLocationManager must exist"
grep -q 'Location Spoofer CA' "$ROOT/App/FirstSetupView.swift" || fail "certificate setup must use the stable app-branded CA name"
! grep -q 'WLOC CA' "$ROOT/App/FirstSetupView.swift" || fail "certificate setup must not show the legacy dated CA name"
grep -q 'localWiFiRuntimeModeInitialized' "$ROOT/Shared/ProxyRuntimeMode.swift" || fail "APP mode initialization must persist independently"
grep -q 'thirdPartyRuntimeModeInitialized' "$ROOT/Shared/ProxyRuntimeMode.swift" || fail "third-party mode initialization must persist independently"
! grep -q 'runVerificationTest' "$ROOT/App/ContentView.swift" || fail "normal app startup must not run the environment verification test"
grep -q '重置证书' "$ROOT/App/SettingsView.swift" || fail "APP mode settings must expose certificate reset"
grep -q 'certificateStore.reset()' "$ROOT/App/SettingsView.swift" || fail "certificate reset must remove the persisted app CA"
grep -q 'requestCertificateSetup()' "$ROOT/App/SettingsView.swift" || fail "certificate reset must open the certificate setup flow"
grep -q 'requestThirdPartyOnboarding()' "$ROOT/App/SettingsView.swift" || fail "third-party settings must keep a manual setup-guide action"
grep -q 'SFSafariViewController' "$ROOT/App/SafariView.swift" || fail "certificate download must use an in-app Safari service"
grep -q 'prepareCertificateDownloadURL' "$ROOT/App/FirstSetupView.swift" || fail "certificate setup must prepare an in-app download URL"
! grep -q 'UIApplication.shared.open(url' "$ROOT/App/ProxyManager.swift" || fail "certificate download must not force an external browser"
grep -q 'AppModeWiFiProxy' "$ROOT/App/FirstSetupView.swift" || fail "APP proxy setup must show the Wi-Fi screenshot"
grep -q 'AppModeCertificateInstall' "$ROOT/App/FirstSetupView.swift" || fail "certificate install setup must show its screenshot"
grep -q 'AppModeCertificateTrust' "$ROOT/App/FirstSetupView.swift" || fail "certificate trust setup must show its screenshot"
grep -q 'UIImage(named: assetName)' "$ROOT/App/FirstSetupView.swift" || fail "missing screenshots must fall back to text without breaking setup"

for asset in AppModeWiFiProxy AppModeCertificateInstall AppModeCertificateTrust; do
  test -s "$ROOT/Resources/Assets.xcassets/$asset.imageset/Contents.json" \
    || fail "missing APP onboarding image asset: $asset"
  grep -q '\.jpg' "$ROOT/Resources/Assets.xcassets/$asset.imageset/Contents.json" \
    || fail "APP onboarding derivatives must use an Asset Catalog-supported JPEG: $asset"
done
test -s "$ROOT/docs/onboarding-screenshots/app-mode/app-mode-wifi-proxy.jpg" \
  || fail "unannotated APP-mode source screenshots must be retained by mode"
test -s "$ROOT/docs/app-icon-source.svg" || fail "the optimized app icon must retain an editable vector source"
test -s "$ROOT/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" \
  || fail "the optimized 1024px app icon is missing"

# VPNManager and Tunnel must NOT exist
test ! -f "$ROOT/App/VPNManager.swift" || fail "VPNManager must be removed"
test ! -d "$ROOT/Tunnel" || fail "Tunnel directory must be removed"

# MobileConfigGenerator removed (unusable)
test ! -f "$ROOT/Shared/MobileConfigGenerator.swift" || fail "MobileConfigGenerator must be removed"

# No duplicate flow test logic
grep -q 'func runVerificationTest' "$ROOT/App/SetupCoordinator.swift" || fail "runVerificationTest must exist in SetupCoordinator"
if grep -q 'func runFullFlowTest' "$ROOT/App/LocationActionCoordinator.swift"; then
  fail "runFullFlowTest duplicate logic must be removed"
fi

echo "PASS: iOS compilation contract"
