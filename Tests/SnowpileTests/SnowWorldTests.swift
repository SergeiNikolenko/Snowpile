import CoreGraphics
import XCTest
@testable import Snowpile

final class SnowWorldTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let window = CGRect(x: 100, y: 200, width: 900, height: 400)

    /// Lets snow fall on one window until it carries a visible drift.
    private func snowyWorld() -> (SnowWorld, Double) {
        let world = SnowWorld()
        world.intensity = 3
        world.setScreens([screen])
        var now = 1.0
        world.updateWindows([(7, window)], dock: nil, now: now)
        while now < 200 {
            now += 0.05
            world.step(now: now)
            world.updateWindows([(7, window)], dock: nil, now: now)
        }
        return (world, now)
    }

    private func drift(_ world: SnowWorld) -> [Float]? {
        world.surfaces.first { $0.key == 7 }?.columns
    }

    func testSwitchingSpacesKeepsSnowInPlace() throws {
        var (world, now) = snowyWorld()
        let before = try XCTUnwrap(drift(world))
        XCTAssertGreaterThan(before.reduce(0, +), 50)
        let lumps = world.lumps.count

        now += 0.1
        world.updateWindows([], dock: nil, now: now)
        XCTAssertNil(drift(world))
        XCTAssertEqual(world.lumps.count, lumps, "hiding a window must not throw its snow")

        now += 0.1
        world.updateWindows([(7, window)], dock: nil, now: now)
        XCTAssertEqual(drift(world), before)
    }

    func testSnowSettlesOnAFullScreenWindowAndOnFieldsInsideWindows() throws {
        let world = SnowWorld()
        world.intensity = 3
        world.setScreens([screen])
        let field = (key: 1 << 40 | 5, frame: CGRect(x: 300, y: 300, width: 400, height: 30), window: 7)
        var now = 1.0
        while now < 200 {
            now += 0.05
            world.updateWindows([(7, window), (8, screen)], elements: [field], dock: nil, now: now)
            world.step(now: now)
        }
        let full = try XCTUnwrap(world.surfaces.first { $0.key == 8 })
        XCTAssertLessThanOrEqual(full.top + full.cap, Float(screen.maxY))
        XCTAssertGreaterThan(full.columns.reduce(0, +), 50)
        let inside = try XCTUnwrap(world.surfaces.first { $0.key == field.key })
        XCTAssertGreaterThan(inside.columns.reduce(0, +), 20)
    }

    func testConnectingADisplayKeepsFloorSnow() throws {
        let world = SnowWorld()
        world.setScreens([screen])
        world.fillFloor()
        world.buildSnowman()
        let floor = try XCTUnwrap(world.surfaces.first { $0.key == -1000 })
        let before = floor.columns

        world.setScreens([screen])
        world.setScreens([screen, CGRect(x: -1024, y: 100, width: 1024, height: 665)])
        let after = try XCTUnwrap(world.surfaces.first { $0.key == -1000 })
        XCTAssertEqual(after.columns, before)
        XCTAssertEqual(after.snowmen.count, 1)
        XCTAssertNotNil(world.surfaces.first { $0.key == -1001 })
    }

    func testEachSpaceKeepsItsOwnFloorSnow() throws {
        let (world, _) = snowyWorld()
        world.setSpaces([1])
        let floor = try XCTUnwrap(world.surfaces.first { $0.kind == .ground })
        let first = floor.columns
        XCTAssertGreaterThan(first.reduce(0, +), 10)

        world.setSpaces([2])
        XCTAssertEqual(floor.columns.reduce(0, +), 0)
        world.setSpaces([1])
        XCTAssertEqual(floor.columns, first)
    }

    func testRolledBallsStackIntoASnowman() throws {
        var (world, now) = snowyWorld()
        func roll(from start: CGFloat, to end: CGFloat) {
            var x = start
            let stride: CGFloat = end > start ? 4 : -4
            while abs(end - x) >= 4 {
                now += 1.0 / 60
                x += stride
                world.step(now: now, pointer: CGPoint(x: x, y: 4), rolling: true)
            }
            now += 1.0 / 60
            world.step(now: now, pointer: CGPoint(x: x, y: 4), rolling: false)
        }
        let floor = try XCTUnwrap(world.surfaces.first { $0.kind == .ground })

        roll(from: 100, to: 700)
        let man = try XCTUnwrap(floor.snowmen.first)
        XCTAssertEqual(man.balls.count, 1)
        XCTAssertGreaterThan(man.balls[0], 6)

        // A second ball rolled up to the first one goes on top of it.
        roll(from: 1150, to: CGFloat(floor.left + man.x))
        XCTAssertEqual(floor.snowmen.count, 1)
        XCTAssertEqual(man.balls.count, 2)
    }

    private func floorWithSnowmen(at positions: [Float]) throws -> (SnowWorld, SnowWorld.Surface, Double) {
        let world = SnowWorld()
        world.falling = false
        world.setScreens([screen])
        var now = 1.0
        world.step(now: now)
        let floor = try XCTUnwrap(world.surfaces.first { $0.kind == .ground })
        for x in positions {
            world.buildSnowman()
            floor.snowmen.last?.x = x
            floor.snowmen.last?.ground = 0
        }
        now += 0.05
        world.step(now: now)
        return (world, floor, now)
    }

    func testThrownSnowmanKnocksAnotherOneDown() throws {
        var (world, floor, now) = try floorWithSnowmen(at: [300, 600])
        let grip = CGPoint(x: 300, y: 40)
        XCTAssertTrue(world.wantsClick(at: grip))
        world.grab(at: grip)
        var p = grip
        for _ in 0..<8 {
            now += 1.0 / 60
            p.x += 20
            p.y += 4
            world.step(now: now, pointer: p)
        }
        world.letGo()
        for _ in 0..<180 {
            now += 1.0 / 60
            world.step(now: now, pointer: CGPoint(x: 1100, y: 700))
        }
        XCTAssertFalse(floor.snowmen.contains { $0.balls.count == 3 && abs($0.x - 600) < 5 })
    }

    func testSnowballSplatsOnAWindowInsteadOfBouncing() throws {
        var (world, floor, now) = try floorWithSnowmen(at: [40])
        floor.snowmen[0].balls = [12]
        world.updateWindows([(7, window)], dock: nil, now: now)
        let grip = CGPoint(x: 40, y: 12)
        world.grab(at: grip)
        var p = grip
        for _ in 0..<20 {
            now += 1.0 / 60
            p.y += 18
            world.step(now: now, pointer: p)
        }
        for _ in 0..<4 {
            now += 1.0 / 60
            p.x += 10
            world.step(now: now, pointer: p)
        }
        world.letGo()
        var fastest: Float = 0
        for _ in 0..<60 {
            now += 1.0 / 60
            world.step(now: now, pointer: CGPoint(x: 1100, y: 700))
            fastest = max(fastest, world.bodies.map { -$0.velocity.x }.max() ?? 0)
        }
        XCTAssertTrue(world.bodies.isEmpty, "the snowball should splat")
        XCTAssertFalse(world.lumps.isEmpty)
        XCTAssertLessThan(fastest, 60, "nothing should spring back off the wall")
    }

    func testSwipeThroughTheHeadKnocksOnlyTheHeadOff() throws {
        var (world, floor, now) = try floorWithSnowmen(at: [500])
        let man = try XCTUnwrap(floor.snowmen.first)
        let head = man.centres[2]
        for x in stride(from: 380, through: 620, by: 12) {
            now += 1.0 / 60
            world.step(now: now, pointer: CGPoint(x: CGFloat(x), y: CGFloat(head)))
        }
        XCTAssertEqual(man.balls.count, 2)
        XCTAssertFalse(man.face)
        XCTAssertTrue(world.bodies.contains { $0.face } || floor.snowmen.contains { $0.face })
    }

    func testTreesGrowInDeepSnowAndSinkWhenItGoes() throws {
        let (world, floor, start) = try floorWithSnowmen(at: [])
        var now = start
        floor.columns = Array(repeating: 30, count: floor.columns.count)
        for _ in 0..<(60 * 40) {
            now += 1.0 / 60
            world.step(now: now)
        }
        XCTAssertFalse(floor.trees.isEmpty)
        floor.columns = Array(repeating: 0, count: floor.columns.count)
        for _ in 0..<(60 * 5) {
            now += 1.0 / 60
            world.step(now: now)
        }
        XCTAssertTrue(floor.trees.isEmpty)
    }

    func testGentleMoveCarriesSnow() throws {
        var (world, now) = snowyWorld()
        let before = try XCTUnwrap(drift(world))
        let lumps = world.lumps.count
        var frame = window
        for _ in 0..<30 {
            now += 1.0 / 30
            frame = frame.offsetBy(dx: 0, dy: 6)
            world.updateWindows([(7, frame)], dock: nil, now: now)
        }
        XCTAssertEqual(world.lumps.count, lumps)
        XCTAssertEqual(drift(world), before)
        XCTAssertEqual(world.surfaces.first { $0.key == 7 }?.top, Float(frame.maxY))
    }

    func testJerkShakesSnowLoose() throws {
        var (world, now) = snowyWorld()
        let before = try XCTUnwrap(drift(world)).reduce(0, +)
        let lumps = world.lumps.count
        now += 1.0 / 30
        world.updateWindows([(7, window.offsetBy(dx: 60, dy: 0))], dock: nil, now: now)
        XCTAssertGreaterThan(world.lumps.count, lumps)
        XCTAssertLessThan(try XCTUnwrap(drift(world)).reduce(0, +), before)
    }
}
