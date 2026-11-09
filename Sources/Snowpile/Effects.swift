import AppKit

/// Effects share window geometry and rendering, while each keeps its own motion and contact rules.
enum Effect: String, CaseIterable {
    case snow, rain, sakura, leaves, fireflies, starfall

    var title: String {
        switch self {
        case .snow: return "Snow"
        case .rain: return "Rain & Lightning"
        case .sakura: return "Sakura"
        case .leaves: return "Autumn Leaves"
        case .fireflies: return "Fireflies"
        case .starfall: return "Starfall"
        }
    }
}

struct EffectSprite {
    var position: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
    /// Shape, rotation, texture seed, animation phase.
    var parameters: SIMD4<Float>
}

final class EffectWorld {
    struct Particle {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var size: Float
        var angle: Float
        var spin: Float
        var phase: Float
        var age: Float = 0
        var life: Float
        var screen: Int
        var kind: Float
        var restingOn: Int?
        var color: SIMD4<Float>
    }

    struct Ledge {
        var key: Int
        var frame: CGRect
        var order: Int
        var wet: Float = 0
    }

    var effect: Effect = .snow {
        didSet {
            guard effect != oldValue else { return }
            particles.removeAll()
            ledges = ledges.map { var ledge = $0; ledge.wet = 0; return ledge }
            debts = Array(repeating: 0, count: screens.count)
            lightningIn = 8
            lastStep = 0
            previousPointer = nil
        }
    }
    var running = true {
        didSet {
            guard running != oldValue else { return }
            previousPointer = nil
            lastStep = 0
            if oldValue && !running {
                for i in particles.indices { particles[i].life = min(particles[i].life, particles[i].age + 1.2) }
            }
        }
    }
    var onWindows = true
    var onDock = true
    var onFloor = true
    var intensity: Float = 1
    var wind: Float = 0
    var reduceMotion = false
    var brushes = true
    private(set) var particles: [Particle] = []
    private(set) var ledges: [Ledge] = []
    private var screens: [CGRect] = []
    private var debts: [Float] = []
    private var lastStep: CFTimeInterval = 0
    private var previousPointer: SIMD2<Float>?
    private var lightningIn: Float = 8
    private var time: Float = 0

    var isAnimating: Bool { effect != .snow && (running || !particles.isEmpty || ledges.contains { $0.wet > 0.01 }) }
    var isIdle: Bool { !isAnimating }

    func setScreens(_ frames: [CGRect]) {
        guard screens != frames else { return }
        screens = frames
        debts = Array(repeating: 0, count: frames.count)
        particles.removeAll { $0.screen >= frames.count || !frames[$0.screen].insetBy(dx: -200, dy: -200).contains(CGPoint(x: CGFloat($0.position.x), y: CGFloat($0.position.y))) }
    }

    func updateWindows(_ windows: [(key: Int, frame: CGRect)], dock: CGRect?) {
        let old = Dictionary(uniqueKeysWithValues: ledges.map { ($0.key, $0) })
        ledges = windows.enumerated().map { Ledge(key: $0.element.key, frame: $0.element.frame, order: $0.offset) }
        if let dock { ledges.append(Ledge(key: Int.min, frame: dock, order: -1)) }
        for (index, frame) in screens.enumerated() {
            ledges.append(Ledge(key: Int.min + index + 1,
                                frame: CGRect(x: frame.minX, y: frame.minY - 1, width: frame.width, height: 1), order: Int.max))
        }
        let current = Dictionary(uniqueKeysWithValues: ledges.map { ($0.key, $0) })
        for i in ledges.indices { ledges[i].wet = old[ledges[i].key]?.wet ?? 0 }
        for i in particles.indices {
            guard let key = particles[i].restingOn else { continue }
            guard let previous = old[key], let next = current[key] else {
                particles[i].restingOn = nil
                particles[i].velocity = SIMD2(wind * 0.3, -40)
                continue
            }
            let delta = SIMD2(Float(next.frame.minX - previous.frame.minX), Float(next.frame.maxY - previous.frame.maxY))
            particles[i].position += delta
            let point = CGPoint(x: CGFloat(particles[i].position.x), y: CGFloat(particles[i].position.y))
            if let index = screens.firstIndex(where: { $0.contains(point) }) { particles[i].screen = index }
            let x = CGFloat(particles[i].position.x)
            if x < next.frame.minX || x > next.frame.maxX || simdLength(delta) > 45 {
                particles[i].restingOn = nil
                particles[i].velocity = SIMD2(delta.x * 4, 35)
            }
        }
    }

