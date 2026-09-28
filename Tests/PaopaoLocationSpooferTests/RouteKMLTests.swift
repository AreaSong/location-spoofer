import XCTest
@testable import PaopaoLocationSpoofer

final class RouteKMLTests: XCTestCase {
    func testDecodesNamedLineStringAsWalkRouteWithRecordedPath() throws {
        let kml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <name>文件名不要用</name>
            <Placemark>
              <name>湾区慢跑</name>
              <LineString>
                <coordinates>
                  113.951,22.494,0
                  113.952,22.495,0
                  113.953,22.496,0
                </coordinates>
              </LineString>
            </Placemark>
          </Document>
        </kml>
        """
        let routes = try RouteKML.decode(Data(kml.utf8), fallbackName: "导入路线")
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].name, "湾区慢跑")
        XCTAssertEqual(routes[0].travelMode, .walk)
        XCTAssertEqual(routes[0].speedKilometersPerHour, 5, accuracy: 0.01)
        XCTAssertEqual(routes[0].repeatMode, .once)
        XCTAssertEqual(routes[0].pathPoints?.count, 3)
        XCTAssertEqual(routes[0].start.wgs84.longitude, 113.951, accuracy: 0.000_000_1)
        XCTAssertEqual(routes[0].start.wgs84.latitude, 22.494, accuracy: 0.000_000_1)
        XCTAssertEqual(routes[0].end.wgs84.longitude, 113.953, accuracy: 0.000_000_1)
    }

    func testDecodesGxTrackAndFallsBackToFileName() throws {
        let kml = """
        <kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
          <Placemark>
            <gx:Track>
              <when>2020-01-01T00:00:00Z</when>
              <gx:coord>113.951 22.494 0</gx:coord>
              <gx:coord>113.952 22.495 0</gx:coord>
            </gx:Track>
          </Placemark>
        </kml>
        """
        let routes = try RouteKML.decode(Data(kml.utf8), fallbackName: "海岸线")
        XCTAssertEqual(routes[0].name, "海岸线")
        XCTAssertEqual(routes[0].pathPoints?.count, 2)
        XCTAssertEqual(routes[0].start.wgs84.longitude, 113.951, accuracy: 0.000_000_1)
        XCTAssertEqual(routes[0].end.wgs84.latitude, 22.495, accuracy: 0.000_000_1)
    }

    func testDecodesSpacedCommaTuplesAndSkipsTooShort() throws {
        let kml = """
        <kml>
          <Placemark><name>短</name><LineString>
            <coordinates>113.951, 22.494, 0 113.9510001, 22.494, 0</coordinates>
          </LineString></Placemark>
          <Placemark><name>长</name><LineString>
            <coordinates>113.951, 22.494, 0 113.952, 22.495, 0</coordinates>
          </LineString></Placemark>
        </kml>
        """
        let routes = try RouteKML.decode(Data(kml.utf8))
        XCTAssertEqual(routes.map(\.name), ["长"])
    }

    func testDecodesPointPlacemarksWhenNoLineStringExists() throws {
        let kml = """
        <kml>
          <Placemark><Point><coordinates>113.951,22.494,0</coordinates></Point></Placemark>
          <Placemark><Point><coordinates>113.952,22.495,0</coordinates></Point></Placemark>
        </kml>
        """
        let routes = try RouteKML.decode(Data(kml.utf8), fallbackName: "点位连线")
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].name, "点位连线")
        XCTAssertEqual(routes[0].pathPoints?.count, 2)
    }

    func testRejectsEmptyInvalidAndKMZ() {
        XCTAssertThrowsError(try RouteKML.decode(Data("<kml></kml>".utf8))) { error in
            XCTAssertEqual(error as? RouteKML.ParseError, .empty)
        }
        XCTAssertThrowsError(try RouteKML.decode(Data("not xml".utf8))) { error in
            XCTAssertEqual(error as? RouteKML.ParseError, .invalidXML)
        }
        XCTAssertThrowsError(try RouteKML.decode(Data([0x50, 0x4B, 0x03, 0x04]))) { error in
            XCTAssertEqual(error as? RouteKML.ParseError, .unsupportedArchive)
        }
        XCTAssertTrue(RouteKML.looksLikeKML(Data("<kml xmlns=\"http://www.opengis.net/kml/2.2\">".utf8)))
        XCTAssertTrue(RouteKML.looksLikeKMZ(Data([0x50, 0x4B, 0x03, 0x04])))
        XCTAssertFalse(RouteKML.looksLikeKML(Data("<gpx version=\"1.1\">".utf8)))
        XCTAssertFalse(RouteKML.looksLikeKML(Data("{\"format\":\"paopao-routes\"}".utf8)))
    }
}
