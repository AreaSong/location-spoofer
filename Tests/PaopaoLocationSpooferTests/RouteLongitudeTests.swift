import CoreLocation
import XCTest
@testable import PaopaoLocationSpoofer

final class RouteLongitudeTests: XCTestCase {
    func testForwardDateLineInterpolationFollowsShortPath() {
        assertSamples(from: 179.9, to: -179.9, expected: [179.9, 179.95, 180, -179.95, -179.9])
    }

    func testReverseDateLineInterpolationFollowsShortPath() {
        assertSamples(from: -179.9, to: 179.9, expected: [-179.9, -179.95, -180, 179.95, 179.9])
    }

    func testOrdinaryLongitudeAndProgressClampingStayUnchanged() {
        assertSamples(from: 10, to: 10.2, expected: [10, 10.05, 10.1, 10.15, 10.2])
        for (progress, expected) in [(-2.0, 179.9), (2.0, -179.9)] {
            XCTAssertEqual(RoutePlayback.interpolate(from: pair(179.9), to: pair(-179.9), progress: progress).wgs84.longitude,
                           expected, accuracy: 1e-9)
        }
    }

    func testEquivalentDateLineEndpointsNeverTravelAway() {
        for (start, end) in [(180.0, -180.0), (-180.0, 180.0), (180.0, 180.0), (-180.0, -180.0)] {
            for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let sample = RoutePlayback.interpolate(from: pair(start), to: pair(end), progress: progress)
                XCTAssertEqual(abs(sample.wgs84.longitude), 180, accuracy: 1e-9)
                XCTAssertLessThan(nativeDistance(pair(start), sample), 0.001)
            }
            XCTAssertEqual(RoutePlayback.interpolate(from: pair(start), to: pair(end), progress: 0).wgs84.longitude, start)
            XCTAssertEqual(RoutePlayback.interpolate(from: pair(start), to: pair(end), progress: 1).wgs84.longitude, end)
        }
    }

    func testExactlyHalfWorldKeepsOriginalSignedDirection() {
        // 恰好相差 180° 时保留原线性公式的方向，两条等长路径不强制统一为向东。
        for (start, end, midpoint) in [(0.0, 180.0, 90.0), (0, -180, -90),
                                     (90, -90, 0), (-90, 90, 0), (180, 0, 90), (-180, 0, -90)] {
            XCTAssertEqual(RoutePlayback.interpolate(from: pair(start), to: pair(end), progress: 0.5).wgs84.longitude,
                           midpoint, accuracy: 1e-9)
        }
    }

    func testDistanceSampledMultiSegmentPathIsContinuousAcrossDateLine() throws {
        let path = RoutePath.make([pair(179.8), pair(179.9), pair(-179.9), pair(-179.8)])
        XCTAssertEqual(path.totalMeters, 44_478, accuracy: 20)
        for candidate in [path, path.reversed()] {
            var last = try XCTUnwrap(candidate.points.first)
            var travelled = 0.0
            for index in 0...40 {
                let sample = RoutePlayback.interpolate(path: candidate, progress: Double(index) / 40)
                XCTAssertGreaterThan(abs(sample.wgs84.longitude), 179.7)
                XCTAssertTrue((-180...180).contains(sample.wgs84.longitude))
                let distance = nativeDistance(last, sample)
                XCTAssertLessThan(distance, 1_120)
                travelled += distance
                last = sample
            }
            XCTAssertEqual(travelled, candidate.totalMeters, accuracy: 80)
            XCTAssertEqual(RoutePlayback.interpolate(path: candidate, progress: -1), candidate.points.first)
            XCTAssertEqual(RoutePlayback.interpolate(path: candidate, progress: 2), candidate.points.last)
        }
    }

    func testEquivalentLongitudesDoNotAddPhantomDistanceOrSegment() {
        let path = RoutePath.make([pair(180), pair(-180), pair(-179.9)])
        XCTAssertEqual(path.points.count, 2)
        XCTAssertEqual(path.totalMeters, 11_119.5, accuracy: 2)
        XCTAssertEqual(RoutePlayback.interpolate(path: path, progress: 0.5).wgs84.longitude, -179.95, accuracy: 1e-9)
    }

    func testPairIsRegeneratedFromWGS84InsteadOfInterpolatingStoredGCJ02() {
        let start = CoordinatePair(wgs84: .init(latitude: 22.5, longitude: 113.9), gcj02: .init(latitude: 0, longitude: 0))
        let end = CoordinatePair(wgs84: .init(latitude: 22.7, longitude: 114.1), gcj02: .init(latitude: 1, longitude: 1))
        let midpoint = RoutePlayback.interpolate(from: start, to: end, progress: 0.5)
        let converted = CoordinateConverter.coordinatePair(lat: 22.6, lon: 114, mapCoordinateSystem: .wgs84)
        XCTAssertEqual(midpoint.wgs84.latitude, 22.6, accuracy: 1e-9)
        XCTAssertEqual(midpoint.gcj02.latitude, converted.gcj02.latitude, accuracy: 1e-9)
        XCTAssertEqual(midpoint.gcj02.longitude, converted.gcj02.longitude, accuracy: 1e-9)
    }

    func testDateLineSimplificationMatchesSameLocalCurveAwayFromSeam() throws {
        let reference = (0...500).map { index in
            CoordinateConverter.coordinatePair(lat: sin(Double(index) / 40) * 0.001,
                lon: Double(index) * 0.00008, mapCoordinateSystem: .wgs84)
        }
        let crossing = reference.map { point in
            let longitude = point.wgs84.longitude + 179.98
            return CoordinateConverter.coordinatePair(lat: point.wgs84.latitude,
                lon: longitude > 180 ? longitude - 360 : longitude, mapCoordinateSystem: .wgs84)
        }
        let referenceIndices = try RoutePathSimplifier.simplify(reference).map { try XCTUnwrap(reference.firstIndex(of: $0)) }
        let crossingIndices = try RoutePathSimplifier.simplify(crossing).map { try XCTUnwrap(crossing.firstIndex(of: $0)) }
        XCTAssertEqual(crossingIndices, referenceIndices)
        XCTAssertLessThan(crossingIndices.count, 100)
    }

    private func assertSamples(from start: Double, to end: Double, expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        for (progress, longitude) in zip([0.0, 0.25, 0.5, 0.75, 1.0], expected) {
            let sample = RoutePlayback.interpolate(from: pair(start), to: pair(end), progress: progress)
            XCTAssertEqual(sample.wgs84.longitude, longitude, accuracy: 1e-9, file: file, line: line)
            XCTAssertTrue((-180...180).contains(sample.wgs84.longitude), file: file, line: line)
            XCTAssertEqual(nativeDistance(pair(start), sample), nativeDistance(pair(start), pair(end)) * progress,
                           accuracy: 1, file: file, line: line)
            XCTAssertEqual(sample.wgs84, sample.gcj02, file: file, line: line)
        }
    }

    private func pair(_ longitude: Double) -> CoordinatePair {
        CoordinateConverter.coordinatePair(lat: 0, lon: longitude, mapCoordinateSystem: .wgs84)
    }

    private func nativeDistance(_ start: CoordinatePair, _ end: CoordinatePair) -> Double {
        CLLocation(latitude: start.wgs84.latitude, longitude: start.wgs84.longitude).distance(
            from: CLLocation(latitude: end.wgs84.latitude, longitude: end.wgs84.longitude))
    }
}
