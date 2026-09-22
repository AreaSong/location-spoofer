import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class ProxyRuntimeModeTests: XCTestCase {
    func testDefaultsToLocalWiFiAndPersistsThirdPartyMode() {
        let suiteName = "ProxyRuntimeModeTests.\(UUID().uuidString)"
        let legacySuiteName = "ProxyRuntimeModeLegacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let legacyDefaults = UserDefaults(suiteName: legacySuiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            legacyDefaults.removePersistentDomain(forName: legacySuiteName)
        }

        let initial = ProxyRuntimeModeStore(defaults: defaults, legacyDefaults: legacyDefaults)
        XCTAssertEqual(initial.mode, .localWiFi)
        XCTAssertFalse(initial.hasSelectedMode)
        XCTAssertFalse(initial.isInitialized(.localWiFi))
        XCTAssertFalse(initial.isInitialized(.thirdParty))
        XCTAssertFalse(initial.isInitialized(.developerTunnel))

        initial.setMode(.thirdParty)
        initial.markInitialized(.thirdParty)
        let restored = ProxyRuntimeModeStore(defaults: defaults, legacyDefaults: legacyDefaults)
        XCTAssertEqual(restored.mode, .thirdParty)
        XCTAssertTrue(restored.hasSelectedMode)
        XCTAssertFalse(restored.isInitialized(.localWiFi))
        XCTAssertTrue(restored.isInitialized(.thirdParty))
        restored.markInitialized(.developerTunnel)
        XCTAssertTrue(ProxyRuntimeModeStore(defaults: defaults, legacyDefaults: legacyDefaults).isInitialized(.developerTunnel))

        restored.resetInitialization(.thirdParty)
        XCTAssertFalse(restored.isInitialized(.thirdParty))
    }

    func testMigratesOnlyCurrentLegacyCompletedMode() {
        let suiteName = "ProxyRuntimeModeMigrationTests.\(UUID().uuidString)"
        let legacySuiteName = "ProxyRuntimeModeMigrationLegacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let legacyDefaults = UserDefaults(suiteName: legacySuiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            legacyDefaults.removePersistentDomain(forName: legacySuiteName)
        }

        defaults.set(ProxyRuntimeMode.thirdParty.rawValue, forKey: "proxyRuntimeMode")
        defaults.set(true, forKey: "hasSelectedProxyRuntimeMode")
        legacyDefaults.set(true, forKey: "setupCompleted")

        let migrated = ProxyRuntimeModeStore(defaults: defaults, legacyDefaults: legacyDefaults)
        XCTAssertFalse(migrated.isInitialized(.localWiFi))
        XCTAssertTrue(migrated.isInitialized(.thirdParty))

        migrated.setMode(.localWiFi)
        XCTAssertFalse(migrated.isInitialized(.localWiFi))
        XCTAssertTrue(migrated.isInitialized(.thirdParty))
    }
}
