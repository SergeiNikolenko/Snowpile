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
    private var interactionMonitor: Any?
    private lazy var pauseItem = item("Pause Snow", #selector(togglePause))
    private lazy var pauseStatusItem: NSMenuItem = {
        let entry = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        entry.isEnabled = false
        entry.isHidden = true
        return entry
    }()
    private lazy var pauseIndefinitelySeparator = NSMenuItem.separator()
    private lazy var pauseIndefinitelyItem = item("Indefinitely", #selector(pauseIndefinitely))
    private lazy var pauseForItem: NSMenuItem = {
        let menu = NSMenu()
        for duration in PauseDuration.allCases {
            if duration == .untilTomorrow { menu.addItem(.separator()) }
            let entry = item(duration.title, #selector(pauseForDuration(_:)))
            entry.representedObject = duration.rawValue
            menu.addItem(entry)
        }
        menu.addItem(pauseIndefinitelySeparator)
        menu.addItem(pauseIndefinitelyItem)
        let entry = NSMenuItem(title: "Pause For", action: nil, keyEquivalent: "")
        entry.submenu = menu
        return entry
    }()
    private lazy var shakeItem = item("Shake Off Snow", #selector(shakeOff))
    private lazy var effectItem: NSMenuItem = {
        let menu = NSMenu()
        let outside = item("Like Outside", #selector(chooseEffect(_:)))
        outside.representedObject = "weather"
        menu.addItem(outside)
        menu.addItem(.separator())
        for mode in SnowMode.allCases {
            let entry = item(mode == .custom ? "Custom Snow" : mode.title, #selector(chooseEffect(_:)))
            entry.representedObject = "snow:" + mode.rawValue
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        for effect in Effect.allCases where effect != .snow {
            let entry = item(effect.title, #selector(chooseEffect(_:)))
            entry.representedObject = effect.rawValue
            menu.addItem(entry)
        }
        let entry = NSMenuItem(title: "Effect", action: nil, keyEquivalent: "")
        entry.submenu = menu
        return entry
    }()

    @objc private func chooseEffect(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        preferences.selection = raw
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Snowpile")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(pauseItem)
        menu.addItem(pauseStatusItem)
        menu.addItem(pauseForItem)
        menu.addItem(effectItem)
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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        interactionMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseUp]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.world.running, self.world.settles.contains(.element) else { return }
                self.elements.noteInteraction(now: CACurrentMediaTime())
            }
        }
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
        preferences.resumeIfPauseExpired()
        pauseItem.title = preferences.snowing ? "Pause Effects" : "Resume Effects"
        if let summary = preferences.pauseStatusSummary() {
            pauseStatusItem.title = summary
            pauseStatusItem.isHidden = false
            pauseIndefinitelySeparator.isHidden = false
            pauseIndefinitelyItem.isHidden = false
            statusItem.button?.toolTip = "Snowpile — \(summary)"
        } else {
            pauseStatusItem.isHidden = true
            pauseIndefinitelySeparator.isHidden = true
            pauseIndefinitelyItem.isHidden = true
        }
        shakeItem.isHidden = activeEffect != .snow
        for entry in effectItem.submenu?.items ?? [] {
            entry.state = entry.representedObject as? String == preferences.selection ? .on : .off
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private var shownScreens: [String] = []
    private var shownScreenFrames: [CGRect] = []
    private var shownScreenScales: [CGFloat] = []
    private var screens: [NSScreen] = []

    private var activeEffect: Effect {
        preferences.followWeather ? weather.conditions?.recommendedEffect ?? .snow : preferences.effect
    }

    private func apply() {
        weather.follow(preferences.followWeather ? preferences.place : nil, yandexKey: preferences.yandexKey)
        world.running = preferences.snowing && activeEffect == .snow
        effects.effect = activeEffect
        effects.running = preferences.snowing && (!preferences.followWeather || weather.conditions?.recommendedEffect == .rain)
        effects.intensity = preferences.followWeather ? weather.conditions?.rainIntensity ?? 0 : Float(preferences.intensity)
        effects.wind = preferences.followWeather ? Float(weather.conditions?.eastWind ?? 0) * 6 : Float(preferences.wind) * 35
        effects.lightningEnabled = !preferences.followWeather || weather.conditions?.thunderstorm == true
        effects.brushes = preferences.pointer
        effects.onWindows = preferences.onWindows
        effects.onDock = preferences.onDock
        effects.onFloor = preferences.onFloor
        effects.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
        if preferences.snowing {
            statusItem.button?.toolTip = "Snowpile"
        } else if let summary = preferences.pauseStatusSummary() {
            statusItem.button?.toolTip = "Snowpile — \(summary)"
        } else {
            statusItem.button?.toolTip = "Snowpile — Paused"
        }
        syncScreensIfNeeded()
        poll()
    }

    @discardableResult
    private func syncScreensIfNeeded() -> Bool {
        let desired = preferences.screens()
        let ids = desired.map(Preferences.id(of:))
        let frames = desired.map(\.frame)
        let scales = desired.map(\.backingScaleFactor)
        guard ids != shownScreens || frames != shownScreenFrames || scales != shownScreenScales else { return false }
        rebuildOverlays()
        return true
    }

    @objc private func rebuildOverlays() {
        screens = preferences.screens()
        shownScreens = screens.map(Preferences.id(of:))
        shownScreenFrames = screens.map(\.frame)
        shownScreenScales = screens.map(\.backingScaleFactor)
        overlays.forEach { $0.close() }
        overlays = screens.enumerated().map { Overlay(screen: $1, index: $0, world: world, effects: effects) }
        world.setScreens(screens.map(\.frame), visible: screens.map(\.visibleFrame))
        effects.setScreens(screens.map(\.frame))
        poll()
    }

    /// Runs 30 times a second. The window list is read at full rate only while a mouse button is down or a window
    /// has just moved, and a few times a second otherwise. A still scene that only fades or thaws is redrawn
    /// a few times a second; one whose windows just moved, at every poll.
    private func poll() {
        if preferences.pausedUntil != nil, preferences.resumeIfPauseExpired() {
            return
        }
        ticks += 1
        if ticks % 30 == 0, syncScreensIfNeeded() {
            return
        }
        let snow = activeEffect == .snow
        if snow ? world.isIdle : effects.isIdle {
            overlays.forEach { $0.setActive(false) }
            return
        }
        let now = CACurrentMediaTime()
        let spaces = SpaceReader.current(for: screens)
        let switched = spaces != lastSpaces
        if switched {
            lastSpaceChange = now
            effects.spaceChanged()
            overlays.forEach { $0.ensureOnTop() }
        }
        lastSpaces = spaces
        world.setSpaces(spaces)
        if ticks % 10 == 0 { dockFrame = DockLocator.frame() }
        if switched || NSEvent.pressedMouseButtons != 0 || now - lastWindowChange < 1 || ticks % 5 == 0 {
            let ownedWindows = WindowList.currentWithOwners()
            let windows = ownedWindows.map { (key: $0.key, frame: $0.frame) }
            if snow && world.settles.contains(.element) {
                elements.refresh(now: now, visiblePIDs: ownedWindows.map(\.pid))
            }
            let frames = windows.map(\.frame)
            if frames != lastFrames {
                lastFrames = frames
                lastWindowChange = now
            }
            let departing = departures.departing(visible: windows, switched: now - lastSpaceChange < 1, now: now)
            let elementScene = elements.scene(in: windows)
            world.updateWindows(windows, elements: elementScene.elements, occluders: elementScene.occluders,
                                dock: dockFrame, now: now, departing: departing)
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

    @objc private func togglePause() {
        if preferences.snowing {
            preferences.pauseIndefinitely()
        } else {
            preferences.resume()
        }
    }

    @objc private func pauseForDuration(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let duration = PauseDuration(rawValue: raw) else { return }
        preferences.pause(for: duration)
    }

    @objc private func pauseIndefinitely() {
        preferences.pauseIndefinitely()
    }

    @objc private func didWake() {
        preferences.resumeIfPauseExpired()
        if !syncScreensIfNeeded() {
            overlays.forEach { $0.ensureOnTop() }
            poll()
        }
    }

    @objc private func buildSnowman() {
        preferences.selection = "snow:" + preferences.mode.rawValue
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
        currentWithOwners().map { ($0.key, $0.frame) }
    }

    /// Normal on-screen windows (with owner PIDs) and desktop widgets, front to back, in Cocoa coordinates.
    static func currentWithOwners() -> [(key: Int, frame: CGRect, pid: pid_t)] {
        guard let primary = NSScreen.screens.first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let height = primary.frame.height
        if widgetHost.flatMap(NSRunningApplication.init(processIdentifier:)) == nil {
            widgetHost = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier
        }
        return info.compactMap { w in
            let layer = w[kCGWindowLayer as String] as? Int
            let ownerPID = (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init)
            let name = w[kCGWindowName as String] as? String ?? ""
            // Desktop widgets are named windows of Notification Center sitting below the normal windows.
            let widget = layer.map { $0 < 0 } == true && ownerPID == widgetHost && !name.isEmpty
            let app = !widget ? ownerPID.flatMap(NSRunningApplication.init(processIdentifier:)) : nil
            guard layer == 0 || widget,
                  shouldInclude(widget: widget, windowName: name, activationPolicy: app?.activationPolicy, hasBundleIdentifier: app?.bundleIdentifier != nil),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let number = w[kCGWindowNumber as String] as? Int,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  b.width >= 80, b.height >= 40
            else { return nil }
            let frame = CGRect(x: b.minX, y: height - b.maxY, width: b.width, height: b.height)
            // Widget corners are much rounder than a window's.
            return (number, widget ? frame.insetBy(dx: 12, dy: 0) : frame, ownerPID ?? 0)
        }
    }

    /// Ignores invisible background helper windows (such as CLI drivers with no bundle ID or title) so they never occlude real windows.
    static func shouldInclude(widget: Bool, windowName: String, activationPolicy: NSApplication.ActivationPolicy?, hasBundleIdentifier: Bool) -> Bool {
        if widget { return true }
        guard let policy = activationPolicy else { return !windowName.isEmpty }
        if policy == .prohibited { return false }
        if policy != .regular && !hasBundleIdentifier && windowName.isEmpty { return false }
        return true
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
