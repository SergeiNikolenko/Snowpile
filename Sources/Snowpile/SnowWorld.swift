import CoreGraphics
import QuartzCore

/// One point sprite as the shader reads it: a falling flake or a lump of shed snow.
struct Sprite {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var size: Float
    var alpha: Float
    var soft: Float
    var lump: Float
}

/// The whole snowfall in global Cocoa coordinates (points, origin at the bottom left of the main screen).
/// Drifts are height maps: one column every `columnWidth` points along the top edge of a window, the Dock or a screen's floor.
final class SnowWorld {
    enum Kind { case window, dock, ground }

    final class Surface {
        let key: Int
        let kind: Kind
        var left: Float
        var top: Float
        var columns: [Float]
        let cap: Float
        /// Position in the window stack, 0 being the frontmost window.
        var z: Int
        var spillLeft: Float = 0
        var spillRight: Float = 0
        var snowmen: [Snowman] = []

        init(key: Int, kind: Kind, left: Float, top: Float, count: Int, cap: Float, z: Int) {
            self.key = key
            self.kind = kind
            self.left = left
            self.top = top
            self.columns = Array(repeating: 0, count: count)
            self.cap = cap
            self.z = z
        }

        var width: Float { Float(columns.count) * SnowWorld.columnWidth }
        var right: Float { left + width }
        var isBare: Bool { snowmen.isEmpty && !columns.contains { $0 > 0.05 } }

        func height(at x: Float) -> Float {
            let i = Int(((x - left) / SnowWorld.columnWidth).rounded(.down))
            return columns.indices.contains(i) ? columns[i] : 0
        }
    }

    struct Flake {
        var x, y, vx, vy: Float
        var fall, drift, sway, swayRate, phase: Float
        var size, alpha, soft: Float
        /// Extra velocity from the pointer, fading away.
        var push: SIMD2<Float> = .zero
        /// Far, faint flakes fall past everything; only nearer ones settle.
        var lands: Bool
        var screen: Int
    }

    struct Lump {
        var x, y, vx, vy, size, seed: Float
    }

    static let columnWidth: Float = 2
    private static let repose: Float = 0.75
    private static let edgeRepose: Float = 2.4
    private static let gravity: Float = 820
    private static let dockKey = -1
    private static let windowCap: Float = 18
    private static let dockCap: Float = 10
    private static let groundCap: Float = 30
    private static let carrySpeed: Float = 600
    private static let cornerInset: Float = 10
    private static let pointerReach: Float = 80
    private static let broomReach: Float = 12

    let start = CACurrentMediaTime()
    var running = true
    /// Whether new flakes come down; settled snow stays either way.
    var falling = true
    var intensity: Float = 1
    var windStrength: Float = 1
    /// Steady wind in points per second, positive towards the right.
    var windBase: Float = 0
    /// When the wind is made up rather than taken from the weather, it now and then turns around.
    var windWanders = true
    /// How fast settled snow melts away while snowing is on, in points per second.
    var thaw: Float = 0
    /// How readily a strong wind picks settled snow back up (drifting and blowing snow), 0 to 1.
    var lift: Float = 0
    var flakeScale: Float = 1
    var settles: Set<Kind> = [.window, .dock, .ground]
    var brushes = true

    private(set) var surfaces: [Surface] = []
    private var screens: [CGRect] = []
    private var flakes: [Flake] = []
    private(set) var lumps: [Lump] = []
    private var byKey: [Int: Surface] = [:]
    /// Drifts of windows that left the screen (hidden, minimised, on another Space), kept until they come back.
    private var stashed: [Int: (surface: Surface, frame: CGRect, since: CFTimeInterval)] = [:]
    private var frames: [Int: CGRect] = [:]
    private var fronts: [CGRect] = []
    private var dock: CGRect?
    private var wind: Float = 0
    private var windTarget: Float = 0
    private var windClock: Float = 0
    private var windSide: Float = 1
    private var spawnDebt: [Float] = []
    private var liftDebt: Float = 0
    private var lastStep: CFTimeInterval = 0
    private var lastPoll: CFTimeInterval = 0
    /// The Space each screen shows, and the floor snow of Spaces not on screen right now.
    private var spaces: [Int] = []
    private var floors: [String: (columns: [Float], snowmen: [Snowman])] = [:]
    private var roll: Roll?
    private var pointer: SIMD2<Float>?
    private var pointerVelocity: SIMD2<Float> = .zero

