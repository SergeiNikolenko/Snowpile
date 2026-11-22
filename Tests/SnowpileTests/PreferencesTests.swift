import XCTest
@testable import Snowpile

final class PreferencesTests: XCTestCase {
    func testEverySnowPresetIsSelectableDirectlyFromWeatherMode() throws {
        let suite = "SnowpileTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        for mode in SnowMode.allCases {
            preferences.selection = "weather"
            preferences.selection = "snow:" + mode.rawValue
            XCTAssertFalse(preferences.followWeather)
            XCTAssertEqual(preferences.effect, .snow)
            XCTAssertEqual(preferences.mode, mode)
            XCTAssertEqual(Preferences(defaults: defaults).selection, "snow:" + mode.rawValue)
        }
    }

    func testManualEffectsLeaveAutomaticWeatherMode() throws {
        let suite = "SnowpileTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        for effect in Effect.allCases where effect != .snow {
            preferences.selection = "weather"
            preferences.selection = effect.rawValue
            XCTAssertFalse(preferences.followWeather)
            XCTAssertEqual(preferences.effect, effect)
            XCTAssertEqual(preferences.selection, effect.rawValue)
        }
        preferences.selection = "weather"
        XCTAssertTrue(preferences.followWeather)
        XCTAssertEqual(preferences.selection, "weather")
    }

    func testTimedPausePersistsAndAutoResumesWhenExpired() throws {
        let suite = "SnowpileTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let preferences = Preferences(defaults: defaults, now: start)
        var changes = 0
        preferences.onChange = { changes += 1 }

        preferences.pause(for: .fifteenMinutes, now: start)
        XCTAssertFalse(preferences.snowing)
        XCTAssertEqual(preferences.pausedUntil, start.addingTimeInterval(15 * 60))
        XCTAssertEqual(changes, 1)

        // Reloading before expiry keeps the scheduled pause intact.
        let reloadedEarly = Preferences(defaults: defaults, now: start.addingTimeInterval(10 * 60))
        XCTAssertFalse(reloadedEarly.snowing)
        XCTAssertEqual(reloadedEarly.pausedUntil, start.addingTimeInterval(15 * 60))
        XCTAssertFalse(reloadedEarly.resumeIfPauseExpired(now: start.addingTimeInterval(14 * 60)))
        XCTAssertFalse(reloadedEarly.snowing)

        // Reaching the deadline automatically resumes and clears the deadline.
        XCTAssertTrue(reloadedEarly.resumeIfPauseExpired(now: start.addingTimeInterval(15 * 60)))
        XCTAssertTrue(reloadedEarly.snowing)
        XCTAssertNil(reloadedEarly.pausedUntil)

        // Relaunching after an expired deadline starts active again.
        preferences.pause(for: .twoHours, now: start)
        let reloadedLate = Preferences(defaults: defaults, now: start.addingTimeInterval(3 * 60 * 60))
        XCTAssertTrue(reloadedLate.snowing)
        XCTAssertNil(reloadedLate.pausedUntil)
    }

    func testManualResumeAndIndefinitePauseClearScheduledDeadline() throws {
        let suite = "SnowpileTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let preferences = Preferences(defaults: defaults, now: start)
        preferences.pause(for: .oneHour, now: start)
        XCTAssertNotNil(preferences.pausedUntil)

        preferences.pauseIndefinitely()
        XCTAssertFalse(preferences.snowing)
        XCTAssertNil(preferences.pausedUntil)

        preferences.pause(for: .thirtyMinutes, now: start)
        preferences.snowing = true
        XCTAssertTrue(preferences.snowing)
        XCTAssertNil(preferences.pausedUntil)
    }

    func testUntilTomorrowAndPauseStatusSummary() throws {
        let suite = "SnowpileTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 20, minute: 10))!
        let nextMorning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 9, minute: 0))!
        XCTAssertEqual(PauseDuration.untilTomorrow.resumeDate(from: evening, calendar: calendar), nextMorning)

        // At 08:30, "Until Tomorrow" skips the 09:00 that is only 30 minutes away.
        let earlyMorning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 8, minute: 30))!
        XCTAssertEqual(PauseDuration.untilTomorrow.resumeDate(from: earlyMorning, calendar: calendar), nextMorning)

        let locale = Locale(identifier: "en_GB")
        let preferences = Preferences(defaults: defaults, now: evening)
        preferences.pause(for: .fifteenMinutes, now: evening, calendar: calendar)
        XCTAssertEqual(preferences.pauseStatusSummary(now: evening, calendar: calendar, locale: locale),
                       "Paused until 20:25 (15m left)")

        preferences.pause(for: .twoHours, now: evening, calendar: calendar)
        XCTAssertEqual(preferences.pauseStatusSummary(now: evening.addingTimeInterval(15 * 60), calendar: calendar, locale: locale),
                       "Paused until 22:10 (1h 45m left)")

        preferences.pause(for: .untilTomorrow, now: evening, calendar: calendar)
        XCTAssertEqual(preferences.pauseStatusSummary(now: evening, calendar: calendar, locale: locale),
                       "Paused until Tomorrow, 09:00")
    }
}
