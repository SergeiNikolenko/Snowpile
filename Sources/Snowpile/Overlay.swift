import AppKit
import MetalKit

struct SceneUniforms {
    var size: SIMD2<Float>
    var origin: SIMD2<Float>
    var scale: Float
    var time: Float
}

struct DriftUniforms {
    var origin: SIMD2<Float>
    var columnWidth: Float
    var count: Int32
    var height: Float
    var occluders: Int32
}

final class SnowGPU {
    static let shared = SnowGPU()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let sprites: MTLRenderPipelineState
    let drifts: MTLRenderPipelineState

    private init() {
        let device = MTLCreateSystemDefaultDevice()!
        self.device = device
        queue = device.makeCommandQueue()!
        let library = try! device.makeLibrary(source: shaderSource, options: nil)
        func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            let c = d.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        sprites = pipeline("pieceVertex", "pieceFragment")
        drifts = pipeline("driftVertex", "driftFragment")
    }
}

/// A transparent, click-through window over one screen, above the Dock and normal windows.
final class Overlay: NSObject, MTKViewDelegate {
    let index: Int
    let frame: CGRect
    private let scale: CGFloat
    private let window: NSWindow
    private let view: MTKView
    private unowned let world: SnowWorld
    private var shown = false

    init(screen: NSScreen, index: Int, world: SnowWorld) {
        self.index = index
        self.frame = screen.frame
        self.scale = screen.backingScaleFactor
        self.world = world
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: SnowGPU.shared.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = 60
        view.isPaused = true
        super.init()
        view.delegate = self
        window.contentView = view
    }

    func setActive(_ active: Bool) {
        guard active != shown else { return }
        shown = active
        if active {
            window.orderFrontRegardless()
            view.isPaused = false
        } else {
            view.isPaused = true
            window.orderOut(nil)
        }
    }

    func close() {
        view.isPaused = true
        view.delegate = nil
        window.close()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        world.step(now: now, pointer: NSEvent.mouseLocation)
        let gpu = SnowGPU.shared
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = gpu.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var scene = SceneUniforms(size: SIMD2(Float(frame.width), Float(frame.height)),
                                  origin: SIMD2(Float(frame.minX), Float(frame.minY)),
                                  scale: Float(scale), time: Float(now - world.start))
        let sceneLength = MemoryLayout<SceneUniforms>.stride

        let drifts = world.drifts(in: frame)
        if !drifts.isEmpty {
            var columns: [Float] = []
            var occluders: [SIMD4<Float>] = []
            var offsets: [(columns: Int, occluders: Int)] = []
            for d in drifts {
                offsets.append((columns.count * MemoryLayout<Float>.stride, occluders.count * MemoryLayout<SIMD4<Float>>.stride))
                columns += d.surface.columns
                occluders += d.occluders
            }
            occluders.append(.zero)
            let columnBuffer = gpu.device.makeBuffer(bytes: columns, length: columns.count * MemoryLayout<Float>.stride)!
            let occluderBuffer = gpu.device.makeBuffer(bytes: occluders, length: occluders.count * MemoryLayout<SIMD4<Float>>.stride)!
            encoder.setRenderPipelineState(gpu.drifts)
            encoder.setVertexBytes(&scene, length: sceneLength, index: 0)
            encoder.setFragmentBytes(&scene, length: sceneLength, index: 0)
            encoder.setFragmentBuffer(columnBuffer, offset: 0, index: 2)
            encoder.setFragmentBuffer(occluderBuffer, offset: 0, index: 3)
            for (d, offset) in zip(drifts, offsets) {
                var u = DriftUniforms(origin: SIMD2(d.surface.left, d.surface.top), columnWidth: SnowWorld.columnWidth,
                                      count: Int32(d.surface.columns.count), height: d.surface.cap, occluders: Int32(d.occluders.count))
                encoder.setVertexBytes(&u, length: MemoryLayout<DriftUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&u, length: MemoryLayout<DriftUniforms>.stride, index: 1)
                encoder.setFragmentBufferOffset(offset.columns, index: 2)
                encoder.setFragmentBufferOffset(offset.occluders, index: 3)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        let sprites = world.sprites(screen: index, frame: frame)
        if !sprites.isEmpty {
            let buffer = gpu.device.makeBuffer(bytes: sprites, length: sprites.count * MemoryLayout<Sprite>.stride)!
            encoder.setRenderPipelineState(gpu.sprites)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&scene, length: sceneLength, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: sprites.count)
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
