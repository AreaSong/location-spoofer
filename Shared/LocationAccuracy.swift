import Foundation

/// 产品范围来自定位精度设置；步长只约束滑条，范围内的每个整数都合法。
enum LocationAccuracy {
    static let minimumMeters = 5
    static let maximumMeters = 100
    static let defaultMeters = 25

    static func isValid(_ meters: Int) -> Bool {
        (minimumMeters...maximumMeters).contains(meters)
    }

    @discardableResult
    static func validatedCInt(_ meters: Int) throws -> CInt {
        // 即使产品范围以后扩大，桥接仍必须精确转换，不能截断或触发陷阱。
        guard let value = CInt(exactly: meters), isValid(meters) else {
            throw ValidationError.outOfRange(meters)
        }
        return value
    }

    enum ValidationError: LocalizedError, Equatable {
        case outOfRange(Int)

        var errorDescription: String? {
            switch self {
            case .outOfRange(let value):
                return "定位精度须为 \(minimumMeters)–\(maximumMeters) 米的整数，收到：\(value)"
            }
        }
    }
}

@MainActor
final class LocationAccuracyStore: ObservableObject {
    static let shared = LocationAccuracyStore()
    static let minimumMeters = LocationAccuracy.minimumMeters
    static let maximumMeters = LocationAccuracy.maximumMeters
    static let defaultMeters = LocationAccuracy.defaultMeters

    private enum Key {
        static let meters = "locationAccuracy.meters"
    }

    @Published private(set) var meters: Int
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        if defaults.object(forKey: Key.meters) == nil {
            meters = Self.defaultMeters
        } else {
            meters = Self.clamped(defaults.integer(forKey: Key.meters))
        }
    }

    func setMeters(_ meters: Int) {
        let value = Self.clamped(meters)
        self.meters = value
        defaults.set(value, forKey: Key.meters)
    }

    static func clamped(_ meters: Int) -> Int {
        min(maximumMeters, max(minimumMeters, meters))
    }
}
