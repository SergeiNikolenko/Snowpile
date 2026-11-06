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
    let parts: MTLRenderPipelineState

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
        parts = pipeline("partVertex", "partFragment")
    }
}

/// Takes clicks on snow; the window lets every other click through to whatever is below.
final class SnowView: MTKView {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPress() }
    override func mouseUp(with event: NSEvent) { onRelease() }
}

/// A transparent window over one screen, above the Dock and normal windows, click-through except over snow.
final class Overlay: NSObject, MTKViewDelegate {
    let index: Int
    let frame: CGRect
    private let scale: CGFloat
    private let window: NSPanel
    private let view: SnowView
    private unowned let world: SnowWorld
    private var shown = false

    init(screen: NSScreen, index: Int, world: SnowWorld) {
        self.index = index
        self.frame = screen.frame
        self.scale = screen.backingScaleFactor
        self.world = world
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.setFrame(screen.frame, display: false)
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        view = SnowView(frame: CGRect(origin: .zero, size: screen.frame.size), device: SnowGPU.shared.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = 60
        view.isPaused = true
        super.init()
        view.delegate = self
        view.onPress = { [weak world] in world?.grab(at: NSEvent.mouseLocation) }
        view.onRelease = { [weak world] in world?.letGo() }
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
        world.step(now: now, pointer: NSEvent.mouseLocation,
                   rolling: NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option)
        let mouse = NSEvent.mouseLocation
        let catches = frame.contains(mouse) && world.wantsClick(at: mouse)
        if window.ignoresMouseEvents == catches { window.ignoresMouseEvents = !catches }
        let gpu = SnowGPU.shared
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = gpu.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var scene = SceneUniforms(size: SIMD2(Float(frame.width), Float(frame.height)),
                                  origin: SIMD2(Float(frame.minX), Float(frame.minY)),
                                  scale: Float(scale), time: Float(now - world.start))
        let sceneLength = MemoryLayout<SceneUniforms>.stride

        let trees = world.trees(in: frame)
        if !trees.isEmpty {
            let buffer = gpu.device.makeBuffer(bytes: trees, length: trees.count * MemoryLayout<Part>.stride)!
            encoder.setRenderPipelineState(gpu.parts)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&scene, length: sceneLength, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: trees.count)
        }

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

        let parts = world.parts(in: frame)
        if !parts.isEmpty {
            let buffer = gpu.device.makeBuffer(bytes: parts, length: parts.count * MemoryLayout<Part>.stride)!
            encoder.setRenderPipelineState(gpu.parts)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&scene, length: sceneLength, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: parts.count)
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
