import Foundation

/// What the sky is doing in the chosen place, reduced to what the snowfall needs.
struct Conditions: Equatable {
    /// 0 when it is not snowing, up to 1 for heavy snow.
    var snow: Double
    var temperature: Double
    /// Wind blowing towards the east in m/s; negative blows west.
    var eastWind: Double
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
        var request = URLRequest(url: URL(string: "https://api.weather.yandex.ru/v2/forecast?lat=\(place.latitude)&lon=\(place.longitude)&limit=1&hours=false")!)
        request.setValue(key, forHTTPHeaderField: "X-Yandex-Weather-Key")
        request.setValue(key, forHTTPHeaderField: "X-Yandex-API-Key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        struct Reply: Decodable {
            struct Fact: Decodable {
                let temp: Double
                let wind_speed: Double
                let wind_dir: String
                let prec_type: Int
                let prec_strength: Double
            }
            let fact: Fact
        }
        let fact = try JSONDecoder().decode(Reply.self, from: data).fact
        // prec_type: 2 is rain with snow, 3 is snow.
        let snow = [2, 3].contains(fact.prec_type) ? max(fact.prec_strength, 0.15) : 0
        let from: [String: Double] = ["n": 0, "ne": 45, "e": 90, "se": 135, "s": 180, "sw": 225, "w": 270, "nw": 315]
        return Conditions(snow: snow, temperature: fact.temp, eastWind: eastward(fact.wind_speed, from: from[fact.wind_dir]))
    }

    private static func openMeteo(_ place: Place) async throws -> Conditions {
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(place.latitude)&longitude=\(place.longitude)"
            + "&current=temperature_2m,snowfall,weather_code,wind_speed_10m,wind_direction_10m&wind_speed_unit=ms")!
        let (data, _) = try await URLSession.shared.data(from: url)
        struct Reply: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let snowfall: Double
                let weather_code: Int
                let wind_speed_10m: Double
                let wind_direction_10m: Double
            }
            let current: Current
        }
        let now = try JSONDecoder().decode(Reply.self, from: data).current
        let snowCode = (71...77).contains(now.weather_code) || (85...86).contains(now.weather_code)
        let snow = snowCode || now.snowfall > 0 ? min(max(now.snowfall / 1.5, 0.15), 1) : 0
        return Conditions(snow: snow, temperature: now.temperature_2m,
                          eastWind: eastward(now.wind_speed_10m, from: now.wind_direction_10m))
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
