import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ window: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Text fields, input composers, cards, message bubbles, floating panels and readable text blocks in visible app
/// windows, read through Accessibility in the background.
/// Each rect is kept as an offset from its window, so it moves with the window between reads,
/// and apps that went to the back keep theirs until they are read again.
///
/// Reading is not free for the app being read, so it happens on focus change, resize, shortly after
/// scrolling/clicking, and periodically for visible apps across all displays.
final class ElementLocator: @unchecked Sendable {
    struct ExtractedOccluder: Equatable {
        let rect: CGRect
        let isSurfaceBody: Bool
    }

    struct WindowLayout: Equatable {
        let surfaces: [CGRect]
        let occluders: [ExtractedOccluder]
    }

    struct ContentOccluder: Equatable {
        let frame: CGRect
        let window: Int
        let isSurfaceBody: Bool
    }

    struct NodeSnapshot {
        let role: String
        let subrole: String
        let frame: CGRect
        let clip: CGRect
        let classes: [String]
        let parent: Int?
        let childCount: Int
    }

    struct SurfaceStyle: Equatable {
        var isRounded = false
        var cornerRadius: CGFloat = 4
        var hasBackground = false
        var hasFrame = false
        var hasComponentCue = false
        var isComposerCue = false
        var isFloating = false
        var isHiddenOrOverlay = false

        var isVisualSurface: Bool {
            !isHiddenOrOverlay && (hasComponentCue || (isRounded && (hasBackground || hasFrame)) || (hasBackground && hasFrame))
        }

        private static let activePrefixes: Set<String> = [
            "dark", "light", "electron", "extension", "browser", "macos", "sm", "md", "lg", "xl", "2xl"
        ]
        private static let ignoredTokens: Set<String> = [
            "pointer-events-none", "contents", "sr-only", "hidden", "invisible", "opacity-0"
        ]
        private static let nonFillBackgrounds: Set<String> = [
            "bg-transparent", "bg-inherit", "bg-none", "bg-current", "bg-auto", "bg-cover", "bg-contain",
            "bg-center", "bg-top", "bg-bottom", "bg-left", "bg-right", "bg-fixed", "bg-local", "bg-scroll",
            "bg-repeat", "bg-no-repeat", "bg-repeat-x", "bg-repeat-y", "bg-repeat-round", "bg-repeat-space"
        ]
        private static let nonFillBackgroundPrefixes = [
            "bg-clip-", "bg-origin-", "bg-opacity-", "bg-blend-"
        ]
        private static let nonFrameBorders: Set<String> = [
            "border-0", "border-none", "border-transparent", "border-inherit", "border-current",
            "border-collapse", "border-separate", "border-solid", "border-dashed", "border-dotted",
            "border-double", "border-hidden"
        ]
        private static let directionalBorderPrefixes = [
            "border-t", "border-b", "border-l", "border-r", "border-s", "border-e", "border-x", "border-y", "border-spacing"
        ]
        private static let componentWords: Set<String> = [
            "bubble", "card", "composer", "popover", "modal", "dialog", "toast", "callout", "codeblock", "widget"
        ]
        private static let composerWords: Set<String> = [
            "composer", "promptbox", "chatbox", "inputbox", "messagebox"
        ]
        private static let floatingWords: Set<String> = [
            "popover", "modal", "dialog", "toast", "floating", "drawer", "tooltip"
        ]

        static func classify(classes: [String]) -> SurfaceStyle {
            var style = SurfaceStyle()
            for raw in classes {
                if ignoredTokens.contains(raw) {
                    style.isHiddenOrOverlay = true
                    return style
                }
            }
            for raw in classes {
                if raw.hasPrefix("group/") {
                    let suffix = String(raw.dropFirst("group/".count))
                    if suffix.contains("summary-panel") || suffix.contains("floating") { style.isFloating = true }
                    continue
                }
                guard !raw.hasPrefix("peer/") else { continue }
                guard let base = activeBaseToken(raw) else { continue }
                inspect(base: base, into: &style)
            }
            if style.isComposerCue {
                style.cornerRadius = max(style.cornerRadius, 14)
            }
            return style
        }

        private static func activeBaseToken(_ raw: String) -> String? {
            var remaining = Substring(raw)
            while let colon = remaining.firstIndex(of: ":") {
                let prefix = String(remaining[..<colon])
                guard activePrefixes.contains(prefix) else { return nil }
                remaining = remaining[remaining.index(after: colon)...]
            }
            return remaining.isEmpty ? nil : String(remaining)
        }

