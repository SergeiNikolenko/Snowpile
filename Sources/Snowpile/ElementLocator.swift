import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ window: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Text fields and search boxes in the windows of the app in front, read through Accessibility in the background.
/// Each is kept as an offset from its window, so it moves with the window between reads,
/// and apps that went to the back keep theirs until they come to the front again.
///
/// Reading is not free for the app being read, so it happens only when the front app changes,
/// when a window with fields is resized, and otherwise every few seconds.
final class ElementLocator: @unchecked Sendable {
    private static let roles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// Roles that never hold a text field; skipping what is inside them, text runs above all, keeps a read cheap.
    private static let leaves: Set<String> = ["AXStaticText", "AXImage", "AXButton", "AXLink", "AXHeading", "AXCheckBox",
                                              "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXProgressIndicator"]
    private static let elementKeys = 1 << 40
    private static let rescanEvery: CFTimeInterval = 8
    private static let manual = "AXManualAccessibility" as CFString

    private let queue = DispatchQueue(label: "Snowpile.elements", qos: .utility)
    private let lock = NSLock()
    /// Offsets from each window's top left corner, in window-server points (y grows down), and the window size they were read at.
    private var byWindow: [Int: (size: CGSize, offsets: [CGRect])] = [:]
    private var busy = false
    private var lastScan: CFTimeInterval = 0
    private var lastApp: pid_t = 0
    private var resized = false
    private var electron: [pid_t: Bool] = [:]

    /// Starts a background read when one is due.
    func refresh(now: CFTimeInterval) {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return }
        let pid = app.processIdentifier
        let due = lock.withLock { () -> Bool in
            guard !busy, pid != lastApp || resized || now - lastScan > Self.rescanEvery else { return false }
            busy = true
            lastApp = pid
            lastScan = now
            resized = false
            return true
        }
        guard due else { return }
        if electron[pid] == nil {
            electron[pid] = app.bundleURL.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
            } ?? false
        }
        let wakes = electron[pid] == true
        queue.async { [self] in
            let found = Self.scan(pid, wakingElectron: wakes)
            lock.withLock {
                byWindow.merge(found) { $1 }
                busy = false
            }
        }
    }

    /// The known elements of `windows` in Cocoa coordinates, each with a key that stays put while the element does.
    /// A window resized since it was read has its fields dropped until it is read again.
    func elements(in windows: [(key: Int, frame: CGRect)]) -> [(key: Int, frame: CGRect, window: Int)] {
        lock.lock()
        defer { lock.unlock() }
        var out: [(key: Int, frame: CGRect, window: Int)] = []
        for w in windows {
            guard let known = byWindow[w.key], !known.offsets.isEmpty else { continue }
            guard known.size == w.frame.size else {
                resized = true
                continue
            }
            for r in known.offsets {
                var h = Hasher()
                h.combine(w.key)
                h.combine(Int(r.minX))
                h.combine(Int(r.minY))
                h.combine(Int(r.width))
                let key = Self.elementKeys | (h.finalize() & (Self.elementKeys - 1))
                out.append((key, CGRect(x: w.frame.minX + r.minX, y: w.frame.maxY - r.maxY, width: r.width, height: r.height), w.key))
            }
        }
        return out
    }

    private static func scan(_ pid: pid_t, wakingElectron: Bool) -> [Int: (size: CGSize, offsets: [CGRect])] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Electron apps build their accessibility tree only on request and keep updating it while it is on,
        // so it is switched on just for the read and back off, unless something else had it on already.
        var wasOn: CFTypeRef?
        let woke = wakingElectron
            && !(AXUIElementCopyAttributeValue(app, manual, &wasOn) == .success && (wasOn as? Bool) == true)
        if woke {
            AXUIElementSetAttributeValue(app, manual, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.6)
        }
        defer { if woke { AXUIElementSetAttributeValue(app, manual, kCFBooleanFalse) } }
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return [:] }
        var out: [Int: (size: CGSize, offsets: [CGRect])] = [:]
        for window in list {
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &id) == .success, let box = read(window).frame else { continue }
            var found: [CGRect] = []
            var pending = [window]
            var next = 0
            while next < pending.count, next < 3000 {
                let node = read(pending[next])
                next += 1
                if let role = node.role, roles.contains(role) {
                    // Snow lies on the field's top edge, so the edge has to be inside the window, below its title bar.
                    if let r = node.frame, r.width >= 60, r.height >= 14, r.minY > box.minY + 8, box.contains(r) {
                        found.append(r.offsetBy(dx: -box.minX, dy: -box.minY))
                    }
                    continue
                }
                if let role = node.role, leaves.contains(role) { continue }
                pending += node.children
            }
            out[Int(id)] = (box.size, found)
        }
        return out
    }

    private static func read(_ element: AXUIElement) -> (role: String?, frame: CGRect?, children: [AXUIElement]) {
        let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
              let v = values as? [AnyObject], v.count == 4 else { return (nil, nil, []) }
        var origin = CGPoint.zero
        var size = CGSize.zero
        var frame: CGRect?
        if CFGetTypeID(v[1]) == AXValueGetTypeID(), CFGetTypeID(v[2]) == AXValueGetTypeID(),
           AXValueGetValue(v[1] as! AXValue, .cgPoint, &origin), AXValueGetValue(v[2] as! AXValue, .cgSize, &size) {
            frame = CGRect(origin: origin, size: size)
        }
        return (v[0] as? String, frame, v[3] as? [AXUIElement] ?? [])
    }
}
