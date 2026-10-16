import SwiftUI
import XCTest
@testable import PaopaoLocationSpoofer

/// 隔离渲染证据，不代表键盘、输入法或 VoiceOver 操作验收。
@available(iOS 16.0, *)
@MainActor
final class MapSearchRenderingTests: XCTestCase {
    func testCoordinateChoicesRenderAtSmallSizeInBothThemes() throws {
        let search = MapSearchModel()
        search.text = "22.5, 113.9"
        search.submit(system: .wgs84, preferred: .wgs84)
        for dark in [false, true] {
            for large in [false, true] {
                let content = MapSearchResults(search: search, onSelect: { _ in }, onCopy: { _ in }, onSave: { _ in })
                    .frame(width: 343, height: 440)
                    .padding(16)
                    .background(dark ? Color.black : Color.white)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.dynamicTypeSize, large ? .accessibility5 : .large)
                let host = UIHostingController(rootView: content)
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 472))
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.frame = window.bounds
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                let image = renderer.image { _ in
                    host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "search-coordinate-\(dark ? "dark" : "light")-\(large ? "AX5" : "normal")"
                attachment.lifetime = .keepAlways
                add(attachment)
                window.isHidden = true
            }
        }
    }

    func testFocusingSearchFieldKeepsTheSameInputAndDoesNotHang() {
        let search = MapSearchModel()
        let counter = SearchLayoutRenderCounter()
        let focus = SearchFocusProbe()
        let content = SearchSessionLayoutFixture(search: search, counter: counter, focus: focus)
        let host = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        let fieldBefore = firstTextField(in: host.view)
        XCTAssertNotNil(fieldBefore, "search field must render before focus")
        XCTAssertNil(viewWithIdentifier("mapSearch.results", in: host.view), "empty results must not appear on idle home chrome")
        let rendersBeforeFocus = counter.count

        focus.wanted = true
        let started = Date()
        while Date().timeIntervalSince(started) < 1.0 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.view.layoutIfNeeded()
        }

        let fieldAfter = firstTextField(in: host.view)
        XCTAssertTrue(fieldBefore === fieldAfter, "focus must not rebuild the search field")
        XCTAssertNil(viewWithIdentifier("mapSearch.results", in: host.view), "focus alone must not insert an empty results scroll view")
        XCTAssertLessThan(
            counter.count - rendersBeforeFocus, 24,
            "focus must not spin the home overlay layout, got \(counter.count - rendersBeforeFocus) extra renders"
        )
        window.isHidden = true
    }

    private func firstTextField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        for child in view.subviews {
            if let field = firstTextField(in: child) { return field }
        }
        return nil
    }

    private func viewWithIdentifier(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for child in view.subviews {
            if let match = viewWithIdentifier(identifier, in: child) { return match }
        }
        return nil
    }
}

@MainActor
private final class SearchLayoutRenderCounter {
    var count = 0
}

@MainActor
private final class SearchFocusProbe: ObservableObject {
    @Published var wanted = false
}

@available(iOS 16.0, *)
private struct SearchSessionLayoutFixture: View {
    @ObservedObject var search: MapSearchModel
    let counter: SearchLayoutRenderCounter
    @ObservedObject var focus: SearchFocusProbe
    @FocusState private var focused: Bool

    var body: some View {
        let _ = { counter.count += 1 }()
        MapHomeOverlayLayout(
            top: { height in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        MapSearchField(search: search, focus: $focused, onSubmit: {})
                        if focused {
                            Button("完成") { focused = false }
                        }
                    }
                    if search.hasVisibleResults {
                        MapSearchResults(search: search, onSelect: { _ in }, onCopy: { _ in }, onSave: { _ in })
                    } else if !focused {
                        Text("坐标").frame(minHeight: 44)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: height, alignment: .top)
            },
            bottom: { _ in
                if !focused {
                    Text("底部").frame(minHeight: 44)
                }
            }
        )
        .ignoresSafeArea(.keyboard)
        .onChange(of: focus.wanted) { focused = $0 }
    }
}