        private static func inspect(base: String, into style: inout SurfaceStyle) {
            if base == "rounded" || base.hasPrefix("rounded-") {
                if let radius = parseCornerRadius(base) {
                    style.isRounded = true
                    style.cornerRadius = max(style.cornerRadius, radius)
                }
            } else if base.hasPrefix("bg-") {
                if !nonFillBackgrounds.contains(base), !nonFillBackgroundPrefixes.contains(where: base.hasPrefix) {
                    style.hasBackground = true
                }
            } else if base == "border" || base.hasPrefix("border-") {
                if !nonFrameBorders.contains(base), !directionalBorderPrefixes.contains(where: { base == $0 || base.hasPrefix($0 + "-") }) {
                    style.hasFrame = true
                }
            } else if base == "ring" || base.hasPrefix("ring-") {
                if base != "ring-0", base != "ring-none", base != "ring-transparent", base != "ring-inset" {
                    style.hasFrame = true
                }
            } else if base == "shadow" || base.hasPrefix("shadow-") {
                if base != "shadow-none", base != "shadow-transparent" {
                    style.hasFrame = true
                    if base != "shadow-xs", base != "shadow-2xs" { style.isFloating = true }
                }
            } else if base.hasPrefix("elevation-") {
                style.hasFrame = true
                style.isFloating = true
            } else if base == "fixed" || base == "sticky" {
                style.isFloating = true
            } else if base.hasPrefix("z-") {
                let suffix = base.dropFirst(2)
                if suffix != "0" && suffix != "auto" && !suffix.hasPrefix("-") {
                    style.isFloating = true
                }
            }

            let words = splitWords(base)
            if words.contains(where: composerWords.contains) {
                style.isComposerCue = true
                style.hasComponentCue = true
                style.isFloating = true
            } else if words.contains(where: componentWords.contains) {
                style.hasComponentCue = true
                if words.contains(where: floatingWords.contains) { style.isFloating = true }
            } else if hasCompoundCue(words) {
                style.hasComponentCue = true
                if words.contains("floating") || words.contains("summary") { style.isFloating = true }
            }
        }

        private static func parseCornerRadius(_ base: String) -> CGFloat? {
            if base == "rounded-none" || base == "rounded-0" || base == "rounded-inherit"
                || base == "rounded-[0]" || base == "rounded-[0px]" || base == "rounded-[inherit]" {
                return nil
            }
            if base.hasPrefix("rounded-b") || base.hasPrefix("rounded-bl") || base.hasPrefix("rounded-br") {
                return nil
            }
            switch base {
            case "rounded-full", "rounded-3xl", "rounded-4xl": return 16
            case "rounded-2xl": return 14
            case "rounded-xl": return 11
            case "rounded-lg": return 8
            case "rounded", "rounded-md", "rounded-sm": return 6
            default:
                if base.hasPrefix("rounded-t-") { return 10 }
                if base.hasPrefix("rounded-["), base.hasSuffix("]") {
                    let inner = String(base.dropFirst("rounded-[".count).dropLast())
                    if inner.hasSuffix("px"), let px = Double(inner.dropLast(2)) {
                        return px >= 6 ? min(CGFloat(px) * 0.75, 18) : nil
                    }
                    return 10
                }
                if base.hasPrefix("rounded-(") { return 10 }
                return nil
            }
        }

        private static func splitWords(_ token: String) -> [String] {
            var words: [String] = []
            var current = ""
            var prevWasLower = false
            for ch in token {
                if ch == "-" || ch == "_" || ch == "/" || !ch.isLetter && !ch.isNumber {
                    if !current.isEmpty { words.append(current.lowercased()); current = "" }
                    prevWasLower = false
                    continue
                }
                if ch.isUppercase && prevWasLower && !current.isEmpty {
                    words.append(current.lowercased())
                    current = ""
                }
                current.append(ch)
                prevWasLower = ch.isLowercase
            }
            if !current.isEmpty { words.append(current.lowercased()) }
            return words
        }

        private static func hasCompoundCue(_ words: [String]) -> Bool {
            guard words.count >= 2 else { return false }
            for i in 0..<(words.count - 1) {
                switch (words[i], words[i + 1]) {
                case ("code", "block"), ("summary", "panel"), ("floating", "panel"),
                     ("input", "bar"), ("search", "bar"), ("user", "message"):
                    return true
                default: break
                }
            }
            return false
        }
    }

