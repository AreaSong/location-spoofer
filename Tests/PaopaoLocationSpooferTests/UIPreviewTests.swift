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
}
