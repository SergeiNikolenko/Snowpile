import AppKit
import ServiceManagement

enum PauseDuration: String, CaseIterable, Equatable {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case eightHours
    case untilTomorrow

    var title: String {
        switch self {
        case .fifteenMinutes: return "15 Minutes"
        case .thirtyMinutes: return "30 Minutes"
        case .oneHour: return "1 Hour"
        case .twoHours: return "2 Hours"
        case .fourHours: return "4 Hours"
        case .eightHours: return "8 Hours"
        case .untilTomorrow: return "Until Tomorrow"
        }
    }

    func resumeDate(from now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .fifteenMinutes: return now.addingTimeInterval(15 * 60)
        case .thirtyMinutes: return now.addingTimeInterval(30 * 60)
        case .oneHour: return now.addingTimeInterval(60 * 60)
        case .twoHours: return now.addingTimeInterval(2 * 60 * 60)
        case .fourHours: return now.addingTimeInterval(4 * 60 * 60)
        case .eightHours: return now.addingTimeInterval(8 * 60 * 60)
        case .untilTomorrow:
            let floor = now.addingTimeInterval(60 * 60)
            return calendar.nextDate(after: floor, matching: DateComponents(hour: 9, minute: 0), matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(12 * 60 * 60)
        }
    }
}

/// User settings, saved in UserDefaults. `onChange` lets the app apply them as they change.
final class Preferences: ObservableObject {
    static let allDisplays = "all"
    static let mainDisplay = "main"

    private let defaults: UserDefaults
    private var applyingPause = false
    var onChange: () -> Void = {}

    @Published var effect: Effect { didSet { save(effect.rawValue, "effect") } }
    @Published var snowing: Bool {
        didSet {
            if !applyingPause { clearPauseDeadline() }
            save(snowing, "snowing")
        }
    }
    @Published private(set) var pausedUntil: Date?
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

    /// One selection keeps weather and manual presets mutually exclusive in both menus.
    var selection: String {
        get { followWeather ? "weather" : effect == .snow ? "snow:" + mode.rawValue : effect.rawValue }
        set {
            if newValue == "weather" {
                followWeather = true
            } else if newValue.hasPrefix("snow:"), let selected = SnowMode(rawValue: String(newValue.dropFirst(5))) {
                followWeather = false
                effect = .snow
                mode = selected
            } else if let selected = Effect(rawValue: newValue) {
                followWeather = false
                effect = selected
            }
        }
    }

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        defaults.register(defaults: [
            "snowing": true, "intensity": 1.0, "wind": 1.0, "display": Self.allDisplays,
            "onWindows": true, "onDock": true, "onFloor": true, "pointer": true,
            "followWeather": false, "yandexKey": "", "mode": SnowMode.snow.rawValue,
        ])
        effect = Effect(rawValue: defaults.string(forKey: "effect") ?? "") ?? .snow
        var initialSnowing = defaults.bool(forKey: "snowing")
        var initialDeadline: Date?
        let storedDeadline = defaults.double(forKey: "pausedUntil")
        if !initialSnowing, storedDeadline > 0 {
            let deadline = Date(timeIntervalSince1970: storedDeadline)
            if deadline <= now {
                defaults.removeObject(forKey: "pausedUntil")
                initialSnowing = true
                defaults.set(true, forKey: "snowing")
            } else {
                initialDeadline = deadline
            }
        } else if storedDeadline > 0 {
            defaults.removeObject(forKey: "pausedUntil")
        }
        snowing = initialSnowing
        pausedUntil = initialDeadline
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

    func pause(for duration: PauseDuration, now: Date = Date(), calendar: Calendar = .current) {
        pause(until: duration.resumeDate(from: now, calendar: calendar), now: now)
    }

    func pause(until date: Date, now: Date = Date()) {
        guard date > now else { resume(); return }
        applyingPause = true
        pausedUntil = date
        defaults.set(date.timeIntervalSince1970, forKey: "pausedUntil")
        snowing = false
        applyingPause = false
    }

    func pauseIndefinitely() {
        applyingPause = true
        clearPauseDeadline()
        snowing = false
        applyingPause = false
    }

    func resume() {
        applyingPause = true
        clearPauseDeadline()
        snowing = true
        applyingPause = false
    }

    @discardableResult
    func resumeIfPauseExpired(now: Date = Date()) -> Bool {
        guard let deadline = pausedUntil else { return false }
        if snowing {
            clearPauseDeadline()
            return false
        }
        guard deadline <= now else { return false }
        resume()
        return true
    }

    func pauseStatusSummary(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard !snowing, let deadline = pausedUntil, deadline > now else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let clock = formatter.string(from: deadline)
        if !calendar.isDate(deadline, inSameDayAs: now) {
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
               calendar.isDate(deadline, inSameDayAs: tomorrow) {
                return "Paused until Tomorrow, \(clock)"
            }
            return "Paused until \(clock)"
        }
        let seconds = deadline.timeIntervalSince(now)
        let remaining: String
        if seconds < 60 {
            remaining = "< 1m left"
        } else {
            let totalMinutes = Int(ceil(seconds / 60))
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if hours == 0 { remaining = "\(minutes)m left" }
            else if minutes == 0 { remaining = "\(hours)h left" }
            else { remaining = "\(hours)h \(minutes)m left" }
        }
        return "Paused until \(clock) (\(remaining))"
    }

    private func clearPauseDeadline() {
        if pausedUntil != nil { pausedUntil = nil }
        defaults.removeObject(forKey: "pausedUntil")
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