    func step(now: CFTimeInterval, pointer: CGPoint?) {
        guard effect != .snow else { return }
        defer { lastStep = now }
        guard lastStep > 0 else { return }
        let dt = Float(min(max(now - lastStep, 0), 0.05))
        guard dt > 0 else { return }
        time += dt
        let cursor = pointer.map { SIMD2(Float($0.x), Float($0.y)) }
        let cursorVelocity = cursor.flatMap { p in previousPointer.map { (p - $0) / dt } } ?? .zero
        previousPointer = cursor
        let amount = min(max(intensity, 0.1), 3)
        if running {
            for i in screens.indices {
                let rate: Float
                switch effect {
                case .rain: rate = 160
                case .sakura: rate = 10
                case .leaves: rate = 5
                case .fireflies: rate = 2.5
                case .starfall: rate = 0.8
                case .snow: rate = 0
                }
                debts[i] += dt * rate * amount * Float(screens[i].width / 1440)
                while debts[i] >= 1 && particles.count < 2200 {
                    debts[i] -= 1
                    particles.append(spawn(screen: i))
                }
                debts[i] = min(debts[i], 2)
            }
        }
        for i in ledges.indices { ledges[i].wet = max(0, ledges[i].wet - dt * 0.08) }
        var alive: [Particle] = []
        var splashes: [Particle] = []
        alive.reserveCapacity(particles.count)
        for var p in particles {
            p.age += dt
            guard p.age < p.life else { continue }
            if p.kind == 6 { alive.append(p); continue }
            if brushes, let cursor {
                let away = p.position - cursor
                let distance = simdLength(away)
                if distance > 1 && distance < 75 {
                    let near = 1 - distance / 75
                    if p.restingOn != nil, simdLength(cursorVelocity) > 25 {
                        p.restingOn = nil
                        p.velocity = cursorVelocity * 0.35 + SIMD2(0, 45)
                        if running { p.age = min(p.age, p.life - 2) }
                    } else if p.restingOn == nil {
                        let tangent = SIMD2(-away.y, away.x) / distance
                        p.velocity += (away / distance * 90 + tangent * 100 + cursorVelocity * 0.15) * near * dt
                    }
                }
            }
            if p.restingOn != nil { alive.append(p); continue }
            let before = p.position
            switch Int(p.kind) {
            case 0: // Rain remains stretched along its direction of travel.
                p.velocity.x += (wind * 1.8 - p.velocity.x) * min(2 * dt, 1)
                p.velocity.y -= 140 * dt
            case 1, 2:
                let target = SIMD2(wind * 0.7 + sin(time * 1.7 + p.phase) * 28, -24 - p.size * 1.2)
                p.velocity += (target - p.velocity) * min(dt * 0.8, 1)
                p.angle += p.spin * dt * (reduceMotion ? 0.25 : 1)
            case 3:
                let target = SIMD2(cos(time * 0.63 + p.phase) * 22 + wind * 0.12, sin(time * 0.81 + p.phase * 1.3) * 16)
                p.velocity += (target - p.velocity) * min(dt * 1.8, 1)
            case 4: break
            case 5: p.velocity.y -= 420 * dt
            default: break
            }
            p.position += p.velocity * dt * (reduceMotion && p.kind != 0 && p.kind != 5 ? 0.4 : 1)
            if p.kind <= 2, p.velocity.y < 0,
               let index = landing(at: p.position, from: before) {
                let roof = Float(ledges[index].frame.maxY)
                if p.kind == 0 {
                    ledges[index].wet = min(1, ledges[index].wet + 0.07)
                    for direction: Float in [-1, 1] {
                        splashes.append(Particle(position: SIMD2(p.position.x, roof + 1), velocity: SIMD2(direction * .random(in: 25...65), .random(in: 25...65)), size: 1.5,
                                                  angle: 0, spin: 0, phase: 0, life: 0.35, screen: p.screen, kind: 5, color: SIMD4(0.5, 0.72, 0.9, 0.65)))
                    }
                    continue
                }
                p.position.y = roof + p.size * 0.13
                p.velocity = .zero
                p.angle = .random(in: -0.25...0.25)
                p.restingOn = ledges[index].key
                if running { p.life = p.age + .random(in: 12...25) }
                let count = alive.lazy.filter { $0.restingOn == p.restingOn }.count
                if count >= 140 { continue }
            }
            let point = CGPoint(x: CGFloat(p.position.x), y: CGFloat(p.position.y))
            if let index = screens.firstIndex(where: { $0.contains(point) }) { p.screen = index }
            let bounds = screens[p.screen].insetBy(dx: -180, dy: -160)
            if p.kind == 3 {
                let screen = screens[p.screen]
                p.position.x = min(max(p.position.x, Float(screen.minX + 8)), Float(screen.maxX - 8))
                p.position.y = min(max(p.position.y, Float(screen.minY + 8)), Float(screen.maxY - 8))
            } else if !bounds.contains(CGPoint(x: CGFloat(p.position.x), y: CGFloat(p.position.y))) { continue }
            alive.append(p)
        }
        particles = Array((alive + splashes).prefix(2400))
        if running && effect == .rain && !reduceMotion {
            lightningIn -= dt
            if lightningIn <= 0, let screen = screens.indices.randomElement() {
                lightning(screen: screen)
                lightningIn = .random(in: 12...24)
            }
        }
    }

