import XCTest
@testable import PaopaoLocationSpoofer

final class UIPreviewTests: XCTestCase {
    func testEnableAndDisableStayInsideTheGivenDefaults() {
        let suiteName = "UIPreviewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(UIPreview.isEnabled(defaults: defaults))
        UIPreview.enable(defaults: defaults)
        XCTAssertEqual(UIPreview.isEnabled(defaults: defaults), UIPreview.isAvailable)
        UIPreview.disable(defaults: defaults)
        XCTAssertFalse(UIPreview.isEnabled(defaults: defaults))
    }

    @MainActor
    func testChoosingAModeInsidePreviewDoesNotLeavePreview() {
        let suiteName = "UIPreviewModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let legacy = UserDefaults(suiteName: suiteName + ".legacy")!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            legacy.removePersistentDomain(forName: suiteName + ".legacy")
        }
        let previous = UserDefaults.standard.bool(forKey: UIPreview.storageKey)
        defer { UserDefaults.standard.set(previous, forKey: UIPreview.storageKey) }

        UIPreview.enable()
        let store = ProxyRuntimeModeStore(defaults: defaults, legacyDefaults: legacy)
        store.setMode(.developerTunnel, disablesPreview: false)
        XCTAssertEqual(UIPreview.isEnabled(), UIPreview.isAvailable)
        store.setMode(.localWiFi)
        XCTAssertFalse(UIPreview.isEnabled())
    }
}