    private static let inputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static let nativeBoxRoles: Set<String> = ["AXBox", "AXPopover", "AXSheet"]
    private static let dialogSubroles: Set<String> = ["AXApplicationDialog", "AXApplicationAlertDialog", "AXPopover", "AXDialog"]
    private static let textLeafRoles: Set<String> = ["AXStaticText", "AXHeading", "AXLink", "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
    private static let surfaceContainerRoles: Set<String> = [
        "AXGroup", "AXSection", "AXArticle", "AXForm", "AXList", "AXLandmarkRegion", "AXLandmarkComplementary"
    ]
    private static let stopAncestorRoles: Set<String> = ["AXScrollArea", "AXWebArea", "AXWindow", "AXToolbar", "AXSplitGroup", "AXTabGroup"]
    /// Roles that never hold a text field or card surface; skipping what is inside them keeps a read cheap.
    private static let leaves: Set<String> = ["AXStaticText", "AXImage", "AXButton", "AXLink", "AXHeading", "AXCheckBox",
                                              "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXProgressIndicator",
                                              "AXListMarker", "AXSplitter", "AXScrollBar", "AXMenuBar", "AXMenu"]
    private static let elementKeys = 1 << 40
    private static let rescanEvery: CFTimeInterval = 3
    private static let backgroundRescanEvery: CFTimeInterval = 7
    private static let electronWakeCooldown: CFTimeInterval = 7
    private static let chromiumWakeCooldown: CFTimeInterval = 6
    private static let interactionDebounce: CFTimeInterval = 0.35
    private static let maxVisitedNodes = 5000
    private static let maxSurfacesPerWindow = 24
    private static let maxOccludersPerWindow = 48
    private static let manual = "AXManualAccessibility" as CFString
    private static let enhancedUI = "AXEnhancedUserInterface" as CFString
    private static let domClassList = "AXDOMClassList" as CFString

    enum WakeMode: Equatable {
        case standard
        case electron
        case chromium
    }

    private let queue = DispatchQueue(label: "Snowpile.elements", qos: .utility)
    private let lock = NSLock()
    /// Offsets from each window's top left corner, in window-server points (y grows down), and the window size they were read at.
    private var byWindow: [Int: (size: CGSize, layout: WindowLayout)] = [:]
    private var busy = false
    private var lastScanByPID: [pid_t: CFTimeInterval] = [:]
    private var lastApp: pid_t = 0
    private var resized = false
    private var dirtyAt: CFTimeInterval?
    private var wakeModes: [pid_t: WakeMode] = [:]

    /// Marks the front app's layout as possibly changed (e.g. after scrolling or clicking) so it rescans shortly after settling.
    func noteInteraction(now: CFTimeInterval) {
        lock.withLock { dirtyAt = now }
    }

    /// Starts a background read for the frontmost app or another visible app on screen when due.
    func refresh(now: CFTimeInterval, visiblePIDs: [pid_t] = []) {
        guard AXIsProcessTrusted() else { return }
        let selfPID = getpid()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var orderedPIDs: [pid_t] = []
        if let frontPID, frontPID != selfPID { orderedPIDs.append(frontPID) }
        for pid in visiblePIDs where pid != selfPID && !orderedPIDs.contains(pid) {
            orderedPIDs.append(pid)
        }
        guard !orderedPIDs.isEmpty else { return }

        var chosen: (pid: pid_t, mode: WakeMode)?
        lock.withLock {
            guard !busy else { return }
            let interactionReady = dirtyAt.map { now - $0 >= Self.interactionDebounce } ?? false
            for pid in orderedPIDs {
                let mode = wakeMode(for: pid)
                let isFront = pid == frontPID
                let last = lastScanByPID[pid] ?? 0
                let cooldown: CFTimeInterval
                switch mode {
                case .electron: cooldown = isFront ? Self.electronWakeCooldown : max(Self.electronWakeCooldown, Self.backgroundRescanEvery + 3)
                case .chromium: cooldown = isFront ? Self.chromiumWakeCooldown : max(Self.chromiumWakeCooldown, Self.backgroundRescanEvery + 2)
                case .standard: cooldown = isFront ? Self.rescanEvery : Self.backgroundRescanEvery
                }
                let neverScanned = last == 0
                let due: Bool
                if isFront {
                    let switched = pid != lastApp
                    let fastTrigger = (switched || resized || interactionReady) && (mode == .standard || neverScanned || now - last >= 2.0)
                    due = neverScanned || fastTrigger || (now - last >= cooldown)
                } else {
                    due = neverScanned || (now - last >= cooldown)
                }
                if due {
                    busy = true
                    if isFront {
                        lastApp = pid
                        resized = false
                        dirtyAt = nil
                    }
                    lastScanByPID[pid] = now
                    chosen = (pid, mode)
                    break
                }
            }
        }
        guard let target = chosen else { return }
        queue.async { [self] in
            let found = Self.scan(target.pid, mode: target.mode)
            lock.withLock {
                byWindow.merge(found) { $1 }
                busy = false
            }
        }
    }

    private func wakeMode(for pid: pid_t) -> WakeMode {
        if let cached = wakeModes[pid] { return cached }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return .standard }
        let mode = Self.detectWakeMode(bundleURL: app.bundleURL, bundleIdentifier: app.bundleIdentifier)
        wakeModes[pid] = mode
        return mode
    }

    static func detectWakeMode(bundleURL: URL?, bundleIdentifier: String?) -> WakeMode {
        if let url = bundleURL {
            let fm = FileManager.default
            let fw = url.appendingPathComponent("Contents/Frameworks")
            if fm.fileExists(atPath: fw.appendingPathComponent("Electron Framework.framework").path) {
                return .electron
            }
            let chromiumFrameworks = [
                "Codex Framework.framework",
                "Google Chrome Framework.framework",
                "Chromium Embedded Framework.framework",
                "Brave Browser Framework.framework",
                "Arc Framework.framework",
                "Microsoft Edge Framework.framework",
                "Dia Framework.framework",
                "Vivaldi Framework.framework",
                "Opera Framework.framework",
                "XUL.framework",
            ]
            if chromiumFrameworks.contains(where: { fm.fileExists(atPath: fw.appendingPathComponent($0).path) }) {
                return .chromium
            }
            let macOS = url.appendingPathComponent("Contents/MacOS")
            if fm.fileExists(atPath: macOS.appendingPathComponent("XUL").path)
                || fm.fileExists(atPath: macOS.appendingPathComponent("libxul.dylib").path) {
                return .chromium
            }
        }
        if let bid = bundleIdentifier?.lowercased() {
            if bid.hasPrefix("com.anthropic.") || bid.contains("claudefordesktop") || bid.contains("electron") {
                return .electron
            }
            if bid.hasPrefix("com.google.chrome") || bid.hasPrefix("company.thebrowser.")
                || bid.hasPrefix("com.brave.browser") || bid.hasPrefix("com.microsoft.edgemac")
                || bid.hasPrefix("com.openai.codex") || bid.hasPrefix("com.openai.chat")
                || bid.hasPrefix("com.openai.atlas") || bid.hasPrefix("ai.perplexity.comet")
                || bid.hasPrefix("app.zen-browser.") || bid.hasPrefix("org.mozilla.")
                || bid.hasPrefix("com.operasoftware.") || bid.hasPrefix("com.kagi.kagimacos")
                || bid.hasPrefix("org.chromium.") || bid.hasPrefix("com.vivaldi.") {
                return .chromium
            }
        }
        return .standard
    }

