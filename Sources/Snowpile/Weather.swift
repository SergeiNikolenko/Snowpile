import Foundation

/// Current conditions in the chosen place.
struct Conditions: Equatable {
    /// 0 when it is not snowing, up to 1 for heavy snow.
    var snow: Double
    var temperature: Double
    /// Wind blowing towards the east in m/s; negative blows west.
    var eastWind: Double
    var windSpeed: Double
    var gusts: Double
    /// Snow lying on the ground in metres, when the source reports it.
    var snowDepth: Double?
    /// 0 when dry, up to 1 for heavy rain.
    var rain: Double = 0
    var thunderstorm = false

    var recommendedEffect: Effect? {
        if snow > 0 { return .snow }
        if rain > 0 || thunderstorm { return .rain }
        return SnowMode.outside(self) == nil ? nil : .snow
    }

    var rainIntensity: Float { rain > 0 ? 0.3 + Float(rain) * 2.7 : 0 }

    var summary: String {
        let degrees = temperature.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)))
        let sky: String
        if thunderstorm {
            sky = "thunderstorm"
        } else if recommendedEffect == .snow, let mode = SnowMode.outside(self) {
            sky = mode.title.lowercased()
        } else if rain > 0 {
            sky = rain >= 0.7 ? "heavy rain" : "rain"
        } else {
            sky = "no precipitation"
        }
        return "\(degrees)°, \(sky)"
    }
}

struct Place: Codable, Equatable, Identifiable {
    var name: String
    var detail: String
    var latitude: Double
    var longitude: Double
    var id: String { "\(latitude),\(longitude)" }

    static let moscow = Place(name: "Москва", detail: "Россия", latitude: 55.7558, longitude: 37.6173)
}

enum Weather {
    /// Yandex Weather when a key is given, Open-Meteo otherwise.
    static func conditions(at place: Place, yandexKey: String) async throws -> Conditions {
        let key = yandexKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? try await openMeteo(place) : try await yandex(place, key: key)
    }

    private static func yandex(_ place: Place, key: String) async throws -> Conditions {
        var request = URLRequest(url: URL(string: "https://api.weather.yandex.ru/graphql/query")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "X-Yandex-Weather-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let query = "{ weatherByPoint(request: {lat: \(place.latitude), lon: \(place.longitude)}) "
            + "{ now { temperature condition precType precStrength windSpeed windDirection windGust } } }"
        request.httpBody = try JSONEncoder().encode(["query": query])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        return try decodeYandex(data)
    }

    static func decodeYandex(_ data: Data) throws -> Conditions {
        struct Reply: Decodable {
            struct Data: Decodable {
                struct Point: Decodable {
                    struct Now: Decodable {
                        let temperature: Double
                        let condition: String?
                        let precType: String
                        let precStrength: String
                        let windSpeed: Double
                        let windDirection: String
                        let windGust: Double?
                    }
                    let now: Now
                }
                let weatherByPoint: Point
            }
            let data: Data
        }
        let now = try JSONDecoder().decode(Reply.self, from: data).data.weatherByPoint.now
        let strengths: [String: Double] = ["ZERO": 0, "WEAK": 0.25, "AVERAGE": 0.5, "STRONG": 0.75, "VERY_STRONG": 1]
        let strength = strengths[now.precStrength] ?? 0.15
        let snow = ["SNOW", "SLEET"].contains(now.precType) ? strength : 0
        let rain = ["RAIN", "SLEET", "HAIL"].contains(now.precType) ? strength : 0
        let thunderstorms = ["THUNDERSTORM", "THUNDERSTORM_WITH_RAIN", "THUNDERSTORM_WITH_HAIL"]
        let from: [String: Double] = ["NORTH": 0, "NORTH_EAST": 45, "EAST": 90, "SOUTH_EAST": 135,
                                      "SOUTH": 180, "SOUTH_WEST": 225, "WEST": 270, "NORTH_WEST": 315]
        return Conditions(snow: snow, temperature: now.temperature, eastWind: eastward(now.windSpeed, from: from[now.windDirection]),
                          windSpeed: now.windSpeed, gusts: now.windGust ?? now.windSpeed * 1.3,
                          snowDepth: nil, rain: rain,
                          thunderstorm: now.condition.map(thunderstorms.contains) ?? false)
    }

    private static func openMeteo(_ place: Place) async throws -> Conditions {
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(place.latitude)&longitude=\(place.longitude)"
            + "&current=temperature_2m,snowfall,rain,showers,weather_code,wind_speed_10m,wind_gusts_10m,wind_direction_10m,snow_depth&wind_speed_unit=ms")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try decodeOpenMeteo(data)
    }

    static func decodeOpenMeteo(_ data: Data) throws -> Conditions {
        struct Reply: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let snowfall: Double
                let rain: Double?
                let showers: Double?
                let interval: Double?
                let weather_code: Int
                let wind_speed_10m: Double
                let wind_gusts_10m: Double
                let wind_direction_10m: Double
                let snow_depth: Double?
            }
            let current: Current
        }
        let now = try JSONDecoder().decode(Reply.self, from: data).current
        // Current precipitation is accumulated over the reported interval.
        let hourlyFactor = 3_600 / max(now.interval ?? 900, 1)
        let snowCode = (71...77).contains(now.weather_code) || (85...86).contains(now.weather_code)
        let snow = snowCode || now.snowfall > 0 ? min(max(now.snowfall * hourlyFactor / 1.5, 0.15), 1) : 0
        let thunderstorm = [95, 96, 97, 99].contains(now.weather_code)
        let rainCode = [51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 96, 99].contains(now.weather_code)
        let rainPerHour = ((now.rain ?? 0) + (now.showers ?? 0)) * hourlyFactor
        let rain = min(max(rainPerHour / 8, rainCode ? 0.15 : 0), 1)
        return Conditions(snow: snow, temperature: now.temperature_2m,
                          eastWind: eastward(now.wind_speed_10m, from: now.wind_direction_10m),
                          windSpeed: now.wind_speed_10m, gusts: now.wind_gusts_10m, snowDepth: now.snow_depth,
                          rain: rain, thunderstorm: thunderstorm)
    }

    /// Meteorological wind direction is where the wind comes from.
    private static func eastward(_ speed: Double, from degrees: Double?) -> Double {
        guard let degrees else { return 0 }
        return -speed * sin(degrees * .pi / 180)
    }

    static func search(_ text: String) async throws -> [Place] {
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        let language = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        parts.queryItems = [.init(name: "name", value: text), .init(name: "count", value: "8"), .init(name: "language", value: language)]
        let (data, _) = try await URLSession.shared.data(from: parts.url!)
        struct Reply: Decodable {
            struct Result: Decodable {
                let name: String
                let latitude: Double
                let longitude: Double
                let country: String?
                let admin1: String?
            }
            let results: [Result]?
        }
        return (try JSONDecoder().decode(Reply.self, from: data).results ?? []).map {
            Place(name: $0.name, detail: [$0.admin1, $0.country].compactMap { $0 }.joined(separator: ", "),
                  latitude: $0.latitude, longitude: $0.longitude)
        }
    }
}
