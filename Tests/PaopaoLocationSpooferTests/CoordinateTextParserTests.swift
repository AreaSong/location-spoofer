import XCTest
@testable import PaopaoLocationSpoofer

final class CoordinateTextParserTests: XCTestCase {
    func testParsesCommaSeparatedLatitudeLongitude() {
        let parsed = CoordinateTextParser.parse("22.544577, 113.94114")

        XCTAssertEqual(parsed?.latitude ?? 0, 22.544577, accuracy: 0.000_000_1)
        XCTAssertEqual(parsed?.longitude ?? 0, 113.94114, accuracy: 0.000_000_1)
    }

    func testParsesChineseCommaAndWhitespace() {
        let parsed = CoordinateTextParser.parse("  22.544577，113.94114  ")

        XCTAssertEqual(parsed?.latitude ?? 0, 22.544577, accuracy: 0.000_000_1)
        XCTAssertEqual(parsed?.longitude ?? 0, 113.94114, accuracy: 0.000_000_1)
    }

    func testSwapsLongitudeLatitudeWhenFirstValueCannotBeLatitude() {
        let parsed = CoordinateTextParser.parse("113.94114 22.544577")

        XCTAssertEqual(parsed?.latitude ?? 0, 22.544577, accuracy: 0.000_000_1)
        XCTAssertEqual(parsed?.longitude ?? 0, 113.94114, accuracy: 0.000_000_1)
    }

    func testRejectsInvalidValuesAndPlaceNames() {
        XCTAssertNil(CoordinateTextParser.parse("深圳湾"))
        XCTAssertNil(CoordinateTextParser.parse("91, 113.94"))
        XCTAssertNil(CoordinateTextParser.parse("22.54"))
        XCTAssertNil(CoordinateTextParser.parse("22.54, 200"))
        XCTAssertNil(CoordinateTextParser.parse(""))
    }
}