    /// The known elements of `windows` in Cocoa coordinates, each with a key that stays put while the element does.
    /// A window resized since it was read has its fields dropped until it is read again.
    func elements(in windows: [(key: Int, frame: CGRect)]) -> [(key: Int, frame: CGRect, window: Int)] {
        scene(in: windows).elements
    }

    /// Both landing surfaces and content occluders (card bodies + text blocks) for `windows` in Cocoa coordinates.
    func scene(in windows: [(key: Int, frame: CGRect)]) -> (elements: [(key: Int, frame: CGRect, window: Int)], occluders: [ContentOccluder]) {
        lock.lock()
        defer { lock.unlock() }
        var outElements: [(key: Int, frame: CGRect, window: Int)] = []
        var outOccluders: [ContentOccluder] = []
        for w in windows {
            guard let known = byWindow[w.key] else { continue }
            guard known.size == w.frame.size else {
                resized = true
                continue
            }
            for r in known.layout.surfaces {
                var h = Hasher()
                h.combine(w.key)
                h.combine(Int((r.minX / 2).rounded()))
                h.combine(Int((r.minY / 2).rounded()))
                h.combine(Int((r.width / 4).rounded()))
                let key = Self.elementKeys | (h.finalize() & (Self.elementKeys - 1))
                outElements.append((key, CGRect(x: w.frame.minX + r.minX, y: w.frame.maxY - r.maxY, width: r.width, height: r.height), w.key))
            }
            for occ in known.layout.occluders {
                let r = occ.rect
                let cocoa = CGRect(x: w.frame.minX + r.minX, y: w.frame.maxY - r.maxY, width: r.width, height: r.height)
                outOccluders.append(ContentOccluder(frame: cocoa, window: w.key, isSurfaceBody: occ.isSurfaceBody))
            }
        }
        return (outElements, outOccluders)
    }

    private enum CandidateKind: Int {
        case input = 1
        case surface = 2
        case composer = 3
    }

    private struct Candidate {
        let rect: CGRect
        let rawRect: CGRect
        let kind: CandidateKind
        let domIndex: Int
        let isFloating: Bool
    }

    /// Pure surface extraction from a window's AX snapshot list. Returns rects relative to the window's top-left corner,
    /// already trimmed for rounded corners and clipped to visible scroll viewports.
    static func extractSurfaces(windowFrame box: CGRect, nodes: [NodeSnapshot]) -> [CGRect] {
        extractLayout(windowFrame: box, nodes: nodes).surfaces
    }