    var isIdle: Bool { !(running && falling) && flakes.isEmpty && lumps.isEmpty && surfaces.allSatisfy(\.isBare) }

    /// Each Space keeps its own snow at the bottom of the screen.
    func setSpaces(_ ids: [Int]) {
        defer { spaces = ids }
        guard ids.count == spaces.count else { return }
        for (i, (old, new)) in zip(spaces, ids).enumerated() where old != new {
            guard let floor = byKey[-1000 - i] else { continue }
            floors["\(i):\(old)"] = floor.isBare ? nil : (floor.columns, floor.snowmen)
            let kept = floors.removeValue(forKey: "\(i):\(new)")
            floor.columns = kept?.columns ?? Array(repeating: 0, count: floor.columns.count)
            floor.snowmen = kept?.snowmen ?? []
        }
    }

    func setScreens(_ frames: [CGRect]) {
        screens = frames
        spaces = []
        floors = [:]
        spawnDebt = Array(repeating: 0, count: frames.count)
        flakes.removeAll { $0.screen >= frames.count }
        for s in surfaces where s.kind == .ground { byKey[s.key] = nil }
        for (i, f) in frames.enumerated() {
            byKey[-1000 - i] = Surface(key: -1000 - i, kind: .ground, left: Float(f.minX), top: Float(f.minY),
                                       count: Int(Float(f.width) / Self.columnWidth), cap: Self.groundCap, z: 0)
        }
        surfaces = Array(byKey.values)
    }

    // MARK: Time

    /// `rolling` is true while the snowman key (Option) is held.
    func step(now: CFTimeInterval, pointer location: CGPoint? = nil, rolling: Bool = false) {
        guard lastStep > 0 else { lastStep = now; return }
        guard now - lastStep > 0.0005 else { return }
        let dt = Float(min(now - lastStep, 0.05))
        lastStep = now
        trackPointer(location, dt)
        rollSnow(rolling: rolling, dt)
        updateWind(dt)
        if running && falling { spawn(dt) }
        if running { liftSnow(dt) }
        advanceFlakes(dt)
        advanceLumps(dt)
        sweep()
        melt(dt)
    }

    private func trackPointer(_ location: CGPoint?, _ dt: Float) {
        guard let location else { pointer = nil; return }
        let p = SIMD2(Float(location.x), Float(location.y))
        let measured = pointer.map { (p - $0) / dt } ?? .zero
        pointerVelocity += (measured - pointerVelocity) * min(dt * 20, 1)
        pointer = p
    }

    /// A moving pointer brushes through a drift and knocks the snow above its tip loose.
    private func sweep() {
        guard brushes, roll == nil, let p = pointer else { return }
        let speed = (pointerVelocity * pointerVelocity).sum().squareRoot()
        guard speed > 60 else { return }
        if speed > 250 { knockSnowmen(at: p) }
        for s in surfaces where p.x >= s.left - Self.broomReach && p.x <= s.right + Self.broomReach {
            let h = s.height(at: min(max(p.x, s.left), s.right - 0.01))
            guard p.y >= s.top - 4, p.y <= s.top + h + 6, isExposed(s, x: p.x) else { continue }
            let keep = max(p.y - s.top - 1, 0)
            let lo = max(0, Int((p.x - Self.broomReach - s.left) / Self.columnWidth))
            let hi = min(s.columns.count - 1, Int((p.x + Self.broomReach - s.left) / Self.columnWidth))
            guard lo <= hi else { continue }
            var loose: Float = 0
            for j in lo...hi where s.columns[j] > keep {
                loose += (s.columns[j] - keep) * Self.columnWidth
                s.columns[j] = keep
            }
            while loose > 0.4 {
                let chunk = min(loose, .random(in: 1.5...5))
                loose -= chunk
                throwLump(x: p.x + .random(in: -Self.broomReach...Self.broomReach), y: s.top + keep + 2, area: chunk,
                          vx: pointerVelocity.x * 0.55 + .random(in: -25...25),
                          vy: abs(pointerVelocity.y) * 0.25 + .random(in: 40...130))
            }
        }
    }

