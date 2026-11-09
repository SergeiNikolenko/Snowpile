import CoreGraphics
import XCTest
@testable import Snowpile

final class SnowMotionTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let window = CGRect(x: 100, y: 200, width: 500, height: 300)

    private func world() throws -> (SnowWorld, SnowWorld.Surface) {
        let world = SnowWorld()
        world.falling = false
        world.setScreens([screen])
        world.updateWindows([(7, window)], dock: nil, now: 1)
        world.step(now: 1)
        let surface = try XCTUnwrap(world.surfaces.first { $0.key == 7 })
        surface.columns = Array(repeating: 8, count: surface.columns.count)
        return (world, surface)
    }

    func testFastDropLeavesConnectedSnowAtItsOriginalHeight() throws {
        let (world, surface) = try world()
        let top = surface.top
        let amount = surface.columns.reduce(0, +)
        world.updateWindows([(7, window.offsetBy(dx: 0, dy: -50))], dock: nil, now: 1.033)
        let sheet = try XCTUnwrap(world.sheets.first)
        XCTAssertEqual(sheet.surface.top, top)
        XCTAssertEqual(sheet.surface.columns.reduce(0, +), amount, accuracy: 0.01)
        XCTAssertEqual(surface.columns.reduce(0, +), 0)
        world.step(now: 1.05)
        XCTAssertGreaterThan(try XCTUnwrap(world.sheets.first).surface.top, surface.top + 40)
        for step in 2...15 { world.step(now: 1 + Double(step) / 60) }
        XCTAssertTrue(world.sheets.isEmpty)
        XCTAssertFalse(world.lumps.isEmpty)
    }

    func testClosingReleasesSnowWhileSpaceChangeStashesIt() throws {
        let (closing, _) = try world()
        closing.updateWindows([], dock: nil, now: 1.033, departing: [7])
        XCTAssertEqual(closing.sheets.count, 1)
        let (hidden, surface) = try world()
        let before = surface.columns
        hidden.updateWindows([], dock: nil, now: 1.033)
        XCTAssertTrue(hidden.sheets.isEmpty)
        hidden.updateWindows([(7, window)], dock: nil, now: 1.066)
        XCTAssertEqual(try XCTUnwrap(hidden.surfaces.first { $0.key == 7 }).columns, before)
    }

    func testLateDepartureReleasesCachedSnowOnlyOnce() throws {
        let (world, _) = try world()
        world.updateWindows([], dock: nil, now: 1.033)
        world.updateWindows([], dock: nil, now: 1.066, departing: [7])
        XCTAssertEqual(world.sheets.count, 1)
        world.updateWindows([], dock: nil, now: 1.1, departing: [7])
        XCTAssertEqual(world.sheets.count, 1)
    }

    func testMinimizingWindowCannotAccumulateAgainDuringItsAnimation() throws {
        let (world, _) = try world()
        world.updateWindows([(7, window)], dock: nil, now: 1.033, departing: [7])
        world.updateWindows([(7, window)], dock: nil, now: 1.066)
        XCTAssertNil(world.surfaces.first { $0.key == 7 })
        XCTAssertEqual(world.sheets.count, 1)
        world.updateWindows([], dock: nil, now: 1.1)
        world.updateWindows([(7, window)], dock: nil, now: 1.133)
        XCTAssertTrue(try XCTUnwrap(world.surfaces.first { $0.key == 7 }).isBare)
    }

    func testResizeReleasesTrimmedSnowAtTheEdge() throws {
        let (world, surface) = try world()
        var resized = window
        resized.size.width -= 100
        world.updateWindows([(7, resized)], dock: nil, now: 1.033)
        XCTAssertEqual(surface.columns.count, 190)
        XCTAssertFalse(world.lumps.isEmpty)
        XCTAssertTrue(world.lumps.allSatisfy { $0.x >= Float(resized.maxX) - 10 })
        XCTAssertTrue(world.sheets.isEmpty)
    }

    func testRepeatedModerateShakesReleaseMoreThanStraightMotion() throws {
        let (shaking, shaken) = try world()
        let (straight, carried) = try world()
        var now = 1.0
        for step in 1...12 {
            now += 1.0 / 30
            shaking.updateWindows([(7, window.offsetBy(dx: step.isMultiple(of: 2) ? 0 : 8, dy: 0))], dock: nil, now: now)
            straight.updateWindows([(7, window.offsetBy(dx: CGFloat(step * 8), dy: 0))], dock: nil, now: now)
            shaking.step(now: now)
            straight.step(now: now)
        }
        XCTAssertLessThan(shaken.columns.reduce(0, +), carried.columns.reduce(0, +) * 0.8)
    }

    func testFallingClumpsProducePowderWhichExpires() throws {
        let (world, _) = try world()
        world.updateWindows([], dock: nil, now: 1.033, departing: [7])
        var sawPowder = false
        for step in 1...180 {
            world.step(now: 1 + Double(step) / 60)
            sawPowder = sawPowder || !world.puffs.isEmpty
        }
        XCTAssertTrue(sawPowder)
        XCTAssertTrue(world.puffs.isEmpty)
        XCTAssertTrue(world.lumps.isEmpty)
    }
    func testSmoothMotionCarriesSnowWithoutReleasingIt() throws {
        let (world, surface) = try world()
        var now = 1.0
        for step in 1...60 {
            now += 1.0 / 60
            world.updateWindows([(7, window.offsetBy(dx: CGFloat(step * 2), dy: CGFloat(step)))], dock: nil, now: now)
            world.step(now: now)
        }
        XCTAssertTrue(world.sheets.isEmpty)
        XCTAssertTrue(world.lumps.isEmpty)
        XCTAssertGreaterThan(surface.columns.reduce(0, +), Float(surface.columns.count) * 7.8)
    }

    func testReleasedSnowCanLandOnItsWindowAfterADrop() throws {
        let (world, surface) = try world()
        world.updateWindows([(7, window.offsetBy(dx: 0, dy: -35))], dock: nil, now: 1.033)
        for step in 1...90 { world.step(now: 1 + Double(step) / 60) }
        XCTAssertGreaterThan(surface.columns.reduce(0, +), 20)
    }

    func testSpaceSwitchDoesNotCarryDetachedSnowIntoAnotherSpace() throws {
        let (world, _) = try world()
        world.setSpaces([1])
        world.updateWindows([], dock: nil, now: 1.033, departing: [7])
        XCTAssertFalse(world.sheets.isEmpty)
        world.setSpaces([2])
        XCTAssertTrue(world.sheets.isEmpty)
        XCTAssertTrue(world.puffs.isEmpty)
        XCTAssertTrue(world.lumps.isEmpty)
    }

}
