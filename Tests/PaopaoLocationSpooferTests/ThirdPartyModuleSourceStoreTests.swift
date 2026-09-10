import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class ThirdPartyModuleSourceStoreTests: XCTestCase {
    func testMirrorDefaultsToEnabledAndPersists() {
        let suite = "ThirdPartyModuleSourceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ThirdPartyModuleSourceStore(defaults: defaults)
        XCTAssertEqual(store.distribution, .onDevice)
        XCTAssertFalse(store.useMirror)

        store.setDistribution(.remoteMirror)
        XCTAssertTrue(ThirdPartyModuleSourceStore(defaults: defaults).useMirror)
        XCTAssertEqual(ThirdPartyModuleSourceStore(defaults: defaults).distribution, .remoteMirror)

        store.setUseMirror(false)
        XCTAssertEqual(ThirdPartyModuleSourceStore(defaults: defaults).distribution, .remoteDirect)
    }
}
