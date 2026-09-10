import Foundation

enum SigningExpiryKind: Equatable {
    case unknown
    case longLived
    case remaining(days: Int)
    case expired
}

struct SigningExpiryStatus: Equatable {
    let kind: SigningExpiryKind
    let expirationDate: Date?

    var settingsMessage: String? {
        switch kind {
        case .unknown, .longLived:
            return nil
        case .expired:
            return "免费签名已过期，请用电脑重新签名并安装。"
        case .remaining(0):
            return "免费签名今天到期，请尽快重新签名安装。"
        case .remaining(let days):
            return "免费签名还剩 \(days) 天，到期后需要重新签名安装。"
        }
    }

    var showsMapBanner: Bool {
        switch kind {
        case .expired:
            return true
        case .remaining(let days):
            return days <= SigningExpiry.mapBannerDays
        case .unknown, .longLived:
            return false
        }
    }

    var mapBannerMessage: String? {
        showsMapBanner ? settingsMessage : nil
    }

    var isExpired: Bool {
        if case .expired = kind { return true }
        return false
    }
}

enum SigningExpiry {
    static let freeSigningWindowDays = 7
    static let mapBannerDays = 2

    static func provisionData(in bundle: Bundle = .main) -> Data? {
        let url = bundle.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func parseExpirationDate(from provision: Data) -> Date? {
        let text = String(data: provision, encoding: .isoLatin1)
            ?? String(data: provision, encoding: .ascii)
        guard let text,
              let xmlStart = text.range(of: "<?xml"),
              let plistEnd = text.range(of: "</plist>", range: xmlStart.lowerBound..<text.endIndex) else {
            return nil
        }
        let xml = String(text[xmlStart.lowerBound..<plistEnd.upperBound])
        guard let xmlData = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                from: xmlData,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return nil
        }
        return plist["ExpirationDate"] as? Date
    }

    static func evaluate(
        expirationDate: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> SigningExpiryStatus {
        guard let expirationDate else {
            return SigningExpiryStatus(kind: .unknown, expirationDate: nil)
        }
        if now >= expirationDate {
            return SigningExpiryStatus(kind: .expired, expirationDate: expirationDate)
        }
        let startNow = calendar.startOfDay(for: now)
        let startExpiry = calendar.startOfDay(for: expirationDate)
        let days = calendar.dateComponents([.day], from: startNow, to: startExpiry).day ?? 0
        if days > freeSigningWindowDays {
            return SigningExpiryStatus(kind: .longLived, expirationDate: expirationDate)
        }
        return SigningExpiryStatus(kind: .remaining(days: max(days, 0)), expirationDate: expirationDate)
    }

    static func current(bundle: Bundle = .main, now: Date = Date()) -> SigningExpiryStatus {
        let expiration = provisionData(in: bundle).flatMap(parseExpirationDate)
        return evaluate(expirationDate: expiration, now: now)
    }
}

@MainActor
final class SigningExpiryBannerStore: ObservableObject {
    static let shared = SigningExpiryBannerStore()

    private enum Key {
        static let day = "signingExpiry.dismissedDay"
        static let expiration = "signingExpiry.dismissedExpiration"
    }

    @Published private(set) var revision = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
    }

    func isBannerDismissed(
        expirationDate: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard defaults.string(forKey: Key.day) == Self.dayString(now, calendar: calendar) else {
            return false
        }
        return defaults.double(forKey: Key.expiration) == expirationDate.timeIntervalSince1970
    }

    func dismissBanner(
        expirationDate: Date,
        now: Date,
        calendar: Calendar = .current
    ) {
        defaults.set(Self.dayString(now, calendar: calendar), forKey: Key.day)
        defaults.set(expirationDate.timeIntervalSince1970, forKey: Key.expiration)
        revision += 1
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
