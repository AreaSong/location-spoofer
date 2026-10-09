import Combine
import Foundation

enum MapDisplayStyle: String, CaseIterable, Equatable {
    case standard
    case satellite
    case hybrid

    var title: String {
        switch self {
        case .standard: return "标准"
        case .satellite: return "卫星"
        case .hybrid: return "混合"
        }
    }

    var symbolName: String {
        switch self {
        case .standard: return "map"
        case .satellite: return "globe"
        case .hybrid: return "square.stack.3d.up"
        }
    }

    var next: MapDisplayStyle {
        switch self {
        case .standard: return .satellite
        case .satellite: return .hybrid
        case .hybrid: return .standard
        }
    }

    var isPhotographic: Bool {
        self == .satellite || self == .hybrid
    }
}

@MainActor
final class MapStyleStore: ObservableObject {
    static let shared = MapStyleStore()

    private enum Key {
        static let style = "mapDisplay.style"
    }

    @Published private(set) var style: MapDisplayStyle
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Key.style), let stored = MapDisplayStyle(rawValue: raw) {
            style = stored
        } else {
            style = .standard
        }
    }

    func setStyle(_ style: MapDisplayStyle) {
        self.style = style
        defaults.set(style.rawValue, forKey: Key.style)
    }

    func cycle() {
        setStyle(style.next)
    }
}
