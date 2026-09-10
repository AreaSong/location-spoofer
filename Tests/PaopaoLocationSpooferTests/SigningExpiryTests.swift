import XCTest
@testable import PaopaoLocationSpoofer

final class SigningExpiryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testMissingExpirationIsUnknown() {
        let status = SigningExpiry.evaluate(expirationDate: nil, now: Date(), calendar: calendar)
        XCTAssertEqual(status.kind, .unknown)
        XCTAssertNil(status.settingsMessage)
        XCTAssertNil(status.mapBannerMessage)
    }

    func testPaidProfileBeyondOneWeekIsLongLived() {
        let now = date(2026, 9, 10, 12)
        let expiration = date(2026, 9, 18, 12)
        let status = SigningExpiry.evaluate(expirationDate: expiration, now: now, calendar: calendar)
        XCTAssertEqual(status.kind, .longLived)
        XCTAssertNil(status.settingsMessage)
        XCTAssertNil(status.mapBannerMessage)
    }

    func testSevenDaysLeftShowsSettingsOnly() {
        let now = date(2026, 9, 10, 12)
        let expiration = date(2026, 9, 17, 12)
        let status = SigningExpiry.evaluate(expirationDate: expiration, now: now, calendar: calendar)
        XCTAssertEqual(status.kind, .remaining(days: 7))
        XCTAssertEqual(status.settingsMessage, "免费签名还剩 7 天，到期后需要重新签名安装。")
        XCTAssertNil(status.mapBannerMessage)
    }

    func testTwoDaysLeftShowsMapBanner() {
        let now = date(2026, 9, 15, 9)
        let expiration = date(2026, 9, 17, 18)
        let status = SigningExpiry.evaluate(expirationDate: expiration, now: now, calendar: calendar)
        XCTAssertEqual(status.kind, .remaining(days: 2))
        XCTAssertEqual(status.mapBannerMessage, status.settingsMessage)
        XCTAssertTrue(status.showsMapBanner)
    }

    func testExpiresLaterToday() {
        let now = date(2026, 9, 17, 10)
        let expiration = date(2026, 9, 17, 20)
        let status = SigningExpiry.evaluate(expirationDate: expiration, now: now, calendar: calendar)
        XCTAssertEqual(status.kind, .remaining(days: 0))
        XCTAssertEqual(status.settingsMessage, "免费签名今天到期，请尽快重新签名安装。")
        XCTAssertTrue(status.showsMapBanner)
    }

    func testExpiredUsesExactTime() {
        let now = date(2026, 9, 17, 21)
        let expiration = date(2026, 9, 17, 20)
        let status = SigningExpiry.evaluate(expirationDate: expiration, now: now, calendar: calendar)
        XCTAssertEqual(status.kind, .expired)
        XCTAssertEqual(status.settingsMessage, "免费签名已过期，请用电脑重新签名并安装。")
        XCTAssertTrue(status.isExpired)
        XCTAssertFalse(status.settingsMessage?.contains("错误代码") == true)
    }

    func testParseExpirationDateFromWrappedPlist() throws {
        let xml = """
        junk<?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ExpirationDate</key>
            <date>2026-09-17T04:00:00Z</date>
        </dict>
        </plist>junk
        """
        let parsed = try XCTUnwrap(SigningExpiry.parseExpirationDate(from: Data(xml.utf8)))
        XCTAssertEqual(parsed, date(2026, 9, 17, 4))
    }

    func testParseIgnoresProvisionWithoutPlist() {
        XCTAssertNil(SigningExpiry.parseExpirationDate(from: Data("not a profile".utf8)))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}

@MainActor
final class SigningExpiryBannerStoreTests: XCTestCase {
    func testDismissOnlyHidesBannerForTheSameDayAndExpiration() {
        let suite = "SigningExpiryBannerStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SigningExpiryBannerStore(defaults: defaults)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expiration = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 20))!
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 9))!
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 9))!
        let otherExpiration = expiration.addingTimeInterval(60)

        XCTAssertFalse(store.isBannerDismissed(expirationDate: expiration, now: today, calendar: calendar))
        store.dismissBanner(expirationDate: expiration, now: today, calendar: calendar)
        XCTAssertTrue(store.isBannerDismissed(expirationDate: expiration, now: today, calendar: calendar))
        XCTAssertFalse(store.isBannerDismissed(expirationDate: otherExpiration, now: today, calendar: calendar))
        XCTAssertFalse(store.isBannerDismissed(expirationDate: expiration, now: tomorrow, calendar: calendar))
    }
}