    private func updateWind(_ dt: Float) {
        windClock -= dt
        if windClock <= 0 {
            if windWanders, Float.random(in: 0...1) < 0.12 { windSide = -windSide }
            windTarget = windBase * (windWanders ? windSide : 1) + .random(in: -1...1) * 22 * windStrength
            windClock = .random(in: 5...12) / max(windStrength, 1)
        }
        wind += (windTarget - wind) * min(dt * 0.4, 1)
    }

    private func spawn(_ dt: Float) {
        for (i, screen) in screens.enumerated() {
            spawnDebt[i] += 40 * intensity * Float(screen.width) / 1000 * dt
            while spawnDebt[i] >= 1 {
                spawnDebt[i] -= 1
                guard flakes.count < 5000 else { continue }
                let depth = pow(Float.random(in: 0...1), 1.6)
                // In a strong wind most snow arrives from the side it blows from, not only from the top.
                let sideways = Float.random(in: 0...1) < min(abs(wind) / 150, 0.7)
                let x = sideways ? (wind > 0 ? Float(screen.minX) - 10 : Float(screen.maxX) + 10)
                    : .random(in: Float(screen.minX) - 80...Float(screen.maxX) + 80)
                let y = sideways ? .random(in: Float(screen.minY)...Float(screen.maxY)) : Float(screen.maxY) + .random(in: 4...24)
                flakes.append(Flake(
                    x: x, y: y, vx: sideways ? wind : 0, vy: 0,
                    fall: 22 + 58 * depth, drift: 0.6 + 0.8 * depth,
                    sway: .random(in: 6...18), swayRate: .random(in: 0.6...1.8), phase: .random(in: 0...(2 * .pi)),
                    size: (1.2 + 3.4 * depth) * flakeScale, alpha: 0.35 + 0.6 * depth, soft: 1 - 0.6 * depth,
                    lands: depth > 0.3, screen: i))
            }
        }
    }

    /// A wind well above a breeze lifts loose snow off the drifts and carries it along low over the surface.
    private func liftSnow(_ dt: Float) {
        let strength = lift * max(abs(wind) - 40, 0) / 100
        guard strength > 0 else { return }
        let snowy = surfaces.filter { settles.contains($0.kind) && !$0.isBare }
        guard !snowy.isEmpty else { return }
        liftDebt += strength * 60 * Float(snowy.count) * dt
        while liftDebt >= 1 {
            liftDebt -= 1
            guard flakes.count < 5000, let s = snowy.randomElement() else { continue }
            let j = Int.random(in: s.columns.indices)
            guard s.columns[j] > 0.3 else { continue }
            let x = s.left + (Float(j) + 0.5) * Self.columnWidth
            guard isExposed(s, x: x),
                  let screen = screens.firstIndex(where: { $0.minX <= CGFloat(x) && CGFloat(x) < $0.maxX }) else { continue }
            let taken = min(Float(0.15), s.columns[j])
            s.columns[j] -= taken
            let size = Float.random(in: 1...2.2) * flakeScale
            flakes.append(Flake(
                x: x, y: s.top + s.columns[j] + 0.5, vx: wind * 0.5, vy: 0,
                fall: .random(in: 8...22), drift: .random(in: 1.3...1.9),
                sway: .random(in: 2...6), swayRate: .random(in: 1...2.5), phase: .random(in: 0...(2 * .pi)),
                size: size, alpha: .random(in: 0.5...0.85), soft: 0.6,
                push: SIMD2(0, .random(in: 15...55)), lands: true, screen: screen))
        }
    }

