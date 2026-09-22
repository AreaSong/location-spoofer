import Foundation
import UserNotifications

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
    static let resignInstructions = """
    免费 Apple ID 签名大约 7 天，到期后系统会拒绝打开 App。

    用电脑重新签名并安装（Impactor、Sideloadly、爱思助手等均可）。

    重装后第三方模式仍要打开小火箭模块，本 App 不能单独拦定位。
    """

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

enum SigningExpiryCountdown {
    /// 按真实剩余时间显示。整天时不补「0 小时」。
    static func text(until expirationDate: Date, now: Date, calendar: Calendar = .current) -> String? {
        guard now < expirationDate else { return nil }
        let parts = calendar.dateComponents([.day, .hour, .minute], from: now, to: expirationDate)
        let days = max(parts.day ?? 0, 0)
        let hours = max(parts.hour ?? 0, 0)
        let minutes = max(parts.minute ?? 0, 0)
        if days > 0 {
            return hours > 0 ? "签名还剩 \(days) 天 \(hours) 小时" : "签名还剩 \(days) 天"
        }
        if hours > 0 {
            return minutes > 0 ? "签名还剩 \(hours) 小时 \(minutes) 分" : "签名还剩 \(hours) 小时"
        }
        if minutes > 0 {
            return "签名还剩 \(minutes) 分钟"
        }
        return "签名即将到期"
    }
}

struct SigningExpiryReminder: Equatable {
    static let identifiers = ["signing-expiry.2d", "signing-expiry.1d", "signing-expiry.2h"]
    static let body = "到期后 App 将无法打开。请用电脑重新签名并安装。"

    let identifier: String
    let fireDate: Date
    let title: String

    /// 只保留仍在未来的提醒：提前 2 天、1 天、2 小时。
    static func upcoming(expirationDate: Date, now: Date) -> [SigningExpiryReminder] {
        let leads: [(String, TimeInterval, String)] = [
            ("signing-expiry.2d", 2 * 24 * 60 * 60, "免费签名还剩 2 天"),
            ("signing-expiry.1d", 24 * 60 * 60, "免费签名还剩 1 天"),
            ("signing-expiry.2h", 2 * 60 * 60, "免费签名即将到期")
        ]
        return leads.compactMap { identifier, lead, title in
            let fireDate = expirationDate.addingTimeInterval(-lead)
            guard fireDate > now else { return nil }
            return SigningExpiryReminder(identifier: identifier, fireDate: fireDate, title: title)
        }
    }
}

@MainActor
enum SigningExpiryReminderScheduler {
    static func sync(
        status: SigningExpiryStatus = SigningExpiry.current(),
        now: Date = Date(),
        center: UNUserNotificationCenter = .current()
    ) async {
        guard case .remaining = status.kind, let expiration = status.expirationDate else {
            center.removePendingNotificationRequests(withIdentifiers: SigningExpiryReminder.identifiers)
            return
        }
        let reminders = SigningExpiryReminder.upcoming(expirationDate: expiration, now: now)
        guard !reminders.isEmpty else {
            center.removePendingNotificationRequests(withIdentifiers: SigningExpiryReminder.identifiers)
            return
        }
        guard await authorizationGranted(center) else { return }
        await replace(reminders, on: center)
    }

    private static func authorizationGranted(_ center: UNUserNotificationCenter) async -> Bool {
        let settings = await notificationSettings(center)
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return await requestAuthorization(center)
        default:
            return false
        }
    }

    private static func replace(_ reminders: [SigningExpiryReminder], on center: UNUserNotificationCenter) async {
        center.removePendingNotificationRequests(withIdentifiers: SigningExpiryReminder.identifiers)
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = SigningExpiryReminder.body
            content.sound = .default
            let parts = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: reminder.fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            let request = UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger)
            await add(request, to: center)
        }
    }

    private static func notificationSettings(_ center: UNUserNotificationCenter) async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private static func requestAuthorization(_ center: UNUserNotificationCenter) async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func add(_ request: UNNotificationRequest, to center: UNUserNotificationCenter) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            center.add(request) { _ in
                continuation.resume()
            }
        }
    }
}