    /// Extracts both snow-catching surfaces and solid content occluders (card bodies + merged vertical text blocks)
    /// in window-relative top-left coordinates.
    static func extractLayout(windowFrame box: CGRect, nodes: [NodeSnapshot]) -> WindowLayout {
        guard !nodes.isEmpty else { return WindowLayout(surfaces: [], occluders: []) }
        let styles = nodes.map { SurfaceStyle.classify(classes: $0.classes) }
        var promotedAncestors = Set<Int>()
        var candidates: [Candidate] = []

        for (index, node) in nodes.enumerated() where inputRoles.contains(node.role) {
            if let promoted = enclosingInputContainer(of: index, nodes: nodes, styles: styles, windowFrame: box) {
                if promotedAncestors.insert(promoted.index).inserted {
                    let ancestor = nodes[promoted.index]
                    let kind: CandidateKind = promoted.isNativeCapsule ? .input : .composer
                    let radius = promoted.cornerRadius
                    if let fitted = fitSurface(ancestor.frame, clip: ancestor.clip, in: box, kind: kind, cornerRadius: radius) {
                        let clippedRaw = clippedRelative(ancestor.frame, clip: ancestor.clip, in: box)
                        candidates.append(Candidate(rect: fitted, rawRect: clippedRaw, kind: kind,
                                                    domIndex: promoted.index, isFloating: !promoted.isNativeCapsule || styles[promoted.index].isFloating))
                    }
                }
                continue
            }
            let radius = max(styles[index].cornerRadius, 4)
            if let fitted = fitSurface(node.frame, clip: node.clip, in: box, kind: .input, cornerRadius: radius) {
                let clippedRaw = clippedRelative(node.frame, clip: node.clip, in: box)
                candidates.append(Candidate(rect: fitted, rawRect: clippedRaw, kind: .input, domIndex: index, isFloating: styles[index].isFloating))
            }
        }

        for (index, node) in nodes.enumerated() {
            guard !promotedAncestors.contains(index), !inputRoles.contains(node.role) else { continue }
            let isNativeBox = nativeBoxRoles.contains(node.role) || dialogSubroles.contains(node.subrole)
            let style = styles[index]
            let isWebSurface = surfaceContainerRoles.contains(node.role) && style.isVisualSurface
            guard isNativeBox || isWebSurface else { continue }
            let kind: CandidateKind = (style.isComposerCue && node.frame.height >= 44) ? .composer : .surface
            let radius = isNativeBox ? max(style.cornerRadius, 10) : style.cornerRadius
            let floating = style.isFloating || node.role == "AXPopover" || node.role == "AXSheet" || dialogSubroles.contains(node.subrole)
            if let fitted = fitSurface(node.frame, clip: node.clip, in: box, kind: kind, cornerRadius: radius) {
                let clippedRaw = clippedRelative(node.frame, clip: node.clip, in: box)
                candidates.append(Candidate(rect: fitted, rawRect: clippedRaw, kind: kind, domIndex: index, isFloating: floating))
            }
        }

        // Strict weak ordering: composers first, then cards, then raw inputs; higher surfaces before nested rows below them.
        candidates.sort { a, b in
            if a.kind.rawValue != b.kind.rawValue { return a.kind.rawValue > b.kind.rawValue }
            if a.rect.minY != b.rect.minY { return a.rect.minY < b.rect.minY }
            let areaA = a.rawRect.width * a.rawRect.height
            let areaB = b.rawRect.width * b.rawRect.height
            if areaA != areaB { return areaA < areaB }
            return a.rect.minX < b.rect.minX
        }

        var kept: [Candidate] = []
        for candidate in candidates {
            var duplicate = false
            for i in kept.indices {
                let existing = kept[i]
                let overlapX = min(existing.rect.maxX, candidate.rect.maxX) - max(existing.rect.minX, candidate.rect.minX)
                let minWidth = min(existing.rect.width, candidate.rect.width)
                if abs(existing.rect.minY - candidate.rect.minY) <= 10, minWidth > 0, overlapX >= minWidth * 0.5 {
                    let candidateArea = candidate.rawRect.width * candidate.rawRect.height
                    let existingArea = existing.rawRect.width * existing.rawRect.height
                    if candidate.kind == existing.kind && candidateArea < existingArea {
                        kept[i] = candidate
                    }
                    duplicate = true
                    break
                }
                let insideHorizontally = candidate.rawRect.minX >= existing.rawRect.minX - 16
                    && candidate.rawRect.maxX <= existing.rawRect.maxX + 16
                let insideVertically = candidate.rawRect.minY > existing.rawRect.minY
                    && candidate.rawRect.maxY <= existing.rawRect.maxY + 8
                if insideHorizontally, insideVertically {
                    if existing.kind == .composer && existing.rawRect.height <= 280 {
                        duplicate = true
                        break
                    }
                    if candidate.kind != .input && (candidate.rawRect.minY - existing.rawRect.minY < 60 || candidate.rawRect.height <= 40) {
                        duplicate = true
                        break
                    }
                }
            }
            if !duplicate {
                kept.append(candidate)
                if kept.count >= maxSurfacesPerWindow { break }
            }
        }

        let clippedKept = clipOverlappingSurfaces(kept)
        let surfaces = clippedKept
            .sorted { a, b in
                a.rect.minY == b.rect.minY ? a.rect.minX < b.rect.minX : a.rect.minY < b.rect.minY
            }
            .map { $0.rect }
        let occluders = extractOccluders(windowFrame: box, nodes: nodes, surfaces: clippedKept)
        return WindowLayout(surfaces: surfaces, occluders: occluders)
    }

    private static func clippedRelative(_ frame: CGRect, clip: CGRect, in box: CGRect) -> CGRect {
        let visible = frame.intersection(clip.intersection(box))
        let r = visible.isNull ? frame : visible
        return r.offsetBy(dx: -box.minX, dy: -box.minY)
    }

