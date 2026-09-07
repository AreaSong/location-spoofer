import XCTest
@testable import PaopaoLocationSpoofer

final class MapLinkParserTests: XCTestCase {
    func testParsesAppleMapsLLParameterAsWGS84() {
        let parsed = MapLinkParser.parse("https://maps.apple.com/?ll=22.544577,113.94114")

        XCTAssertEqual(parsed?.sourceName, "苹果地图")
        XCTAssertEqual(parsed?.inferredSystem, .wgs84)
        XCTAssertEqual(parsed?.latitude ?? 0, 22.544577, accuracy: 0.000_000_1)
        XCTAssertEqual(parsed?.longitude ?? 0, 113.94114, accuracy: 0.000_000_1)
    }

    func testParsesGoogleMapsAtCoordinateAsWGS84() {
        let parsed = MapLinkParser.parse("https://www.google.com/maps/@22.544577,113.94114,17z")

        XCTAssertEqual(parsed?.sourceName, "谷歌地图")
        XCTAssertEqual(parsed?.inferredSystem, .wgs84)
        XCTAssertEqual(parsed?.latitude ?? 0, 22.544577, accuracy: 0.000_000_1)
        XCTAssertEqual(parsed?.longitude ?? 0, 113.94114, accuracy: 0.000_000_1)
    }

    func testParsesAmapPositionAsLongitudeLatitudeGCJ02() {
        let parsed = MapLinkParser.parse("https://uri.amap.com/marker?position=113.94114,22.544577&name=%E6%B7%B1%E5%9C%B3%E6%B9%BE")

        XCTAssertEqual(parsed?.sourceName, "高德")
        XCTAssertEqual(parsed?.inferredSystem, .gcj02)
        XCTAssertEqual(parsed?.name, "深圳湾")
        XCTAssertEqual(parsed?.latitude ?? 0, 22.544577, accuracy: 0.000_000_1)
        XCTAssertEqual(parsed?.longitude ?? 0, 113.94114, accuracy: 0.000_000_1)
    }

    func testIgnoresLinksWithoutCoordinates() {
        XCTAssertNil(MapLinkParser.parse("https://maps.apple.com/?q=深圳湾"))
        XCTAssertNil(MapLinkParser.parse("https://www.google.com/maps/place/Shanghai"))
        XCTAssertNil(MapLinkParser.parse("https://uri.amap.com/marker?name=深圳湾"))
        XCTAssertNil(MapLinkParser.parse("深圳湾"))
    }
}
