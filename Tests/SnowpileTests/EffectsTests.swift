import XCTest
import AppKit
import MetalKit
@testable import Snowpile

final class EffectsTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 800, height: 600)

    func testPauseRetiresParticlesAndSwitchResetsState() {
        let world = EffectWorld()
        world.setScreens([screen])
        world.effect = .fireflies
        for i in 1...300 { world.step(now: Double(i) / 30, pointer: nil) }
        XCTAssertFalse(world.particles.isEmpty)
        world.running = false
        for i in 301...360 { world.step(now: Double(i) / 30, pointer: nil) }
        XCTAssertTrue(world.isIdle)
        world.effect = .leaves
        XCTAssertTrue(world.particles.isEmpty)
    }

    func testSpaceChangeClearsTransientParticles() {
        let world = EffectWorld()
        world.effect = .rain
        world.setScreens([screen])
        for i in 1...60 { world.step(now: Double(i) / 30, pointer: nil) }
        XCTAssertFalse(world.particles.isEmpty)
        world.spaceChanged()
        XCTAssertTrue(world.particles.isEmpty)
    }

    func testSettledLeavesFollowWindowAcrossDisplays() throws {
        let world = EffectWorld()
        world.effect = .leaves
        world.setScreens([screen, screen.offsetBy(dx: 800, dy: 0)])
        let window = CGRect(x: 100, y: 130, width: 600, height: 220)
        world.updateWindows([(key: 10, frame: window)], dock: nil)
        for i in 1...600 { world.step(now: Double(i) / 30, pointer: nil) }
        let settled = world.particles.filter { $0.restingOn == 10 }
        XCTAssertFalse(settled.isEmpty)
        for i in 1...40 {
            world.updateWindows([(key: 10, frame: window.offsetBy(dx: CGFloat(i * 20), dy: 0))], dock: nil)
        }
        for leaf in settled {
            let moved = try XCTUnwrap(world.particles.first { $0.phase == leaf.phase })
            XCTAssertEqual(moved.position.x, leaf.position.x + 800, accuracy: 0.01)
            XCTAssertEqual(moved.screen, 1)
            XCTAssertEqual(moved.restingOn, 10)
        }
    }

    func testPauseRetiresPetalsAndLeavesEvenWhenLandingOrBrushed() {
        for effect in [Effect.sakura, .leaves] {
            let world = EffectWorld()
            world.effect = effect
            world.setScreens([screen])
            world.updateWindows([(key: 10, frame: CGRect(x: 0, y: 200, width: 800, height: 150))], dock: nil)
            for i in 1...600 { world.step(now: Double(i) / 30, pointer: nil) }
            XCTAssertTrue(world.particles.contains { $0.restingOn == 10 })
            world.running = false
            for i in 601...675 {
                world.step(now: Double(i) / 30, pointer: CGPoint(x: (i * 17) % 800, y: 352))
            }
            XCTAssertTrue(world.isIdle, effect.rawValue)
        }
    }

    func testReduceMotionSuppressesLightning() {
        for reduced in [false, true] {
            let world = EffectWorld()
            world.effect = .rain
            world.reduceMotion = reduced
            world.setScreens([screen])
            for i in 1...244 { world.step(now: Double(i) / 30, pointer: nil) }
            XCTAssertEqual(world.particles.contains { $0.kind == 6 }, !reduced)
        }
    }

    func testOrdinaryRainDoesNotCreateLightning() {
        let world = EffectWorld()
        world.effect = .rain
        world.lightningEnabled = false
        world.setScreens([screen])
        for i in 1...900 { world.step(now: Double(i) / 30, pointer: nil) }
        XCTAssertFalse(world.particles.isEmpty)
        XCTAssertFalse(world.particles.contains { $0.kind == 6 })
    }

    func testDryThunderstormHasLightningWithoutRaindrops() {
        let world = EffectWorld()
        world.effect = .rain
        world.intensity = 0
        world.setScreens([screen])
        for i in 1...244 { world.step(now: Double(i) / 30, pointer: nil) }
        XCTAssertTrue(world.particles.contains { $0.kind == 6 })
        XCTAssertFalse(world.particles.contains { $0.kind == 0 })
    }

    func testEveryEffectRendersWithMetal() throws {
        let gpu = SnowGPU.shared
        let width = 800, height = 600
        let textureDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        textureDescription.usage = [.renderTarget, .shaderRead]
        textureDescription.storageMode = .shared
        let texture = try XCTUnwrap(gpu.device.makeTexture(descriptor: textureDescription))
        for effect in Effect.allCases where effect != .snow {
            let world = EffectWorld()
            world.effect = effect
            world.setScreens([screen])
            world.updateWindows([(key: 10, frame: CGRect(x: 100, y: 130, width: 600, height: 220))], dock: nil)
            let frames = effect == .rain ? 244 : 270
            for i in 1...frames { world.step(now: Double(i) / 30, pointer: CGPoint(x: 400, y: 320)) }
            // Meteors are intentionally intermittent. Capture an actual visible meteor instead of
            // assuming that one exists at a single randomly chosen instant.
            if effect == .starfall {
                for i in (frames + 1)...(frames + 900) {
                    if world.particles.contains(where: { screen.insetBy(dx: 100, dy: 100).contains(CGPoint(x: CGFloat($0.position.x), y: CGFloat($0.position.y))) }) { break }
                    world.step(now: Double(i) / 30, pointer: nil)
                }
            }
            let sprites = world.sprites(screen: 0, frame: screen)
            XCTAssertFalse(sprites.isEmpty, effect.rawValue)
            let buffer = try XCTUnwrap(gpu.device.makeBuffer(bytes: sprites, length: sprites.count * MemoryLayout<EffectSprite>.stride))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.07, green: 0.08, blue: 0.1, alpha: 1)
            let command = try XCTUnwrap(gpu.queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            var scene = SceneUniforms(size: SIMD2(Float(width), Float(height)), origin: .zero, scale: 1, time: 9)
            encoder.setRenderPipelineState(gpu.effects)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&scene, length: MemoryLayout<SceneUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: sprites.count)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            XCTAssertNil(command.error, effect.rawValue)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            let lit = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 35 || bytes[$0 + 1] > 30 || bytes[$0 + 2] > 30 }.count
            XCTAssertGreaterThan(lit, 8, effect.rawValue)
            if let directory = ProcessInfo.processInfo.environment["SNOWPILE_RENDER_OUTPUT"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
                let destination = try XCTUnwrap(bitmap.bitmapData)
                for i in stride(from: 0, to: bytes.count, by: 4) {
                    destination[i] = bytes[i + 2]; destination[i + 1] = bytes[i + 1]
                    destination[i + 2] = bytes[i]; destination[i + 3] = bytes[i + 3]
                }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(effect.rawValue + ".png"))
            }
        }
    }
}