    private func advanceFlakes(_ dt: Float) {
        var kept: [Flake] = []
        kept.reserveCapacity(flakes.count)
        for var f in flakes {
            f.phase += f.swayRate * dt
            if brushes, let p = pointer {
                let away = SIMD2(f.x, f.y) - p
                let distance = (away * away).sum().squareRoot()
                if distance < Self.pointerReach, distance > 0.01 {
                    let near = 1 - distance / Self.pointerReach
                    f.push += (away / distance * 700 * near * near + pointerVelocity * 2.5 * near) * dt
                }
            }
            f.push *= exp(-2.5 * dt)
            let flutter = f.sway * sin(f.phase) * (0.75 + 0.25 * sin(f.phase * 0.37 + f.size))
            f.vx += (wind * f.drift + flutter - f.vx) * min(dt * 3, 1)
            f.vx += f.push.x * dt * 4
            f.vy = -f.fall + f.push.y
            let nx = f.x + f.vx * dt, ny = f.y + f.vy * dt
            if f.lands, let s = landing(x: nx, from: f.y, to: ny) {
                deposit(on: s, x: nx, amount: 0.3 * f.size / 2.5 * (0.3 + 1.4 * heap(s, x: nx)))
                continue
            }
            f.x = nx
            f.y = ny
            let bounds = screens[f.screen]
            if ny < Float(bounds.minY) - 8 || nx < Float(bounds.minX) - 160 || nx > Float(bounds.maxX) + 160 { continue }
            kept.append(f)
        }
        flakes = kept
    }

    private func advanceLumps(_ dt: Float) {
        let floor = Float(screens.map(\.minY).min() ?? 0) - 20
        var kept: [Lump] = []
        for var l in lumps {
            l.vy -= Self.gravity * dt
            l.vx *= max(0, 1 - 0.8 * dt)
            let nx = l.x + l.vx * dt, ny = l.y + l.vy * dt
            if let s = landing(x: nx, from: l.y, to: ny) {
                deposit(on: s, x: nx, amount: l.size * l.size / (1.32 * Self.columnWidth))
                continue
            }
            l.x = nx
            l.y = ny
            if ny > floor { kept.append(l) }
        }
        lumps = kept
    }

    private func melt(_ dt: Float) {
        for s in surfaces {
            let rate = !running || !settles.contains(s.kind) ? 5 : thaw
            guard rate > 0 else { continue }
            for j in s.columns.indices where s.columns[j] > 0 {
                s.columns[j] = max(0, s.columns[j] - rate * dt)
            }
        }
        let shrink = (!running ? 3 : thaw * 0.5) * dt
        guard shrink > 0 else { return }
        for s in surfaces where !s.snowmen.isEmpty {
            for man in s.snowmen { man.balls = man.balls.map { $0 - shrink }.filter { $0 > 2 } }
            s.snowmen.removeAll { $0.balls.isEmpty }
        }
    }

    // MARK: Settling

    /// The highest exposed snow surface a piece crosses while moving from `y0` down to `y1` at `x`.
    private func landing(x: Float, from y0: Float, to y1: Float) -> Surface? {
        var best: Surface?
        var bestY = -Float.infinity
        for s in surfaces where x >= s.left && x < s.right && settles.contains(s.kind) {
            let sy = s.top + s.height(at: x)
            if y0 >= sy, y1 < sy, sy > bestY, isExposed(s, x: x) {
                best = s
                bestY = sy
            }
        }
        return best
    }

    private func isExposed(_ s: Surface, x: Float) -> Bool {
        switch s.kind {
        case .dock:
            return true
        case .ground:
            return dock?.contains(CGPoint(x: CGFloat(x), y: CGFloat(s.top) + 1)) != true
        case .window:
            let edge = CGPoint(x: CGFloat(x), y: CGFloat(s.top) - 0.5)
            if dock?.contains(edge) == true { return false }
            return !fronts.prefix(s.z).contains { $0.contains(edge) }
        }
    }

    private func deposit(on s: Surface, x: Float, amount: Float) {
        let i = Int(((x - s.left) / Self.columnWidth).rounded(.down))
        guard s.columns.indices.contains(i) else { return }
        s.columns[i] += amount * 0.5
        s.columns[i > 0 ? i - 1 : i] += amount * 0.25
        s.columns[i + 1 < s.columns.count ? i + 1 : i] += amount * 0.25
        settle(s, around: i)
    }