    /// Trims any surface whose top snow ledge extends behind an overlapping front card, popover, or floating panel.
    private static func clipOverlappingSurfaces(_ kept: [Candidate]) -> [Candidate] {
        guard kept.count > 1 else { return kept }
        func isInFront(_ a: Candidate, of b: Candidate) -> Bool {
            if a.isFloating != b.isFloating { return a.isFloating }
            let bInsideA = b.rawRect.minX >= a.rawRect.minX - 8 && b.rawRect.maxX <= a.rawRect.maxX + 8
                && b.rawRect.minY >= a.rawRect.minY - 8 && b.rawRect.maxY <= a.rawRect.maxY + 8
            if bInsideA { return false }
            if a.rawRect.minY + 4 < b.rawRect.minY && b.rawRect.minY < a.rawRect.maxY - 2 {
                return true
            }
            return a.domIndex > b.domIndex
        }

        var result: [Candidate] = []
        for (bi, b) in kept.enumerated() {
            var spans: [(CGFloat, CGFloat)] = [(b.rect.minX, b.rect.maxX)]
            for (ai, a) in kept.enumerated() where ai != bi {
                guard b.rect.minY >= a.rawRect.minY - 2 && b.rect.minY <= a.rawRect.maxY + 2 else { continue }
                let overlapsX = min(b.rect.maxX, a.rawRect.maxX) > max(b.rect.minX, a.rawRect.minX) + 2
                guard overlapsX, isInFront(a, of: b) else { continue }
                let cutMin = a.rawRect.minX - 2
                let cutMax = a.rawRect.maxX + 2
                var next: [(CGFloat, CGFloat)] = []
                for (lo, hi) in spans {
                    if hi <= cutMin || lo >= cutMax {
                        next.append((lo, hi))
                    } else {
                        if lo < cutMin { next.append((lo, cutMin)) }
                        if hi > cutMax { next.append((cutMax, hi)) }
                    }
                }
                spans = next
                if spans.isEmpty { break }
            }
            guard let best = spans.max(by: { ($0.1 - $0.0) < ($1.1 - $1.0) }), best.1 - best.0 >= 48 else { continue }
            let trimmed = CGRect(x: best.0, y: b.rect.minY, width: best.1 - best.0, height: b.rect.height)
            result.append(Candidate(rect: trimmed, rawRect: b.rawRect, kind: b.kind, domIndex: b.domIndex, isFloating: b.isFloating))
        }
        return result
    }

    /// Builds solid content occluders from kept card/panel bodies and merged vertical text blocks so snowflakes never
    /// fly across readable text or through floating panels.
    private static func extractOccluders(windowFrame box: CGRect, nodes: [NodeSnapshot], surfaces: [Candidate]) -> [ExtractedOccluder] {
        let windowBounds = CGRect(origin: .zero, size: box.size)
        var surfaceOccluders: [ExtractedOccluder] = []
        for s in surfaces {
            let r = s.rawRect.intersection(windowBounds)
            guard !r.isNull, r.width >= 56, r.height >= 20 else { continue }
            // Keep the top ~2pt clear so snow settling directly on this surface's top edge stays visible.
            let body = CGRect(x: r.minX, y: r.minY + 2, width: r.width, height: max(1, r.height - 2))
            surfaceOccluders.append(ExtractedOccluder(rect: body, isSurfaceBody: true))
        }

        var textLeaves: [CGRect] = []
        for node in nodes {
            let isTextLeaf = textLeafRoles.contains(node.role)
            let isLabeledRow = node.role == "AXButton" && node.frame.width >= 56 && node.frame.height >= 16 && node.frame.height <= 44
            guard isTextLeaf || isLabeledRow else { continue }
            let clip = node.clip.intersection(box)
            guard !clip.isNull else { continue }
            let visible = node.frame.intersection(clip)
            guard !visible.isNull, visible.width >= 12, visible.height >= 8,
                  visible.width <= box.width * 0.94, visible.height <= box.height * 0.90 else { continue }
            let rel = visible.offsetBy(dx: -box.minX, dy: -box.minY)
            guard rel.minY >= 24 || !isLabeledRow else { continue }
            let padded = rel.insetBy(dx: -6, dy: -4).intersection(windowBounds)
            if !padded.isNull { textLeaves.append(padded) }
        }

        let mergedText = mergeTextBlocks(textLeaves, windowSize: box.size)
        var out = surfaceOccluders
        for rect in mergedText {
            let covered = surfaceOccluders.contains { $0.rect.insetBy(dx: -4, dy: -4).contains(rect) }
            if !covered {
                out.append(ExtractedOccluder(rect: rect, isSurfaceBody: false))
            }
        }
        if out.count > maxOccludersPerWindow {
            let surfacesPart = out.filter(\.isSurfaceBody)
            let textPart = out.filter { !$0.isSurfaceBody }
                .sorted { ($0.rect.width * $0.rect.height) > ($1.rect.width * $1.rect.height) }
            let room = max(0, maxOccludersPerWindow - surfacesPart.count)
            out = Array(surfacesPart.prefix(maxOccludersPerWindow)) + Array(textPart.prefix(room))
        }
        return out
    }

