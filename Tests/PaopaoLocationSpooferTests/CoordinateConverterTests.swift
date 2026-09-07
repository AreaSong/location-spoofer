import XCTest
@testable import PaopaoLocationSpoofer

final class CoordinateConverterTests: XCTestCase {
    func testFixedAnchorWhitelistMapsKnownNames() {
        XCTAssertEqual(
            CoordinateConverter.mapCoordinateSystem(forFixedAnchorFirstResultName: "林士街"),
            .gcj02
        )
        XCTAssertEqual(
            CoordinateConverter.mapCoordinateSystem(forFixedAnchorFirstResultName: "Rumsey Street"),
            .gcj02
        )
        XCTAssertEqual(
            CoordinateConverter.mapCoordinateSystem(forFixedAnchorFirstResultName: "rumsey st."),
            .gcj02
        )
        XCTAssertEqual(
            CoordinateConverter.mapCoordinateSystem(forFixedAnchorFirstResultName: "Connaught Road West"),
            .wgs84
        )
    }

    func testFixedAnchorWhitelistAcceptsNormalizedVariants() {
        XCTAssertEqual(
            CoordinateConverter.mapCoordinateSystem(forFixedAnchorFirstResultName: "  林士街  "),
            .gcj02
        )
        XCTAssertEqual(
            CoordinateConverter.mapCoordinateSystem(forFixedAnchorFirstResultName: "RUMSEY\tSTREET"),
            .gcj02
        )
        XCTAssertEqual(
            CoordinateConverter.mapCoordinateSystem(forFixedAnchorFirstResultName: "Rumsey Street, Sheung Wan"),
            .gcj02
        )
        XCTAssertEqual(
            CoordinateConverter.mapCoordinateSystem(forFixedAnchorFirstResultName: "connaught road west, hong kong"),
            .wgs84
        )
    }

    func testUnknownFixedAnchorNameDoesNotDefaultToWGS84() {
        XCTAssertNil(CoordinateConverter.mapCoordinateSystem(forFixedAnchorFirstResultName: "شارع غير معروف"))
        XCTAssertNil(CoordinateConverter.mapCoordinateSystem(forFixedAnchorFirstResultName: "???\u{FFFD}"))
        XCTAssertNil(CoordinateConverter.mapCoordinateSystem(forFixedAnchorFirstResultName: "Central Pier"))
        XCTAssertNil(CoordinateConverter.mapCoordinateSystem(forFixedAnchorFirstResultName: "   "))
        XCTAssertNil(CoordinateConverter.mapCoordinateSystem(forFixedAnchorFirstResultName: ""))
    }

    func testUnknownFixedAnchorNameKeepsRuntimeStandard() {
        let previous = CoordinateConverter.MapCoordinateSystem.gcj02
        let outcome = CoordinateConverter.runtimeRefreshResult(
            previous: previous,
            firstResultName: "شارع غير معروف"
        )

        if case .unavailable = outcome {
            XCTAssertEqual(previous, .gcj02)
        } else {
            XCTFail("未知名称应保留当前标准，实际结果: \(outcome)")
        }
        XCTAssertEqual(
            CoordinateConverter.runtimeRefreshResult(
                previous: .wgs84,
                firstResultName: "Central Pier"
            ),
            .unavailable(reason: "固定锚点名称未列入白名单")
        )
    }

    func testKnownFixedAnchorNameCanSwitchRuntimeStandard() {
        let toWGS = CoordinateConverter.runtimeRefreshResult(
            previous: .gcj02,
            firstResultName: "Connaught Road West"
        )
        let toGCJ = CoordinateConverter.runtimeRefreshResult(
            previous: .wgs84,
            firstResultName: "Rumsey Street"
        )
        let unchanged = CoordinateConverter.runtimeRefreshResult(
            previous: .gcj02,
            firstResultName: "林士街"
        )

        XCTAssertEqual(
            toWGS,
            .changed(.init(previous: .gcj02, current: .wgs84))
        )
        XCTAssertEqual(
            toGCJ,
            .changed(.init(previous: .wgs84, current: .gcj02))
        )
        XCTAssertEqual(unchanged, .unchanged(.gcj02))
    }
}
