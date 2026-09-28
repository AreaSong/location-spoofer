import XCTest
@testable import PaopaoLocationSpoofer

final class FavoriteMapPinTests: XCTestCase {
    func testPinsUseMapSystemAndMarkSelection() {
        let bay = FavoriteLocation(
            name: "深圳湾",
            latitude: 22.544577,
            longitude: 113.94114,
            accuracy: 15,
            mapCoordinateSystem: .gcj02
        )
        let tower = FavoriteLocation(
            name: "埃菲尔铁塔",
            latitude: 48.85837,
            longitude: 2.294481,
            accuracy: 20,
            mapCoordinateSystem: .wgs84
        )
        let pins = FavoriteMapPin.pins(
            from: [bay, tower],
            selectedID: tower.id,
            mapSystem: .gcj02
        )
        XCTAssertEqual(pins.count, 2)
        XCTAssertEqual(pins[0].name, "深圳湾")
        XCTAssertEqual(pins[0].latitude, bay.coordinatePair.gcj02.latitude, accuracy: 0.000_000_1)
        XCTAssertFalse(pins[0].isSelected)
        XCTAssertEqual(pins[1].id, tower.id)
        XCTAssertTrue(pins[1].isSelected)
        XCTAssertEqual(pins[1].latitude, tower.coordinatePair.gcj02.latitude, accuracy: 0.000_000_1)
    }
}
