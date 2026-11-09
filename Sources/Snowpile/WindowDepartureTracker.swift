import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func departureWindowID(_ element: AXUIElement, _ window: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Distinguishes a closed or minimized window from a window hidden by another Space.
/// AX reads run off the render thread and only inspect the window list, never its controls.
final class WindowDepartureTracker {
    private var visibleIDs: Set<Int> = []
    private var pending: [Int: (pid: pid_t, since: CFTimeInterval)] = [:]
    private var reported: Set<Int> = []
    private var spaceChangedAt: CFTimeInterval = -.infinity
    private var lastScan: CFTimeInterval = -.infinity
    private var lastWindowQuery: CFTimeInterval = -.infinity
    private var lastFront: pid_t?
    private let queue = DispatchQueue(label: "Snowpile.window-departures", qos: .utility)
    private let lock = NSLock()
    private var reading = false
    private var minimized: [Int: CFTimeInterval] = [:]

    func departing(visible: [(key: Int, frame: CGRect)], switched: Bool, now: CFTimeInterval) -> Set<Int> {
        let current = Set(visible.map(\.key))
        let missing = visibleIDs.subtracting(current)
        reported.subtract(current.subtracting(visibleIDs))
        defer { visibleIDs = current }
        if switched {
            spaceChangedAt = now
            pending.removeAll()
            reported.removeAll()
        }
        // Space transitions can briefly expose windows from both Spaces.
        guard now - spaceChangedAt > 0.8 else { return [] }

        var departed: Set<Int> = []
        pending = pending.filter { !current.contains($0.key) && now - $0.value.since < 2 }
        // A closing window can leave the visible list before WindowServer removes its fading frame.
        let needsWindowQuery = !missing.isEmpty || (!pending.isEmpty && now - lastWindowQuery >= 0.25)
        if needsWindowQuery { lastWindowQuery = now }
        if needsWindowQuery,
           let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
            var owners: [Int: pid_t] = [:]
            for window in all {
                guard let id = window[kCGWindowNumber as String] as? Int,
                      let owner = window[kCGWindowOwnerPID as String] as? Int else { continue }
                owners[id] = pid_t(owner)
            }
            for id in missing.union(pending.keys) {
                if let previous = pending[id], NSRunningApplication(processIdentifier: previous.pid)?.isHidden == true {
                    pending[id] = nil
                    continue
                }
                guard let pid = owners[id] else {
                    departed.insert(id)
                    continue
                }
                guard NSRunningApplication(processIdentifier: pid)?.isHidden == false else {
                    pending[id] = nil
                    continue
                }
                pending[id] = (pid, pending[id]?.since ?? now)
            }
        }
        let observations = lock.withLock { minimized }
        for (id, time) in observations where time > spaceChangedAt && now - time < 1 {
            if current.contains(id) || pending[id] != nil { departed.insert(id) }
        }
        departed.subtract(reported)
        reported.formUnion(departed)
        for id in departed { pending[id] = nil }
        // Keep deduplication bounded to windows still visible or awaiting their final disappearance.
        reported.formIntersection(current.union(missing).union(pending.keys))

        let front = NSWorkspace.shared.frontmostApplication
        let frontPID = front?.processIdentifier
        if AXIsProcessTrusted(), now - lastScan >= 0.35 || frontPID != lastFront || !missing.isEmpty {
            var pids = Set(pending.values.map(\.pid))
            if let frontPID, frontPID != getpid(), front?.isHidden == false { pids.insert(frontPID) }
            let canRead = lock.withLock { () -> Bool in
                guard !reading else { return false }
                reading = true
                return true
            }
            if canRead {
                lastScan = now
                lastFront = frontPID
                let applications = pids
                queue.async { [self] in
                    var found: [Int: CFTimeInterval] = [:]
                    for pid in applications {
                        guard NSRunningApplication(processIdentifier: pid)?.isHidden == false else { continue }
                        let app = AXUIElementCreateApplication(pid)
                        AXUIElementSetMessagingTimeout(app, 0.05)
                        var value: CFTypeRef?
                        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                              let windows = value as? [AXUIElement] else { continue }
                        for window in windows.prefix(100) {
                            var state: CFTypeRef?
                            guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &state) == .success,
                                  state as? Bool == true else { continue }
                            var id: CGWindowID = 0
                            if departureWindowID(window, &id) == .success { found[Int(id)] = now }
                        }
                    }
                    lock.withLock {
                        minimized = found
                        reading = false
                    }
                }
            }
        }
        return departed
    }
}
