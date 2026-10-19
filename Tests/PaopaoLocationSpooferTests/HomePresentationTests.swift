import XCTest
@testable import PaopaoLocationSpoofer

final class HomePresentationTests: XCTestCase {
    func testSelectingNewSpotKeepsStopAccessible() {
        XCTAssertEqual(HomeSecondaryAction.resolve(routePhase: .inactive, waiting: false,
                       showsRoute: false, spoofState: .active, needsSwitch: true), .stopLocation)
        XCTAssertNil(HomeSecondaryAction.resolve(routePhase: .inactive, waiting: false,
                     showsRoute: false, spoofState: .active, needsSwitch: false))
    }

    func testRunningRouteOwnsSecondaryActionEvenOnSpotTab() {
        for phase in [RoutePhase.playing, .paused] {
            for showsRoute in [false, true] {
                XCTAssertEqual(HomeSecondaryAction.resolve(routePhase: phase, waiting: false,
                               showsRoute: showsRoute, spoofState: .active, needsSwitch: true), .exitRoute)
            }
        }
    }

    func testPendingRouteCanBeCancelledWithoutStoppingSpotDirectly() {
        XCTAssertEqual(HomeSecondaryAction.resolve(routePhase: .preparing, waiting: true,
                       showsRoute: false, spoofState: .verifying, needsSwitch: false), .exitRoute)
    }

    func testDraftRouteDoesNotStealSpotStopOntoTheRouteCard() {
        for phase in [RoutePhase.preparing, .finished] {
            XCTAssertNil(HomeSecondaryAction.resolve(routePhase: phase, waiting: false,
                         showsRoute: true, spoofState: .active, needsSwitch: false))
            XCTAssertNil(HomeSecondaryAction.resolve(routePhase: phase, waiting: false,
                         showsRoute: true, spoofState: .idle, needsSwitch: false))
        }
    }
}

@MainActor
final class MapHomeSheetBoxTests: XCTestCase {
    func testSettingsPresentsThroughSystemSheetLikeLogs() {
        let box = MapHomeSheetBox()

        box.present(.logs)
        XCTAssertEqual(box.activeSheet?.kind, .logs)

        box.activeSheet = nil
        box.present(.settings)

        // 设置页走同一个 .sheet(item:)，才有卡片滑入和下拉关闭。
        XCTAssertEqual(box.activeSheet?.kind, .settings)
    }

    func testReopeningSettingsGetsFreshSheetIdentity() {
        let box = MapHomeSheetBox()
        box.present(.settings)
        let first = box.activeSheet?.id

        box.activeSheet = nil
        let reopened = expectation(description: "settings reopened")
        box.present(.settings)
        // 刚关闭后再点会延后一帧重新呈现；identity 必须换新，SwiftUI 才会再次 present。
        DispatchQueue.main.async {
            XCTAssertEqual(box.activeSheet?.kind, .settings)
            XCTAssertNotEqual(box.activeSheet?.id, first)
            reopened.fulfill()
        }
        wait(for: [reopened], timeout: 1)
    }
}

