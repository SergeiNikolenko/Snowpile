import Foundation

/// What the sky is doing in the chosen place, reduced to what the snowfall needs.
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
            + "{ now { temperature precType precStrength windSpeed windDirection } } }"
        request.httpBody = try JSONEncoder().encode(["query": query])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        struct Reply: Decodable {
            struct Data: Decodable {
                struct Point: Decodable {
                    struct Now: Decodable {
                        let temperature: Double
                        let precType: String
                        let precStrength: String
                        let windSpeed: Double
                        let windDirection: String
                    }
                    let now: Now
                }
                let weatherByPoint: Point
            }
            let data: Data
        }
        let now = try JSONDecoder().decode(Reply.self, from: data).data.weatherByPoint.now
        let strength: [String: Double] = ["WEAK": 0.25, "AVERAGE": 0.5, "STRONG": 0.75, "VERY_STRONG": 1]
        let snow = ["SNOW", "SLEET"].contains(now.precType) ? strength[now.precStrength] ?? 0.15 : 0
        let from: [String: Double] = ["NORTH": 0, "NORTH_EAST": 45, "EAST": 90, "SOUTH_EAST": 135,
                                      "SOUTH": 180, "SOUTH_WEST": 225, "WEST": 270, "NORTH_WEST": 315]
        return Conditions(snow: snow, temperature: now.temperature, eastWind: eastward(now.windSpeed, from: from[now.windDirection]),
                          windSpeed: now.windSpeed, gusts: now.windSpeed * 1.3, snowDepth: nil)
    }

    private static func openMeteo(_ place: Place) async throws -> Conditions {
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(place.latitude)&longitude=\(place.longitude)"
            + "&current=temperature_2m,snowfall,weather_code,wind_speed_10m,wind_gusts_10m,wind_direction_10m,snow_depth&wind_speed_unit=ms")!
        let (data, _) = try await URLSession.shared.data(from: url)
        struct Reply: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let snowfall: Double
                let weather_code: Int
                let wind_speed_10m: Double
                let wind_gusts_10m: Double
                let wind_direction_10m: Double
                let snow_depth: Double?
            }
            let current: Current
        }
        let now = try JSONDecoder().decode(Reply.self, from: data).current
        let snowCode = (71...77).contains(now.weather_code) || (85...86).contains(now.weather_code)
        let snow = snowCode || now.snowfall > 0 ? min(max(now.snowfall / 1.5, 0.15), 1) : 0
        return Conditions(snow: snow, temperature: now.temperature_2m,
                          eastWind: eastward(now.wind_speed_10m, from: now.wind_direction_10m),
                          windSpeed: now.wind_speed_10m, gusts: now.wind_gusts_10m, snowDepth: now.snow_depth)
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
