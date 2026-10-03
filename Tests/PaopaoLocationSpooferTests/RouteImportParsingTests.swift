import XCTest
@testable import PaopaoLocationSpoofer

final class RouteImportParsingTests: XCTestCase {
    func testCancelledGPXDoesNotReturnRoutes() async throws {
        try await assertCancelled {
            try RouteGPX.decode(Data("<gpx><trk><trkseg><trkpt lat=\"1\" lon=\"2\"/><trkpt lat=\"1.01\" lon=\"2.01\"/></trkseg></trk></gpx>".utf8))
        }
    }

    func testCancelledKMLDoesNotReturnRoutes() async throws {
        try await assertCancelled {
            try RouteKML.decode(Data("<kml><Placemark><LineString><coordinates>2,1 2.01,1.01</coordinates></LineString></Placemark></kml>".utf8))
        }
    }

    func testCancelledJSONDoesNotReturnRoutes() async throws {
        let data = Data(#"{"format":"paopao-routes","version":1,"routes":[{"id":"7B983438-E72D-47BE-9FD1-D3142D72AD77","name":"合成","travelMode":"walk","speedKilometersPerHour":5,"offsetMeters":0,"repeatMode":"once","createdAt":"2020-01-01T00:00:00.000Z","start":{"latitude":1,"longitude":2},"end":{"latitude":1.01,"longitude":2.01},"vias":[]}] }"#.utf8)
        try await assertCancelled { try RouteTransfer.decode(data) }
    }

    private func assertCancelled(_ decode: @escaping @Sendable () throws -> [SavedRoute]) async throws {
        let gate = RouteParsingGate()
        let work = Task.detached {
            await gate.pause()
            return try decode()
        }
        await gate.waitUntilEntered()
        work.cancel()
        await gate.release()
        do {
            _ = try await work.value
            XCTFail("已取消的解析仍返回了可提交路线")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }
}

private actor RouteParsingGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { pending = $0; observer?.resume(); observer = nil }
    }
    func waitUntilEntered() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