    private func spawn(screen index: Int) -> Particle {
        let screen = screens[index]
        var p = Particle(position: SIMD2(Float.random(in: Float(screen.minX)...Float(screen.maxX)), Float(screen.maxY) + 20),
                         velocity: .zero, size: 10, angle: .random(in: 0...(2 * .pi)), spin: .random(in: -2...2),
                         phase: .random(in: 0...30), life: 50, screen: index, kind: 0, color: SIMD4(1, 1, 1, 1))
        switch effect {
        case .rain:
            p.kind = 0; p.velocity = SIMD2(wind * 1.8, -.random(in: 650...950)); p.size = .random(in: 0.8...1.4)
            p.color = SIMD4(0.54, 0.72, 0.9, 0.48); p.life = 8
        case .sakura:
            p.kind = 1; p.velocity = SIMD2(wind * 0.7, -35); p.size = .random(in: 8...15)
            p.color = SIMD4(1, .random(in: 0.55...0.78), .random(in: 0.73...0.9), 0.9)
        case .leaves:
            p.kind = 2; p.velocity = SIMD2(wind * 0.7, -40); p.size = .random(in: 14...25)
            p.color = [SIMD4<Float>(0.83, 0.28, 0.08, 0.95), SIMD4(0.95, 0.61, 0.1, 0.95), SIMD4(0.65, 0.14, 0.08, 0.95)].randomElement()!
        case .fireflies:
            p.kind = 3; p.size = .random(in: 10...20); p.life = .random(in: 8...18)
            p.position.y = .random(in: Float(screen.minY)...Float(screen.maxY)); p.color = SIMD4(0.72, 1, 0.26, 1)
        case .starfall:
            p.kind = 4; p.size = .random(in: 45...95); p.life = .random(in: 1.1...2.5)
            p.velocity = SIMD2(-.random(in: 300...550), -.random(in: 220...400)); p.color = SIMD4(0.66, 0.82, 1, 0.9)
        case .snow: break
        }
        return p
    }

