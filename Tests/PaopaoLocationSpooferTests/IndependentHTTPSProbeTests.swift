import XCTest
import SwiftUI
@testable import PaopaoLocationSpoofer

@MainActor
final class IndependentHTTPSProbeTests: XCTestCase {
    private let body = Data(#"{"protocol":"location-spoofer-probe","version":"1","mode":"no-storage"}"#.utf8)

    func testProbeSendsOnlyFixedGETAndAcceptsExactResponse() async {
        let requester = ProbeRequester(data: body)
        let result = await IndependentHTTPSProbe.run(requester: requester)
        XCTAssertEqual(result, IndependentHTTPSProbe.successMessage)
        XCTAssertEqual(requester.request?.url, IndependentHTTPSProbe.endpoint)
        XCTAssertEqual(requester.request?.httpMethod, "GET")
        XCTAssertNil(requester.request?.httpBody)
        XCTAssertNil(requester.request?.url?.query)
        XCTAssertNil(requester.request?.value(forHTTPHeaderField: "Authorization"))
    }

    func testInvalidResponsesNeverReportPassed() async {
        for data in [Data("{}".utf8), Data(#"{"success":true}"#.utf8),
                     Data(#"{"protocol":"location-spoofer-probe","version":"2","mode":"no-storage"}"#.utf8),
                     Data(repeating: 32, count: 4097)] {
            let result = await IndependentHTTPSProbe.run(requester: ProbeRequester(data: data))
            XCTAssertTrue(result.contains("失败"))
        }
        for status in [302, 404, 500] {
            let result = await IndependentHTTPSProbe.run(requester: ProbeRequester(data: body, status: status))
            XCTAssertTrue(result.contains("失败"))
        }
    }

    func testOtherURLResponseIsRejected() {
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        XCTAssertFalse(IndependentHTTPSProbe.accepts(data: body, response: response))
    }

    func testCertificateFailureDoesNotChangeLocationState() async {
        let previous = ThirdPartyProxyManager.shared.connectionState
        let result = await IndependentHTTPSProbe.run(requester: ProbeRequester(error: URLError(.serverCertificateUntrusted)))
        XCTAssertTrue(result.contains("失败"))
        XCTAssertEqual(ThirdPartyProxyManager.shared.connectionState, previous)
    }

    func testCancellationHasSeparateResult() async {
        let result = await IndependentHTTPSProbe.run(requester: ProbeRequester(error: URLError(.cancelled)))
        XCTAssertEqual(result, "独立 HTTPS 探测已取消")
    }

    func testProbePageRendersAtSmallAndLargeTextSizes() {
        for (name, width, style, textSize) in [
            ("small-light", 320.0, UIUserInterfaceStyle.light, DynamicTypeSize.large),
            ("large-dark", 390.0, UIUserInterfaceStyle.dark, DynamicTypeSize.accessibility1)
        ] {
            let host = UIHostingController(rootView: IndependentHTTPSProbeView().environment(\.dynamicTypeSize, textSize)
                .environment(\.colorScheme, style == .dark ? .dark : .light)
                .preferredColorScheme(style == .dark ? .dark : .light))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
            window.overrideUserInterfaceStyle = style
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertEqual(image.size.width, width)
            let attachment = XCTAttachment(image: image)
            attachment.name = "https-probe-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("https-probe-\(name).png")
            try? image.pngData()?.write(to: url)
            print("PROBE_SCREENSHOT=\(url.path)")
            window.isHidden = true
        }
    }

    func testRedirectDelegateDoesNotFollowRedirect() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: IndependentHTTPSProbe.endpoint)
        let response = HTTPURLResponse(url: IndependentHTTPSProbe.endpoint, statusCode: 302,
                                       httpVersion: nil, headerFields: nil)!
        var called = false
        ThirdPartyRedirectBlocker().urlSession(session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "http://example.com")!)) { request in
                called = true
                XCTAssertNil(request)
            }
        XCTAssertTrue(called)
    }
}

private final class ProbeRequester: ThirdPartyProxyRequesting {
    var request: URLRequest?
    let data: Data
    let status: Int
    let error: Error?
    init(data: Data = Data(), status: Int = 200, error: Error? = nil) {
        self.data = data; self.status = status; self.error = error
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        if let error { throw error }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
