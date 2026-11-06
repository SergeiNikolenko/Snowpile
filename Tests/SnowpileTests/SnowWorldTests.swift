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
