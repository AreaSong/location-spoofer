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
}
