import AppKit
import ServiceManagement

/// User settings, saved in UserDefaults. `onChange` lets the app apply them as they change.
final class Preferences: ObservableObject {
    static let allDisplays = "all"
    static let mainDisplay = "main"

    private let defaults = UserDefaults.standard
    var onChange: () -> Void = {}

    @Published var effect: Effect { didSet { save(effect.rawValue, "effect") } }
    @Published var snowing: Bool { didSet { save(snowing, "snowing") } }
    @Published var intensity: Double { didSet { save(intensity, "intensity") } }
    @Published var wind: Double { didSet { save(wind, "wind") } }
    @Published var display: String { didSet { save(display, "display") } }
    @Published var onWindows: Bool { didSet { save(onWindows, "onWindows") } }
    @Published var onDock: Bool { didSet { save(onDock, "onDock") } }
    @Published var onFloor: Bool { didSet { save(onFloor, "onFloor") } }
    @Published var pointer: Bool { didSet { save(pointer, "pointer") } }
    @Published var followWeather: Bool { didSet { save(followWeather, "followWeather") } }
    @Published var mode: SnowMode { didSet { save(mode.rawValue, "mode") } }
    @Published var yandexKey: String { didSet { save(yandexKey, "yandexKey") } }
    @Published var place: Place { didSet { save((try? JSONEncoder().encode(place)) ?? Data(), "place") } }
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled

    init() {
        defaults.register(defaults: [
            "snowing": true, "intensity": 1.0, "wind": 1.0, "display": Self.allDisplays,
            "onWindows": true, "onDock": true, "onFloor": true, "pointer": true,
            "followWeather": false, "yandexKey": "", "mode": SnowMode.snow.rawValue,
        ])
        effect = Effect(rawValue: defaults.string(forKey: "effect") ?? "") ?? .snow
        snowing = defaults.bool(forKey: "snowing")
        intensity = defaults.double(forKey: "intensity")
        wind = defaults.double(forKey: "wind")
        display = defaults.string(forKey: "display") ?? Self.allDisplays
        onWindows = defaults.bool(forKey: "onWindows")
        onDock = defaults.bool(forKey: "onDock")
        onFloor = defaults.bool(forKey: "onFloor")
        pointer = defaults.bool(forKey: "pointer")
        followWeather = defaults.bool(forKey: "followWeather")
        mode = SnowMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .snow
        yandexKey = defaults.string(forKey: "yandexKey") ?? ""
        place = defaults.data(forKey: "place").flatMap { try? JSONDecoder().decode(Place.self, from: $0) } ?? .moscow
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange()
    }

    func setOpensAtLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func screens() -> [NSScreen] {
        switch display {
        case Self.allDisplays: return NSScreen.screens
        case Self.mainDisplay: return Array(NSScreen.screens.prefix(1))
        default:
            let chosen = NSScreen.screens.filter { Self.id(of: $0) == display }
            return chosen.isEmpty ? NSScreen.screens : chosen
        }
    }

    static func id(of screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? screen.localizedName
    }
}