    /// Merges adjacent text leaves into cohesive horizontal lines and vertical reading columns while respecting column gutters.
    private static func mergeTextBlocks(_ leaves: [CGRect], windowSize: CGSize) -> [CGRect] {
        guard !leaves.isEmpty else { return [] }
        let maxLineWidth = windowSize.width * 0.80

        // Pass 1: merge fragments on the same horizontal line.
        let byLine = leaves.sorted { a, b in
            abs(a.minY - b.minY) <= 4 ? a.minX < b.minX : a.minY < b.minY
        }
        var lines: [CGRect] = []
        for r in byLine {
            if let idx = lines.lastIndex(where: { existing in
                let vOverlap = min(existing.maxY, r.maxY) - max(existing.minY, r.minY)
                let hGap = max(r.minX - existing.maxX, existing.minX - r.maxX)
                let union = existing.union(r)
                return vOverlap >= -3 && hGap <= 22 && union.width <= maxLineWidth && union.height <= max(existing.height, r.height) + 12
            }) {
                lines[idx] = lines[idx].union(r)
            } else {
                lines.append(r)
            }
        }

        // Pass 2: merge vertically stacked lines and paragraphs within the same column into vertical text blocks.
        // Track filled area alongside bounding rect so merging never swallows wide empty column gutters.
        var blocks = lines
            .sorted { a, b in a.minY == b.minY ? a.minX < b.minX : a.minY < b.minY }
            .map { (rect: $0, filled: $0.width * $0.height) }
        var changed = true
        var passes = 0
        while changed && passes < 6 {
            changed = false
            passes += 1
            var next: [(rect: CGRect, filled: CGFloat)] = []
            for item in blocks {
                let r = item.rect
                if let idx = next.indices.reversed().first(where: { i in
                    let e = next[i].rect
                    let vGap = max(r.minY - e.maxY, e.minY - r.maxY)
                    guard vGap <= 34 else { return false }
                    let hOverlap = min(e.maxX, r.maxX) - max(e.minX, r.minX)
                    let maxW = max(e.width, r.width)
                    let minW = min(e.width, r.width)
                    let alignedLeft = abs(e.minX - r.minX) <= 32 && hOverlap >= minW * 0.35
                    let strongOverlap = hOverlap >= maxW * 0.55
                    let sameColumn = alignedLeft || strongOverlap
                    guard sameColumn else { return false }
                    let union = e.union(r)
                    guard union.width <= min(windowSize.width * 0.82, max(e.width, r.width) + 120) else { return false }
                    let combinedFilled = next[i].filled + item.filled
                    let unionArea = union.width * union.height
                    return unionArea <= combinedFilled * 1.65
                }) {
                    let prev = next[idx]
                    let inter = prev.rect.intersection(r)
                    let overlapArea = inter.isNull ? 0 : inter.width * inter.height
                    next[idx] = (prev.rect.union(r), prev.filled + item.filled - overlapArea)
                    changed = true
                } else {
                    next.append(item)
                }
            }
            blocks = next
        }
        return blocks.map(\.rect)
    }

    /// Promotes a text field inside a composer container (web/Electron) or a native rounded capsule (such as Safari's URL pill)
    /// up to its enclosing visual container so snow settles on the outer top edge rather than inside above the text.
    private static func enclosingInputContainer(of index: Int, nodes: [NodeSnapshot], styles: [SurfaceStyle], windowFrame box: CGRect) -> (index: Int, cornerRadius: CGFloat, isNativeCapsule: Bool)? {
        let input = nodes[index]
        let isNativeInput = input.classes.isEmpty
        var current = input.parent
        for depth in 0..<6 {
            guard let idx = current else { return nil }
            let ancestor = nodes[idx]
            if stopAncestorRoles.contains(ancestor.role) { return nil }
            let r = ancestor.frame
            let compact = r.height <= 280 && r.height <= box.height * 0.45 && r.width <= input.frame.width + 220
            let wraps = r.minY <= input.frame.minY + 2 && r.maxY >= input.frame.maxY - 2
            if compact, wraps, (styles[idx].isVisualSurface || nativeBoxRoles.contains(ancestor.role)) {
                return (idx, max(styles[idx].cornerRadius, 14), false)
            }
            if isNativeInput, depth < 4, ancestor.role == "AXGroup", ancestor.classes.isEmpty {
                let capsuleHeight = r.height >= input.frame.height + 4 && r.height <= 54
                let capsuleWidth = r.width >= input.frame.width && r.width <= box.width * 0.78
                let wrapsHorizontally = r.minX <= input.frame.minX + 2 && r.maxX >= input.frame.maxX - 2
                let wrapsVertically = r.minY < input.frame.minY - 1 && r.maxY >= input.frame.maxY - 1
                    && abs(r.midY - input.frame.midY) <= 10
                if capsuleHeight, capsuleWidth, wrapsHorizontally, wrapsVertically {
                    return (idx, min(r.height * 0.5, 16), true)
                }
            }
            current = ancestor.parent
        }
        return nil
    }

    private static func fitSurface(_ r: CGRect, clip rawClip: CGRect, in box: CGRect, kind: CandidateKind, cornerRadius: CGFloat) -> CGRect? {
        let clip = rawClip.intersection(box)
        guard !clip.isNull, clip.width >= 60, clip.height >= 20 else { return nil }
        let minWidth: CGFloat = kind == .input ? 60 : 72
        let minHeight: CGFloat = kind == .input ? 14 : 26
        guard r.width >= minWidth, r.height >= minHeight else { return nil }
        if kind == .surface {
            guard r.height <= box.height * 0.85 else { return nil }
            guard !(r.width > box.width * 0.90 && r.height > box.height * 0.72) else { return nil }
        }
        let minTop = max(box.minY + (kind == .input ? 4 : 32), clip.minY + 2)
        let maxTop = clip.maxY - 14
        guard r.minY >= minTop, r.minY <= maxTop else { return nil }
        let visibleHeight = min(r.maxY, clip.maxY) - r.minY
        guard visibleHeight >= minHeight else { return nil }
        let visibleMinX = max(r.minX, clip.minX)
        let visibleMaxX = min(r.maxX, clip.maxX)
        let visibleWidth = visibleMaxX - visibleMinX
        guard visibleWidth >= minWidth else { return nil }
        let extraInset = max(0, min(cornerRadius - 4, visibleWidth * 0.18))
        let left = visibleMinX + (r.minX >= clip.minX ? extraInset : 0)
        let right = visibleMaxX - (r.maxX <= clip.maxX ? extraInset : 0)
        guard right - left >= 48 else { return nil }
        return CGRect(x: left - box.minX, y: r.minY - box.minY, width: right - left, height: visibleHeight)
    }

