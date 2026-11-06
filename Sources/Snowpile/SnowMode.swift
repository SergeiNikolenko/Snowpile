/// Kinds of snowy weather, from a few flakes to a blizzard, and how each one drives the snowfall.
enum SnowMode: String, CaseIterable, Identifiable {
    case flurries, snow, heavySnow, driftingSnow, blowingSnow, blizzard, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flurries: "Flurries"
        case .snow: "Snow"
        case .heavySnow: "Heavy Snow"
        case .driftingSnow: "Drifting Snow"
        case .blowingSnow: "Blowing Snow"
        case .blizzard: "Blizzard"
        case .custom: "Custom"
        }
    }

    /// How hard it snows (0 for drifting snow, which only lifts what already lies), steady wind in points
    /// per second, gustiness, how much settled snow the wind picks up, and flake size.
    struct Storm {
        var intensity: Float
        var wind: Float
        var gusts: Float
        var lift: Float
        var flakeScale: Float
    }

    var storm: Storm {
        switch self {
        case .flurries: Storm(intensity: 0.35, wind: 8, gusts: 0.5, lift: 0, flakeScale: 0.85)
        case .snow, .custom: Storm(intensity: 1, wind: 12, gusts: 0.8, lift: 0, flakeScale: 1)
        case .heavySnow: Storm(intensity: 2.8, wind: 14, gusts: 0.7, lift: 0, flakeScale: 1.15)
        case .driftingSnow: Storm(intensity: 0, wind: 90, gusts: 0.6, lift: 0.6, flakeScale: 0.8)
        case .blowingSnow: Storm(intensity: 2.6, wind: 85, gusts: 1.2, lift: 0.5, flakeScale: 0.9)
        case .blizzard: Storm(intensity: 6.5, wind: 140, gusts: 1.8, lift: 1, flakeScale: 0.9)
        }
    }

    /// The mode the weather calls for, or nil when nothing snowy is going on.
    /// Thresholds follow common meteorological usage: blowing snow from about 10 m/s, a blizzard from about 15 m/s with heavy snow.
    static func outside(_ now: Conditions) -> SnowMode? {
        let wind = max(now.windSpeed, now.gusts * 0.7)
        if now.snow == 0 {
            return wind >= 10 && (now.snowDepth ?? 0) > 0 ? .driftingSnow : nil
        }
        if wind >= 15 && now.snow >= 0.5 { return .blizzard }
        if wind >= 10 { return .blowingSnow }
        if now.snow >= 0.7 { return .heavySnow }
        return now.snow >= 0.3 ? .snow : .flurries
    }
}