    /// Slides snow down any slope steeper than the angle of repose; over a window's open ends it spills off as lumps.
    private func settle(_ s: Surface, around i: Int) {
        let n = s.columns.count
        let lo = max(0, i - 12), hi = min(n - 1, i + 12)
        for _ in 0..<4 {
            for j in lo..<hi {
                let d = s.columns[j] - s.columns[j + 1]
                let excess = abs(d) - Self.repose
                guard excess > 0 else { continue }
                let m = excess * 0.5
                if d > 0 {
                    s.columns[j] -= m
                    s.columns[j + 1] += m
                } else {
                    s.columns[j] += m
                    s.columns[j + 1] -= m
                }
            }
            guard s.kind != .ground else { continue }
            if lo == 0, s.columns[0] > Self.edgeRepose {
                s.spillLeft += s.columns[0] - Self.edgeRepose
                s.columns[0] = Self.edgeRepose
            }
            if hi == n - 1, s.columns[n - 1] > Self.edgeRepose {
                s.spillRight += s.columns[n - 1] - Self.edgeRepose
                s.columns[n - 1] = Self.edgeRepose
            }
        }
        for j in lo...hi {
            let x = s.left + (Float(j) + 0.5) * Self.columnWidth
            s.columns[j] = min(s.columns[j], s.cap * (0.45 + 0.55 * heap(s, x: x)))
        }
        if s.spillLeft > 1.5 {
            throwLump(x: s.left - 1.5, y: s.top + 1, area: s.spillLeft * Self.columnWidth, vx: -.random(in: 6...24), vy: 0)
            s.spillLeft = 0
        }
        if s.spillRight > 1.5 {
            throwLump(x: s.right + 1.5, y: s.top + 1, area: s.spillRight * Self.columnWidth, vx: .random(in: 6...24), vy: 0)
            s.spillRight = 0
        }
    }

    /// 0...1 along a surface: where the wind tends to heap snow up. Fixed per surface so mounds grow in place.
    private func heap(_ s: Surface, x: Float) -> Float {
        let u = x - s.left
        let seed = Float(abs(s.key) % 997)
        return 0.5 + 0.3 * sin(u * 0.045 + seed) + 0.2 * sin(u * 0.013 + seed * 0.7)
    }

    private func throwLump(x: Float, y: Float, area: Float, vx: Float, vy: Float) {
        guard lumps.count < 2500 else { return }
        lumps.append(Lump(x: x, y: y, vx: vx, vy: vy, size: min(max(area.squareRoot() * 1.15, 1.3), 7), seed: .random(in: 0.01...1)))
    }

    /// Breaks the drift into lumps that fly off with the window's motion.
    private func shed(_ s: Surface, velocity v: SIMD2<Float>, share: Float = 1) {
        let n = s.columns.count
        var j = 0
        while j < n {
            let k = min(j + 3, n)
            var sum: Float = 0
            for c in j..<k {
                let loose = s.columns[c] * share
                sum += loose
                s.columns[c] -= loose
            }
            if sum * Self.columnWidth > 0.6 {
                // The window slides out from under its snow: the snow keeps only a little of its sideways motion and falls.
                throwLump(x: s.left + Float(j + k) * 0.5 * Self.columnWidth, y: s.top + sum / Float(k - j) * 0.5,
                          area: sum * Self.columnWidth,
                          vx: v.x * 0.3 + .random(in: -12...12), vy: .random(in: 0...12))
            }
            j = k
        }
        s.spillLeft = 0
        s.spillRight = 0
        for man in s.snowmen { crumble(man, on: s, velocity: v) }
        s.snowmen = []
    }

    func shakeOff() {
        for s in surfaces { shed(s, velocity: SIMD2(0, .random(in: 60...160))) }
    }

    // MARK: Windows

