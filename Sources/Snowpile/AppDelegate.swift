import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let world = SnowWorld()
    private let preferences = Preferences()
    private let updater = Updater()
    private let weather = WeatherModel()
    private var overlays: [Overlay] = []
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var timer: Timer?
    private var dockFrame: CGRect?
    private var ticks = 0
    private lazy var pauseItem = item("Pause Snow", #selector(togglePause))
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Snowpile")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(pauseItem)
        menu.addItem(modeItem)
        menu.addItem(item("Shake Off Snow", #selector(shakeOff)))
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
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.poll() }
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
        pauseItem.title = preferences.snowing ? "Pause Snow" : "Resume Snow"
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
        weather.follow(preferences.followWeather ? preferences.place : nil, yandexKey: preferences.yandexKey)
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
        overlays = screens.enumerated().map { Overlay(screen: $1, index: $0, world: world) }
        world.setScreens(screens.map(\.frame))
        poll()
    }

    private func poll() {
        if world.isIdle {
            overlays.forEach { $0.setActive(false) }
            return
        }
        if ticks % 3 == 0 { dockFrame = DockLocator.frame() }
        ticks += 1
        world.setSpaces(SpaceReader.current(for: screens))
        world.updateWindows(WindowList.current(), dock: dockFrame, now: CACurrentMediaTime())
        overlays.forEach { $0.setActive(true) }
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
    /// Normal on-screen windows, front to back, in Cocoa coordinates.
    static func current() -> [(key: Int, frame: CGRect)] {
        guard let primary = NSScreen.screens.first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let height = primary.frame.height
        let me = Int(getpid())
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let number = w[kCGWindowNumber as String] as? Int,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  b.width >= 80, b.height >= 40
            else { return nil }
            return (number, CGRect(x: b.minX, y: height - b.maxY, width: b.width, height: b.height))
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
