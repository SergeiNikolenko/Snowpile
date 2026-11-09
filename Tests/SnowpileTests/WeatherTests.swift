import XCTest
@testable import Snowpile

final class WeatherTests: XCTestCase {
    func testOpenMeteoUsesRainAndShowersAtTheirReportedInterval() throws {
        let now = try openMeteo(code: 81, rain: 0.25, showers: 0.75)

        XCTAssertEqual(now.recommendedEffect, .rain)
        XCTAssertEqual(now.rain, 0.5, accuracy: 0.001)
        XCTAssertEqual(now.rainIntensity, 1.65, accuracy: 0.001)
        XCTAssertEqual(now.eastWind, -5, accuracy: 0.001)
        XCTAssertFalse(now.thunderstorm)
    }

    func testOpenMeteoDistinguishesDryWeatherSnowAndThunderstorms() throws {
        let dry = try openMeteo(code: 3)
        XCTAssertNil(dry.recommendedEffect)
        XCTAssertEqual(dry.rainIntensity, 0)

        let snow = try openMeteo(code: 85)
        XCTAssertEqual(snow.recommendedEffect, .snow)
        XCTAssertEqual(SnowMode.outside(snow), .flurries)

        for code in [95, 96, 97, 99] {
            let storm = try openMeteo(code: code)
            XCTAssertTrue(storm.thunderstorm)
            XCTAssertEqual(storm.recommendedEffect, .rain)
        }
    }

    func testOpenMeteoSnowIntensityUsesTheReportedInterval() throws {
        let quarterHour = try openMeteo(code: 73, snowfall: 0.225)
        let hour = try openMeteo(code: 73, snowfall: 0.9, interval: 3_600)
        XCTAssertEqual(quarterHour.snow, 0.6, accuracy: 0.001)
        XCTAssertEqual(quarterHour.snow, hour.snow, accuracy: 0.001)
        XCTAssertEqual(SnowMode.outside(quarterHour), .snow)
    }

    func testOpenMeteoDoesNotMistakeRainOverExistingSnowForDriftingSnow() throws {
        let drifting = try openMeteo(code: 3, wind: 12, snowDepth: 0.12)
        XCTAssertEqual(drifting.recommendedEffect, .snow)
        XCTAssertEqual(SnowMode.outside(drifting), .driftingSnow)

        let rain = try openMeteo(code: 63, rain: 0.5, wind: 12, snowDepth: 0.12)
        XCTAssertEqual(rain.recommendedEffect, .rain)
    }

    func testYandexThunderstormUsesDocumentedConditionAndWindFields() throws {
        let now = try yandex(condition: "THUNDERSTORM_WITH_RAIN", type: "RAIN", strength: "STRONG")

        XCTAssertEqual(now.recommendedEffect, .rain)
        XCTAssertEqual(now.rain, 0.75)
        XCTAssertTrue(now.thunderstorm)
        XCTAssertEqual(now.eastWind, 11, accuracy: 0.001)
        XCTAssertEqual(now.gusts, 16)
        XCTAssertNil(now.snowDepth)
    }

    func testYandexPreservesSnowInSleetAndDistinguishesRainFromDryWeather() throws {
        let sleet = try yandex(condition: "SLEET", type: "SLEET", strength: "AVERAGE")
        XCTAssertEqual(sleet.recommendedEffect, .snow)
        XCTAssertEqual(sleet.snow, 0.5)
        XCTAssertEqual(sleet.rain, 0.5)

        let dry = try yandex(condition: "OVERCAST", type: "NO_TYPE", strength: "ZERO")
        XCTAssertNil(dry.recommendedEffect)

        let rain = try yandex(condition: "RAIN", type: "RAIN", strength: "AVERAGE")
        XCTAssertEqual(rain.recommendedEffect, .rain)
        XCTAssertFalse(rain.thunderstorm)
    }

    private func openMeteo(code: Int, rain: Double = 0, showers: Double = 0, wind: Double = 5,
                           snowDepth: Double = 0, snowfall: Double = 0, interval: Int = 900) throws -> Conditions {
        try Weather.decodeOpenMeteo(Data("""
        {"current":{
          "temperature_2m":3,"weather_code":\(code),"interval":\(interval),
          "snowfall":\(snowfall),"rain":\(rain),"showers":\(showers),"snow_depth":\(snowDepth),
          "wind_speed_10m":\(wind),"wind_gusts_10m":8,"wind_direction_10m":90
        }}
        """.utf8))
    }

    private func yandex(condition: String, type: String, strength: String) throws -> Conditions {
        try Weather.decodeYandex(Data("""
        {"data":{"weatherByPoint":{"now":{
          "temperature":1,"condition":"\(condition)","precType":"\(type)","precStrength":"\(strength)",
          "windSpeed":11,"windDirection":"WEST","windGust":16
        }}}}
        """.utf8))
    }
}
