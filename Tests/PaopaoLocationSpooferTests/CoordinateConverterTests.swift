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

    func testDisplayLineFormatsSixDecimals() {
        let pair = CoordinatePair(
            wgs84: .init(latitude: 25.276123, longitude: 110.371456),
            gcj02: .init(latitude: 25.279381, longitude: 110.374361)
        )
        XCTAssertEqual(pair.displayLine(for: .gcj02), "25.279381, 110.374361")
        XCTAssertEqual(pair.displayLine(for: .wgs84), "25.276123, 110.371456")
    }

    func testBd09RoundTripsGcj02WithinAMeter() {
        let gcjLat = 22.544577
        let gcjLon = 113.94114
        let bd = CoordinateConverter.gcj02ToBd09(lat: gcjLat, lon: gcjLon)
        let back = CoordinateConverter.bd09ToGcj02(lat: bd.lat, lon: bd.lon)
        XCTAssertNotEqual(bd.lat, gcjLat, accuracy: 0.001)
        XCTAssertEqual(back.lat, gcjLat, accuracy: 0.000_001)
        XCTAssertEqual(back.lon, gcjLon, accuracy: 0.000_001)
    }
}