    /// `windows` runs front to back, as the window server lists them.
    func updateWindows(_ windows: [(key: Int, frame: CGRect)], dock newDock: CGRect?, now: CFTimeInterval) {
        let elapsed = Float(max(now - lastPoll, 0.02))
        lastPoll = now
        fronts = windows.map(\.frame)
        dock = newDock
        var live = Set<Int>()
        for (z, w) in windows.enumerated() {
            live.insert(w.key)
            place(key: w.key, kind: .window, frame: w.frame, cap: Self.windowCap, z: z, elapsed: elapsed)
        }
        if let d = newDock {
            live.insert(Self.dockKey)
            place(key: Self.dockKey, kind: .dock, frame: d, cap: Self.dockCap, z: -1, elapsed: elapsed)
        }
        for s in surfaces where s.kind != .ground && !live.contains(s.key) {
            if let frame = frames[s.key], !s.isBare { stashed[s.key] = (s, frame, now) }
            byKey[s.key] = nil
            frames[s.key] = nil
        }
        stashed = stashed.filter { now - $0.value.since < 1800 }
        surfaces = Array(byKey.values)
    }

    private func place(key: Int, kind: Kind, frame: CGRect, cap: Float, z: Int, elapsed: Float) {
        // Window corners are rounded, so snow only lies along the straight part of the top edge.
        let inset: Float = kind == .window ? Self.cornerInset : 0
        let left = Float(frame.minX) + inset, top = Float(frame.maxY)
        let count = max(1, Int((Float(frame.width) - 2 * inset) / Self.columnWidth))
        frames[key] = frame
        guard let s = byKey[key] else {
            // A window coming back where it was gets its snow back; anywhere else it quietly starts bare.
            if let old = stashed.removeValue(forKey: key), old.frame.equalTo(frame) {
                old.surface.z = z
                byKey[key] = old.surface
            } else {
                byKey[key] = Surface(key: key, kind: kind, left: left, top: top, count: count, cap: cap, z: z)
            }
            return
        }
        let velocity = SIMD2(left - s.left, top - s.top) / elapsed
        let speed = (velocity * velocity).sum().squareRoot()
        // A gentle move carries the snow along; a jerk or a quick drop shakes some of it loose, more the harder it is.
        if kind == .window, speed > Self.carrySpeed || -velocity.y > Self.carrySpeed * 0.6 {
            let jolt = max(speed - Self.carrySpeed, -velocity.y - Self.carrySpeed * 0.6)
            shed(s, velocity: velocity, share: min(0.35 + jolt / 900, 1))
        }
        s.left = left
        s.top = top
        if s.columns.count > count {
            s.columns.removeLast(s.columns.count - count)
        } else if s.columns.count < count {
            s.columns.append(contentsOf: repeatElement(0, count: count - s.columns.count))
        }
        s.z = z
    }

    // MARK: Drawing

    func sprites(screen index: Int, frame: CGRect) -> [Sprite] {
        var out: [Sprite] = []
        for f in flakes where f.screen == index {
            out.append(Sprite(position: SIMD2(f.x, f.y), velocity: SIMD2(f.vx, f.vy), size: f.size, alpha: f.alpha, soft: f.soft, lump: 0))
        }
        let box = frame.insetBy(dx: -10, dy: -10)
        for l in lumps where box.contains(CGPoint(x: CGFloat(l.x), y: CGFloat(l.y))) {
            out.append(Sprite(position: SIMD2(l.x, l.y), velocity: SIMD2(l.vx, l.vy), size: l.size, alpha: 0.96, soft: 0.25, lump: l.seed))
        }
        return out
    }

    /// Drifts that show on `frame`, each with the rectangles (minX, minY, maxX, maxY) in front of it that hide it.
    func drifts(in frame: CGRect) -> [(surface: Surface, occluders: [SIMD4<Float>])] {
        surfaces.compactMap { s in
            let box = CGRect(x: CGFloat(s.left) - 2, y: CGFloat(s.top) - 2, width: CGFloat(s.width) + 4, height: CGFloat(s.cap) + 4)
            guard box.intersects(frame), !s.isBare else { return nil }
            var rects: [CGRect] = []
            switch s.kind {
            case .dock: break
            case .ground: rects = dock.map { [$0] } ?? []
            case .window: rects = Array(fronts.prefix(s.z)) + (dock.map { [$0] } ?? [])
            }
            let occluders = rects.filter { $0.intersects(box) }
                .map { SIMD4(Float($0.minX), Float($0.minY), Float($0.maxX), Float($0.maxY)) }
            return (s, occluders)
        }
    }
}

