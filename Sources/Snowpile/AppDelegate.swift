import AppKit
import ApplicationServices
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let world = SnowWorld()
    private let preferences = Preferences()
    private let updater = Updater()
    private var overlays: [Overlay] = []
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var timer: Timer?
    private var dockFrame: CGRect?
    private var ticks = 0
    private lazy var pauseItem = item("Pause Snow", #selector(togglePause))

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Snowpile")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(pauseItem)
        menu.addItem(item("Shake Off Snow", #selector(shakeOff)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Snowpile", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        preferences.onChange = { [weak self] in self?.apply() }
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
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem.title = preferences.snowing ? "Pause Snow" : "Resume Snow"
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
        world.intensity = Float(preferences.intensity)
        world.windStrength = Float(preferences.wind)
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

    @objc private func togglePause() {
        preferences.snowing.toggle()
    }

    @objc private func shakeOff() {
        world.shakeOff()
    }

    @objc private func checkForUpdates() {
        updater.checkNow()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(preferences: preferences, updater: updater)))
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