    private static func scan(_ pid: pid_t, mode: WakeMode) -> [Int: (size: CGSize, layout: WindowLayout)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Electron and Chromium apps build their web accessibility tree only on request and keep updating it while on,
        // so the flag is switched on just for the read and back off, unless something else had it on already.
        let wakeAttr: CFString?
        let wakeDelay: TimeInterval
        switch mode {
        case .standard: wakeAttr = nil; wakeDelay = 0
        case .electron: wakeAttr = manual; wakeDelay = 0.6
        case .chromium: wakeAttr = enhancedUI; wakeDelay = 0.35
        }
        var woke = false
        if let wakeAttr {
            var wasOn: CFTypeRef?
            let already = AXUIElementCopyAttributeValue(app, wakeAttr, &wasOn) == .success && (wasOn as? Bool) == true
            if !already {
                AXUIElementSetAttributeValue(app, wakeAttr, kCFBooleanTrue)
                woke = true
                Thread.sleep(forTimeInterval: wakeDelay)
            }
        }
        defer {
            if woke, let wakeAttr { AXUIElementSetAttributeValue(app, wakeAttr, kCFBooleanFalse) }
        }
        var windows: CFTypeRef?
        var ok = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success
        if woke && (!ok || (windows as? [AXUIElement] ?? []).isEmpty) {
            Thread.sleep(forTimeInterval: 0.25)
            ok = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success
        }
        guard ok, let list = windows as? [AXUIElement] else { return [:] }
        var out: [Int: (size: CGSize, layout: WindowLayout)] = [:]
        for window in list {
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &id) == .success, let box = read(window).frame else { continue }
            var snapshots: [NodeSnapshot] = []
            var pending: [(element: AXUIElement, parent: Int?, clip: CGRect, inScroll: Bool)] = [(window, nil, box, false)]
            var next = 0
            while next < pending.count, next < maxVisitedNodes {
                let entry = pending[next]
                next += 1
                let node = read(entry.element)
                guard let role = node.role else { continue }
                let isScroll = role == "AXScrollArea"
                    || node.classes.contains(where: isScrollContainerClass)
                if entry.inScroll, let r = node.frame, r.width > 0, r.height > 0,
                   !node.classes.contains("overflow-visible"), !node.classes.contains("fixed"), !node.classes.contains("contents"),
                   !r.intersects(entry.clip.insetBy(dx: -40, dy: -40)) {
                    continue
                }
                var snapshotIndex = entry.parent
                if let r = node.frame, r.width > 0, r.height > 0 {
                    snapshotIndex = snapshots.count
                    snapshots.append(NodeSnapshot(role: role, subrole: node.subrole ?? "", frame: r, clip: entry.clip,
                                                  classes: node.classes, parent: entry.parent, childCount: node.children.count))
                }
                if inputRoles.contains(role) || leaves.contains(role) { continue }
                var childClip = entry.clip
                if let r = node.frame, r.width >= 40, r.height >= 40,
                   !node.classes.contains("contents"), !node.classes.contains("overflow-visible"),
                   (isScroll || role == "AXWebArea" || node.classes.contains("overflow-hidden") || node.classes.contains("overflow-clip")) {
                    let tightened = entry.clip.intersection(r)
                    if !tightened.isNull { childClip = tightened }
                }
                let childInScroll = entry.inScroll || isScroll
                for child in node.children {
                    pending.append((child, snapshotIndex, childClip, childInScroll))
                }
            }
            out[Int(id)] = (box.size, extractLayout(windowFrame: box, nodes: snapshots))
        }
        return out
    }

    private static func isScrollContainerClass(_ token: String) -> Bool {
        token.contains("overflow-y-auto") || token.contains("overflow-y-scroll")
            || token.contains("overflow-auto") || token.contains("overflow-scroll")
            || token.contains("scroll-container") || token.hasPrefix("scrollContainer")
    }

    private static func read(_ element: AXUIElement) -> (role: String?, subrole: String?, frame: CGRect?, children: [AXUIElement], classes: [String]) {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute, domClassList as String] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
              let v = values as? [AnyObject], v.count == 6 else { return (nil, nil, nil, [], []) }
        var origin = CGPoint.zero
        var size = CGSize.zero
        var frame: CGRect?
        if CFGetTypeID(v[2]) == AXValueGetTypeID(), CFGetTypeID(v[3]) == AXValueGetTypeID(),
           AXValueGetValue(v[2] as! AXValue, .cgPoint, &origin), AXValueGetValue(v[3] as! AXValue, .cgSize, &size) {
            frame = CGRect(origin: origin, size: size)
        }
        return (v[0] as? String, v[1] as? String, frame, v[4] as? [AXUIElement] ?? [], v[5] as? [String] ?? [])
    }
}
