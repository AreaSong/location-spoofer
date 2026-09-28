import XCTest
@testable import PaopaoLocationSpoofer

final class RouteGPXTests: XCTestCase {
    func testDecodesNamedTrackAsWalkRouteWithRecordedPath() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>文件名不要用</name></metadata>
          <trk>
            <name>湾区慢跑</name>
            <trkseg>
              <trkpt lat="22.494" lon="113.951"></trkpt>
              <trkpt lat="22.495" lon="113.952"></trkpt>
              <trkpt lat="22.496" lon="113.953"></trkpt>
            </trkseg>
          </trk>
        </gpx>
        """
        let routes = try RouteGPX.decode(Data(gpx.utf8), fallbackName: "导入路线")
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].name, "湾区慢跑")
        XCTAssertEqual(routes[0].travelMode, .walk)
        XCTAssertEqual(routes[0].speedKilometersPerHour, 5, accuracy: 0.01)
        XCTAssertEqual(routes[0].repeatMode, .once)
        XCTAssertEqual(routes[0].pathPoints?.count, 3)
        XCTAssertEqual(routes[0].start.wgs84.latitude, 22.494, accuracy: 0.000_000_1)
        XCTAssertEqual(routes[0].end.wgs84.longitude, 113.953, accuracy: 0.000_000_1)
    }

    func testDecodesRouteAndFallsBackToFileName() throws {
        let gpx = """
        <gpx>
          <rte>
            <rtept lat="22.494" lon="113.951"/>
            <rtept lat="22.495" lon="113.952"/>
          </rte>
        </gpx>
        """
        let routes = try RouteGPX.decode(Data(gpx.utf8), fallbackName: "海岸线")
        XCTAssertEqual(routes[0].name, "海岸线")
        XCTAssertEqual(routes[0].pathPoints?.count, 2)
    }

    func testDecodesMultipleTracksAndSkipsTooShort() throws {
        let gpx = """
        <gpx>
          <trk><name>短</name><trkseg>
            <trkpt lat="22.494" lon="113.951"/><trkpt lat="22.4940001" lon="113.951"/>
          </trkseg></trk>
          <trk><name>长</name><trkseg>
            <trkpt lat="22.494" lon="113.951"/>
            <trkpt lat="22.495" lon="113.952"/>
          </trkseg></trk>
        </gpx>
        """
        let routes = try RouteGPX.decode(Data(gpx.utf8))
        XCTAssertEqual(routes.map(\.name), ["长"])
    }

    func testRejectsEmptyAndInvalidDocuments() {
        XCTAssertThrowsError(try RouteGPX.decode(Data("<gpx></gpx>".utf8))) { error in
            XCTAssertEqual(error as? RouteGPX.ParseError, .empty)
        }
        XCTAssertThrowsError(try RouteGPX.decode(Data("not xml".utf8))) { error in
            XCTAssertEqual(error as? RouteGPX.ParseError, .invalidXML)
        }
        XCTAssertTrue(RouteGPX.looksLikeGPX(Data("<gpx version=\"1.1\">".utf8)))
        XCTAssertFalse(RouteGPX.looksLikeGPX(Data("{\"format\":\"paopao-routes\"}".utf8)))
    }
}