// MARK: Snowmen

/// A stack of up to three snowballs standing on a surface, bottom ball first.
final class Snowman {
    /// Position along the surface, measured from its left end, so the snowman rides along with a window.
    var x: Float
    /// Height of the snow it stands on, above the surface's top edge.
    var ground: Float
    var balls: [Float]
    let facesRight = Bool.random()

    init(x: Float, ground: Float, balls: [Float]) {
        self.x = x
        self.ground = ground
        self.balls = balls
    }

    /// Centre height of each ball above the surface's top edge.
    var centres: [Float] {
        var out: [Float] = []
        for (i, r) in balls.enumerated() {
            out.append(i == 0 ? ground + r * 0.88 : out[i - 1] + balls[i - 1] * 0.78 + r * 0.78)
        }
        return out
    }
}

/// A snowball being rolled along a drift.
struct Roll {
    var key: Int
    var x: Float
    var area: Float
    var radius: Float { (area / .pi).squareRoot() }
}

/// One piece of a snowman as the shader reads it. `kind`: 0 snowball, 1 coal, 2 carrot, 3 twig.
struct Part {
    var position: SIMD2<Float>
    var size: Float
    var kind: Float
    var angle: Float
    var seed: Float
}

extension SnowWorld {
    private static let largestBall: Float = 30
    private static let smallestBall: Float = 4

    /// While the snowman key is held over a drift, a snowball follows the pointer along it and picks snow up.
    fileprivate func rollSnow(rolling: Bool, _ dt: Float) {
        guard rolling, running, let p = pointer else {
            if let done = roll { release(done) }
            roll = nil
            return
        }
        guard var current = roll, let s = byKey[current.key] else {
            roll = surfaces.first { s in
                guard p.x >= s.left, p.x < s.right else { return false }
                let h = s.height(at: p.x)
                return h > 1 && p.y >= s.top - 6 && p.y <= s.top + h + 30 && isExposed(s, x: p.x)
            }.map { Roll(key: $0.key, x: p.x, area: .pi * 4) }
            return
        }
        let r = current.radius
        guard p.y > s.top - 40, p.y < s.top + 2 * r + 80 else {
            release(current)
            roll = nil
            return
        }
        let target = min(max(p.x, s.left + r), s.right - r)
        let step = min(max(target - current.x, -400 * dt), 400 * dt)
        current.x += step
        if r < Self.largestBall, step != 0 {
            let reach = max(r * 0.7, 3)
            let lo = max(0, Int((current.x - reach - s.left) / Self.columnWidth))
            let hi = min(s.columns.count - 1, Int((current.x + reach - s.left) / Self.columnWidth))
            if lo <= hi {
                for j in lo...hi {
                    let taken = min(s.columns[j], abs(step) * 0.3)
                    s.columns[j] -= taken
                    current.area += taken * Self.columnWidth * 1.6
                }
            }
        }
        roll = current
    }

    /// A ball let go next to a snowman that still has room goes on top of it; otherwise it starts a new one.
    private func release(_ done: Roll) {
        guard let s = byKey[done.key] else { return }
        let r = done.radius
        guard r >= Self.smallestBall else {
            deposit(on: s, x: done.x, amount: done.area / Self.columnWidth)
            return
        }
        let local = done.x - s.left
        if let man = s.snowmen.first(where: { abs($0.x - local) < $0.balls[0] + r * 0.5 && $0.balls.count < 3 }) {
            man.balls.append(min(r, man.balls[man.balls.count - 1]))
        } else {
            s.snowmen.append(Snowman(x: local, ground: s.height(at: done.x), balls: [r]))
        }
    }

