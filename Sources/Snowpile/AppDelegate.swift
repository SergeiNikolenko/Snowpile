import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let world = SnowWorld()
    private let effects = EffectWorld()
    private let departures = WindowDepartureTracker()
    private let preferences = Preferences()
    private let updater = Updater()
    private let weather = WeatherModel()
    private let elements = ElementLocator()
    private var overlays: [Overlay] = []
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var timer: Timer?
    private var dockFrame: CGRect?
    private var ticks = 0
    private var lastSpaces: [Int] = []
    private var lastFrames: [CGRect] = []
    private var lastWindowChange: CFTimeInterval = 0
    private var lastSpaceChange: CFTimeInterval = 0
    private var lastDigest = 0
    private var lastStillDraw: CFTimeInterval = 0
    private lazy var pauseItem = item("Pause Snow", #selector(togglePause))
    private lazy var shakeItem = item("Shake Off Snow", #selector(shakeOff))
    private lazy var modeItem: NSMenuItem = {
        let modes = NSMenu()
        modes.addItem(item("Like Outside", #selector(chooseMode(_:))))
        modes.addItem(.separator())
        for mode in SnowMode.allCases {
            let entry = item(mode.title, #selector(chooseMode(_:)))
            entry.representedObject = mode.rawValue
            modes.addItem(entry)
        }
        let entry = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        entry.submenu = modes
        return entry
    }()

    private lazy var effectItem: NSMenuItem = {
        let menu = NSMenu()
        for effect in Effect.allCases {
            let entry = item(effect.title, #selector(chooseEffect(_:)))
            entry.representedObject = effect.rawValue
            menu.addItem(entry)
        }
        let entry = NSMenuItem(title: "Effect", action: nil, keyEquivalent: "")
        entry.submenu = menu
        return entry
    }()

    @objc private func chooseEffect(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let effect = Effect(rawValue: raw) else { return }
        preferences.effect = effect
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Snowpile")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(pauseItem)
        menu.addItem(effectItem)
        menu.addItem(modeItem)
        menu.addItem(shakeItem)
        menu.addItem(item("Build a Snowman", #selector(buildSnowman)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Snowpile", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        preferences.onChange = { [weak self] in self?.apply() }
        weather.onChange = { [weak self] in self?.apply() }
        rebuildOverlays()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildOverlays),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        apply()
        if !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: "askedForDock") {
            UserDefaults.standard.set(true, forKey: "askedForDock")
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
        if CommandLine.arguments.contains("--settings") { showSettings() }
        if CommandLine.arguments.contains("--deep-snow") { world.fillFloor() }
        if CommandLine.arguments.contains("--snowman") { buildSnowman() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem.title = preferences.snowing ? "Pause Effects" : "Resume Effects"
        modeItem.isHidden = preferences.effect != .snow
        shakeItem.isHidden = preferences.effect != .snow
        for entry in effectItem.submenu?.items ?? [] {
            entry.state = entry.representedObject as? String == preferences.effect.rawValue ? .on : .off
        }
        for entry in modeItem.submenu?.items ?? [] where entry.action != nil {
            let raw = entry.representedObject as? String
            entry.state = preferences.followWeather ? (raw == nil ? .on : .off) : (raw == preferences.mode.rawValue ? .on : .off)
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private var shownScreens: [String] = []
    private var screens: [NSScreen] = []

    private func apply() {
        world.running = preferences.snowing
        effects.effect = preferences.effect
        effects.running = preferences.snowing
        effects.intensity = Float(preferences.intensity)
        effects.wind = Float(preferences.wind) * 35
        effects.brushes = preferences.pointer
        effects.onWindows = preferences.onWindows
        effects.onDock = preferences.onDock
        effects.onFloor = preferences.onFloor
        effects.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        weather.follow(preferences.followWeather && preferences.effect == .snow ? preferences.place : nil, yandexKey: preferences.yandexKey)
        if preferences.followWeather {
            let now = weather.conditions
            let storm = now.flatMap(SnowMode.outside)?.storm
            let side: Float = (now?.eastWind ?? 0) < 0 ? -1 : 1
            let realWind = Float(abs(now?.eastWind ?? 0)) * 6
            world.falling = (storm?.intensity ?? 0) > 0
            world.intensity = storm?.intensity ?? 0
            world.windBase = side * min(max(realWind, storm?.wind ?? 0), 180)
            world.windWanders = false
            world.windStrength = storm?.gusts ?? 0.35
            world.lift = storm?.lift ?? 0
            world.flakeScale = storm?.flakeScale ?? 1
            world.thaw = Float(min(max(now?.temperature ?? 0, 0) * 0.03, 0.3))
        } else {
            let storm = preferences.mode.storm
            let custom = preferences.mode == .custom
            world.falling = storm.intensity > 0
            world.intensity = custom ? Float(preferences.intensity) : storm.intensity
            world.windBase = custom ? 0 : storm.wind
            world.windWanders = true
            world.windStrength = custom ? Float(preferences.wind) : storm.gusts
            world.lift = storm.lift
            world.flakeScale = storm.flakeScale
            world.thaw = 0
        }
        world.brushes = preferences.pointer
        world.settles = Set([
            preferences.onWindows ? .window : nil,
            preferences.onWindows ? .element : nil,
            preferences.onDock ? .dock : nil,
            preferences.onFloor ? .ground : nil,
        ].compactMap { $0 })
        statusItem.button?.appearsDisabled = !preferences.snowing
        if preferences.screens().map(Preferences.id(of:)) != shownScreens { rebuildOverlays() }
        poll()
    }

    @objc private func rebuildOverlays() {
        screens = preferences.screens()
        shownScreens = screens.map(Preferences.id(of:))
        overlays.forEach { $0.close() }
        overlays = screens.enumerated().map { Overlay(screen: $1, index: $0, world: world, effects: effects) }
        world.setScreens(screens.map(\.frame))
        effects.setScreens(screens.map(\.frame))
        poll()
    }

    /// Runs 30 times a second. The window list is read at full rate only while a mouse button is down or a window
    /// has just moved, and a few times a second otherwise. A still scene that only fades or thaws is redrawn
    /// a few times a second; one whose windows just moved, at every poll.
    private func poll() {
        let snow = preferences.effect == .snow
        if snow ? world.isIdle : effects.isIdle {
            overlays.forEach { $0.setActive(false) }
            return
        }
        let now = CACurrentMediaTime()
        ticks += 1
        let spaces = SpaceReader.current(for: screens)
        let switched = spaces != lastSpaces
        if switched { lastSpaceChange = now; effects.spaceChanged() }
        lastSpaces = spaces
        world.setSpaces(spaces)
        if ticks % 10 == 0 { dockFrame = DockLocator.frame() }
        if switched || NSEvent.pressedMouseButtons != 0 || now - lastWindowChange < 1 || ticks % 5 == 0 {
            if snow && world.settles.contains(.element) { elements.refresh(now: now) }
            let windows = WindowList.current()
            let frames = windows.map(\.frame)
            if frames != lastFrames {
                lastFrames = frames
                lastWindowChange = now
            }
            let departing = departures.departing(visible: windows, switched: now - lastSpaceChange < 1, now: now)
            world.updateWindows(windows, elements: elements.elements(in: windows), dock: dockFrame, now: now, departing: departing)
            effects.updateWindows(windows, dock: dockFrame)
        }
        if !snow {
            effects.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            for overlay in overlays {
                overlay.setActive(true)
                overlay.update(animating: effects.isAnimating, fast: !effects.reduceMotion && (effects.effect == .rain || effects.effect == .starfall), changed: true)
            }
            return
        }
        if !world.isAnimating {
            world.step(now: now, pointer: NSEvent.mouseLocation,
                       rolling: NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option)
        }
        let animating = world.isAnimating
        var changed = false
        if !animating, switched || now - lastWindowChange < 1 || now - lastStillDraw > 0.25 {
            let digest = world.sceneDigest
            changed = digest != lastDigest
            lastDigest = digest
            if changed { lastStillDraw = now }
        } else if animating {
            lastDigest = 0
        }
        for overlay in overlays {
            overlay.setActive(true)
            overlay.update(animating: animating, fast: world.isAnimatingFast, changed: changed)
        }
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = SnowMode(rawValue: raw) {
            preferences.mode = mode
            preferences.followWeather = false
        } else {
            preferences.followWeather = true
        }
    }

    @objc private func togglePause() {
        preferences.snowing.toggle()
    }

    @objc private func buildSnowman() {
        preferences.effect = .snow
        world.buildSnowman()
        poll()
    }

    @objc private func shakeOff() {
        world.shakeOff()
    }

    @objc private func checkForUpdates() {
        updater.checkNow()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(preferences: preferences, updater: updater, weather: weather)))
            window.title = "Snowpile Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

enum WindowList {
    private static var widgetHost: pid_t?

    /// Normal on-screen windows and then the desktop widgets behind them, front to back, in Cocoa coordinates.
    static func current() -> [(key: Int, frame: CGRect)] {
        guard let primary = NSScreen.screens.first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let height = primary.frame.height
        if widgetHost.flatMap(NSRunningApplication.init(processIdentifier:)) == nil {
            widgetHost = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier
        }
        return info.compactMap { w in
            let layer = w[kCGWindowLayer as String] as? Int
            // Desktop widgets are named windows of Notification Center sitting below the normal windows.
            let widget = layer.map { $0 < 0 } == true && (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == widgetHost
                && !(w[kCGWindowName as String] as? String ?? "").isEmpty
            guard layer == 0 || widget,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let number = w[kCGWindowNumber as String] as? Int,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  b.width >= 80, b.height >= 40
            else { return nil }
            let frame = CGRect(x: b.minX, y: height - b.maxY, width: b.width, height: b.height)
            // Widget corners are much rounder than a window's.
            return (number, widget ? frame.insetBy(dx: 12, dy: 0) : frame)
        }
    }
}

enum DockLocator {
    /// The bottom Dock's icon strip, read through Accessibility; nil without permission or for a side Dock.
    static func frame() -> CGRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let primary = NSScreen.screens.first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            guard (role as? String) == kAXListRole else { continue }
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &size) == .success else { continue }
            var p = CGPoint.zero
            var s = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &p)
            AXValueGetValue(size as! AXValue, .cgSize, &s)
            guard s.width > s.height else { return nil }
            let rect = CGRect(x: p.x, y: primary.frame.height - p.y - s.height, width: s.width, height: s.height)
            return NSScreen.screens.contains { $0.frame.contains(rect) } ? rect : nil
        }
        return nil
    }
}

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSManagedDisplayGetCurrentSpace") private func CGSManagedDisplayGetCurrentSpace(_ connection: Int32, _ display: CFString) -> Int

enum SpaceReader {
    /// The id of the Space each screen is showing.
    static func current(for screens: [NSScreen]) -> [Int] {
        let connection = CGSMainConnectionID()
        return screens.map { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let name = CFUUIDCreateString(nil, uuid) else { return 0 }
            return CGSManagedDisplayGetCurrentSpace(connection, name)
        }
    }
}
