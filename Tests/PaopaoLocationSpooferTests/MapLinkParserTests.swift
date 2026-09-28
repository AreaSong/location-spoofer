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
        XCTAssertNil(MapLinkParser.parse("https://j.map.baidu.com/share"))
        XCTAssertNil(MapLinkParser.parse("https://map.qq.com/m/place/info?name=深圳湾"))
        XCTAssertNil(MapLinkParser.parse("深圳湾"))
    }

    func testParsesBaiduMarkerAsBD09ConvertedToGCJ02() {
        let gcjLat = 22.544577
        let gcjLon = 113.94114
        let bd = CoordinateConverter.gcj02ToBd09(lat: gcjLat, lon: gcjLon)
        let title = "深圳湾".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "深圳湾"
        let parsed = MapLinkParser.parse(
            "baidumap://map/marker?location=\(bd.lat),\(bd.lon)&title=\(title)"
        )

        XCTAssertEqual(parsed?.sourceName, "百度地图")
        XCTAssertEqual(parsed?.inferredSystem, .gcj02)
        XCTAssertEqual(parsed?.name, "深圳湾")
        XCTAssertEqual(parsed?.latitude ?? 0, gcjLat, accuracy: 0.000_001)
        XCTAssertEqual(parsed?.longitude ?? 0, gcjLon, accuracy: 0.000_001)
    }

    func testParsesBaiduWebLatlngWithExplicitGcj02() {
        let parsed = MapLinkParser.parse(
            "https://map.baidu.com/?latlng=22.544577,113.94114&coord_type=gcj02&title=深圳湾"
        )

        XCTAssertEqual(parsed?.sourceName, "百度地图")
        XCTAssertEqual(parsed?.inferredSystem, .gcj02)
        XCTAssertEqual(parsed?.name, "深圳湾")
        XCTAssertEqual(parsed?.latitude ?? 0, 22.544577, accuracy: 0.000_000_1)
        XCTAssertEqual(parsed?.longitude ?? 0, 113.94114, accuracy: 0.000_000_1)
    }

    func testParsesBaiduWgs84CoordTypeWithoutBD09Shift() {
        let parsed = MapLinkParser.parse(
            "https://api.map.baidu.com/marker?location=22.544577,113.94114&coord_type=wgs84&title=深圳湾"
        )

        XCTAssertEqual(parsed?.inferredSystem, .wgs84)
        XCTAssertEqual(parsed?.latitude ?? 0, 22.544577, accuracy: 0.000_000_1)
        XCTAssertEqual(parsed?.longitude ?? 0, 113.94114, accuracy: 0.000_000_1)
    }

    func testIgnoresBaiduMercatorCoordType() {
        XCTAssertNil(MapLinkParser.parse(
            "https://map.baidu.com/?latlng=22.544577,113.94114&coord_type=bd09mc"
        ))
    }

    func testParsesTencentPointXYAsGCJ02() {
        let parsed = MapLinkParser.parse(
            "https://map.qq.com/?type=marker&pointx=113.94114&pointy=22.544577&name=%E6%B7%B1%E5%9C%B3%E6%B9%BE"
        )

        XCTAssertEqual(parsed?.sourceName, "腾讯地图")
        XCTAssertEqual(parsed?.inferredSystem, .gcj02)
        XCTAssertEqual(parsed?.name, "深圳湾")
        XCTAssertEqual(parsed?.latitude ?? 0, 22.544577, accuracy: 0.000_000_1)
        XCTAssertEqual(parsed?.longitude ?? 0, 113.94114, accuracy: 0.000_000_1)
    }

    func testParsesTencentURIMarkerAndAppScheme() {
        let uri = MapLinkParser.parse(
            "https://apis.map.qq.com/uri/v1/marker?marker=coord:22.544577,113.94114;title:深圳湾;addr:南山"
        )
        let app = MapLinkParser.parse("qqmap://map/marker?coord=22.544577,113.94114&title=湾区")

        XCTAssertEqual(uri?.sourceName, "腾讯地图")
        XCTAssertEqual(uri?.name, "深圳湾")
        XCTAssertEqual(uri?.latitude ?? 0, 22.544577, accuracy: 0.000_000_1)
        XCTAssertEqual(uri?.longitude ?? 0, 113.94114, accuracy: 0.000_000_1)
        XCTAssertEqual(app?.name, "湾区")
        XCTAssertEqual(app?.inferredSystem, .gcj02)
        XCTAssertEqual(app?.longitude ?? 0, 113.94114, accuracy: 0.000_000_1)
    }
}