    private func lightning(screen index: Int) {
        let screen = screens[index]
        var point = SIMD2(Float.random(in: Float(screen.minX + screen.width * 0.1)...Float(screen.maxX - screen.width * 0.1)), Float(screen.maxY))
        for _ in 0..<8 {
            let next = point + SIMD2(Float.random(in: -35...35), -Float(screen.height) / 16)
            let delta = next - point
            particles.append(Particle(position: (point + next) * 0.5, velocity: .zero, size: simdLength(delta), angle: atan2(delta.y, delta.x), spin: 0,
                                      phase: 0, life: 0.3, screen: index, kind: 6, color: SIMD4(0.75, 0.86, 1, 0.65)))
            point = next
        }
    }

    func spaceChanged() {
        particles.removeAll()
        previousPointer = nil
        lastStep = 0
        for i in ledges.indices { ledges[i].wet = 0 }
        debts = Array(repeating: 0, count: screens.count)
    }

    private func landing(at end: SIMD2<Float>, from start: SIMD2<Float>) -> Int? {
        ledges.indices.filter { i in
            let ledge = ledges[i]
            let roof = Float(ledge.frame.maxY)
            let enabled = ledge.order == Int.max ? onFloor : ledge.key == Int.min ? onDock : onWindows
            return enabled && end.x >= Float(ledge.frame.minX + 4) && end.x <= Float(ledge.frame.maxX - 4)
                && start.y >= roof && end.y <= roof
                && !ledges.contains { other in
                    other.order < ledge.order && other.frame.contains(CGPoint(x: CGFloat(end.x), y: CGFloat(roof + 1)))
                }
        }.max { ledges[$0].frame.maxY < ledges[$1].frame.maxY }
    }

    func sprites(screen index: Int, frame: CGRect) -> [EffectSprite] {
        var result: [EffectSprite] = []
        for p in particles where p.screen == index {
            if let key = p.restingOn, let ledge = ledges.first(where: { $0.key == key }),
               ledges.contains(where: { $0.order < ledge.order && $0.frame.contains(CGPoint(x: CGFloat(p.position.x), y: CGFloat(p.position.y))) }) { continue }
            var color = p.color
            if p.kind != 6 { color.w *= min(p.age * 3, 1) * min((p.life - p.age) * 2, 1) }
            var size = SIMD2(p.size, p.size)
            var angle = p.angle
            switch Int(p.kind) {
            case 0:
                size = SIMD2(min(simdLength(p.velocity) * 0.025, 30), p.size)
                angle = atan2(p.velocity.y, p.velocity.x)
            case 1, 2:
                if p.restingOn == nil { size.y *= 0.35 + 0.65 * abs(cos(time * 2 + p.phase)) }
            case 3:
                color.w *= 0.25 + 0.75 * pow(0.5 + 0.5 * sin(time * 2.8 + p.phase), 2)
            case 4:
                size = SIMD2(p.size, 3); angle = atan2(p.velocity.y, p.velocity.x)
            case 5: size = SIMD2(3, 2)
            case 6: size = SIMD2(p.size + 2, 3); color.w *= (p.life - p.age) / p.life
            default: break
            }
            result.append(EffectSprite(position: p.position, size: size, color: color, parameters: SIMD4(p.kind, angle, p.phase, time)))
        }
        if effect == .rain {
            for ledge in ledges where ledge.wet > 0.01 && frame.intersects(ledge.frame) {
                let left = max(ledge.frame.minX, frame.minX)
                let right = min(ledge.frame.maxX, frame.maxX)
                guard right - left > 8 else { continue }
                // Small segments can be hidden independently by foreground windows.
                for x in stride(from: left + 4, to: right - 4, by: 12) {
                    let y = ledge.frame.maxY + 0.5
                    guard !ledges.contains(where: { $0.order < ledge.order && $0.frame.contains(CGPoint(x: x, y: y)) }) else { continue }
                    result.append(EffectSprite(position: SIMD2(Float(x + 5), Float(y)), size: SIMD2(12, 2), color: SIMD4(0.43, 0.66, 0.84, ledge.wet * 0.45), parameters: SIMD4(7, 0, 0, 0)))
                }
            }
        }
        return result
    }

    private func simdLength(_ vector: SIMD2<Float>) -> Float { (vector * vector).sum().squareRoot() }
}
