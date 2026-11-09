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
}