    /// Bursts a snowman into lumps that fly off with `velocity`.
    fileprivate func crumble(_ man: Snowman, on s: Surface, velocity v: SIMD2<Float>) {
        for (r, centre) in zip(man.balls, man.centres) {
            let pieces = min(Int(r * r / 10) + 2, 14)
            for _ in 0..<pieces {
                let angle = Float.random(in: 0...(2 * .pi))
                let off = SIMD2(cos(angle), sin(angle)) * (r * Float.random(in: 0...0.8))
                throwLump(x: s.left + man.x + off.x, y: s.top + centre + off.y, area: .pi * r * r / Float(pieces) * 0.6,
                          vx: v.x * 0.4 + off.x * 4, vy: max(v.y * 0.3, 0) + .random(in: 20...90))
            }
        }
    }

    /// A fast swipe of the pointer through a snowman knocks it over.
    fileprivate func knockSnowmen(at p: SIMD2<Float>) {
        for s in surfaces where !s.snowmen.isEmpty {
            s.snowmen.removeAll { man in
                let hit = zip(man.balls, man.centres).contains { r, c in
                    let d = p - SIMD2(s.left + man.x, s.top + c)
                    return (d * d).sum() < r * r
                }
                if hit { crumble(man, on: s, velocity: pointerVelocity) }
                return hit
            }
        }
    }

    /// Puts a ready snowman on the bottom of the main screen.
    func buildSnowman() {
        guard let floor = byKey[-1000] else { return }
        let x = Float.random(in: 0.2...0.8) * floor.width
        floor.snowmen.append(Snowman(x: x, ground: floor.height(at: floor.left + x), balls: [24, 16, 11]))
    }

    func parts(in frame: CGRect) -> [Part] {
        var out: [Part] = []
        let box = frame.insetBy(dx: -40, dy: -40)
        for s in surfaces where !s.snowmen.isEmpty {
            for man in s.snowmen {
                let x = s.left + man.x
                guard box.contains(CGPoint(x: CGFloat(x), y: CGFloat(s.top + man.ground))),
                      isExposed(s, x: x) else { continue }
                out += pieces(of: man, at: SIMD2(x, s.top))
            }
        }
        if let roll, let s = byKey[roll.key] {
            let r = roll.radius
            out.append(Part(position: SIMD2(roll.x, s.top + s.height(at: roll.x) + r * 0.88), size: 2 * r, kind: 0, angle: 0, seed: 0.5))
        }
        return out
    }

    private func pieces(of man: Snowman, at base: SIMD2<Float>) -> [Part] {
        let centres = man.centres
        var out = zip(man.balls, centres).enumerated().map { i, ball in
            Part(position: base + SIMD2(0, ball.1), size: 2 * ball.0, kind: 0, angle: 0, seed: Float(i) * 0.37 + 0.1)
        }
        guard man.balls.count >= 2, let r = man.balls.last, let c = centres.last else { return out }
        let side: Float = man.facesRight ? 1 : -1
        let head = base + SIMD2(0, c)
        for eye: Float in [-1, 1] {
            out.append(Part(position: head + SIMD2(r * (0.32 * eye + 0.12 * side), r * 0.25), size: r * 0.24, kind: 1, angle: 0, seed: 0))
        }
        out.append(Part(position: head + SIMD2(side * r * 0.55, -r * 0.05), size: r * 1.0, kind: 2,
                        angle: man.facesRight ? 0 : .pi, seed: 0))
        let body = man.balls.count - 2
        let br = man.balls[body], bc = base + SIMD2(0, centres[body])
        if man.balls.count == 3 {
            for k: Float in [-0.35, 0, 0.35] {
                out.append(Part(position: bc + SIMD2(side * br * 0.15, br * k), size: br * 0.16, kind: 1, angle: 0, seed: 0))
            }
        }
        for arm: Float in [-1, 1] {
            let start = bc + SIMD2(arm * br * 0.8, br * 0.25)
            for k in 0..<9 {
                let t = Float(k) / 8
                out.append(Part(position: start + SIMD2(arm * br * 0.9 * t, br * 0.55 * t * t + br * 0.25 * t),
                                size: max(br * 0.16, 2.4), kind: 3, angle: 0, seed: 0))
            }
            out.append(Part(position: start + SIMD2(arm * br * 0.7, br * 0.62), size: max(br * 0.13, 2), kind: 3, angle: 0, seed: 0))
        }
        return out
    }
}
