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
