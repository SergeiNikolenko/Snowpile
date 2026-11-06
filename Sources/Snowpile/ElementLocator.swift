import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ window: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Text fields and search boxes in the windows of the app in front, read through Accessibility in the background.
/// Each is kept as an offset from its window, so it moves with the window between reads,
/// and apps that went to the back keep theirs until they come to the front again.
final class ElementLocator: @unchecked Sendable {
    private static let roles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static let elementKeys = 1 << 40

    private let queue = DispatchQueue(label: "Snowpile.elements", qos: .utility)
    private let lock = NSLock()
    /// Offsets from each window's top left corner, in window-server points (y grows down).
    private var byWindow: [Int: [CGRect]] = [:]
    private var busy = false

    func refresh() {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return }
        let start = lock.withLock { () -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        }
        guard start else { return }
        let pid = app.processIdentifier
        queue.async { [self] in
            let found = Self.scan(pid)
            lock.withLock {
                byWindow.merge(found) { $1 }
                busy = false
            }
        }
    }

    /// The known elements of `windows` in Cocoa coordinates, each with a key that stays put while the element does.
    func elements(in windows: [(key: Int, frame: CGRect)]) -> [(key: Int, frame: CGRect, window: Int)] {
        let known = lock.withLock { byWindow }
        var out: [(key: Int, frame: CGRect, window: Int)] = []
        for w in windows {
            for r in known[w.key] ?? [] {
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

    private static func scan(_ pid: pid_t) -> [Int: [CGRect]] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Chromium and Electron apps only build their accessibility tree once someone asks for it.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return [:] }
        var out: [Int: [CGRect]] = [:]
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
                pending += node.children
            }
            out[Int(id)] = found
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
