import Cocoa
import MetalKit
import IOSurface

struct ProjectionUniforms {
    var cameraYaw: Float
    var cameraPitch: Float
    var tanHalfVFOV: Float
    var aspectRatio: Float
    var eyeIndex: Int32
    var sourceLayout: Int32
}

final class PlayerMetalView: MTKView, MTKViewDelegate {
    var onMouseMoved: ((CGPoint, CGSize) -> Void)?
    var onScrollWheel: ((CGFloat) -> Void)?
    weak var model: VideoPlayerModel?

    private var player: OpaquePointer?
    private var glInitialized = false
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    var eventMonitor: Any?
    var lastControlsVisible = true
    private var cachedTexture: MTLTexture?
    private var cachedSurfaceID: UInt32 = 0
    var mouseDownOrigin: NSPoint?
    var draggedDistance: CGFloat = 0
    var didWarpCursor = false
    var yawWrapOffset: Float = 0
    var lastScreenPoint: NSPoint?
    var targetYaw: Float = 0
    var targetPitch: Float = 0
    var isSmoothing = false

    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, player: OpaquePointer?) {
        self.player = player

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not supported")
        }

        super.init(frame: frame, device: device)

        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        self.layer?.isOpaque = false
        self.preferredFramesPerSecond = 60
        self.isPaused = false
        self.enableSetNeedsDisplay = false

        commandQueue = device.makeCommandQueue()
        setupPipeline(device: device)
    }

    required init(coder: NSCoder) { fatalError() }

    private func setupPipeline(device: MTLDevice) {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunc = library.makeFunction(name: "projectionVertex"),
              let fragmentFunc = library.makeFunction(name: "projectionFragment") else {
            fatalError("Failed to load Metal shaders")
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFunc
        desc.fragmentFunction = fragmentFunc
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        pipelineState = try? device.makeRenderPipelineState(descriptor: desc)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let player = player else { return }

        if !glInitialized {
            if mpv_player_init_gl(player) == 0 {
                glInitialized = true
            } else {
                return
            }
        }

        syncTrafficLights()
        interpolateCamera()

        // Render video frame to IOSurface
        mpv_player_render_frame(player)

        guard let surfaceRef = mpv_player_get_surface(player)?.takeUnretainedValue(),
              let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let pipeline = pipelineState else {
            // No video — just present cleared (transparent) drawable
            if let drawable = currentDrawable,
               let descriptor = currentRenderPassDescriptor,
               let commandBuffer = commandQueue?.makeCommandBuffer() {
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
                encoder?.endEncoding()
                commandBuffer.present(drawable)
                commandBuffer.commit()
            }
            mpv_player_report_swap(player)
            return
        }

        // Get or create Metal texture from IOSurface
        let texture = metalTexture(from: surfaceRef)
        guard let videoTexture = texture else {
            mpv_player_report_swap(player)
            return
        }

        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(videoTexture, index: 0)

        let source = model?.sourceLayout ?? .sideBySide
        let display: DisplayMode = source.is360 ? .leftEye
                               : source.is2D  ? .both
                               : (model?.displayMode ?? .leftEye)
        let yaw = model?.camera.cameraYaw ?? 0
        let pitch = model?.camera.cameraPitch ?? 0
        let fov = model?.camera.effectiveTanHalfVFOV ?? 1.0

        let drawableWidth = Int(view.drawableSize.width)
        let drawableHeight = Int(view.drawableSize.height)

        if display == .both {
            let hw = drawableWidth / 2
            let halfAspect = Float(hw) / Float(drawableHeight)

            encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                            width: Double(hw), height: Double(drawableHeight),
                                            znear: 0, zfar: 1))
            var uniforms = ProjectionUniforms(cameraYaw: yaw, cameraPitch: pitch,
                                             tanHalfVFOV: fov, aspectRatio: halfAspect,
                                             eyeIndex: DisplayMode.leftEye.rawValue,
                                             sourceLayout: source.rawValue)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ProjectionUniforms>.size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

            encoder.setViewport(MTLViewport(originX: Double(hw), originY: 0,
                                            width: Double(hw), height: Double(drawableHeight),
                                            znear: 0, zfar: 1))
            uniforms.eyeIndex = DisplayMode.rightEye.rawValue
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ProjectionUniforms>.size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        } else {
            let aspect = Float(drawableWidth) / Float(drawableHeight)
            encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                            width: Double(drawableWidth), height: Double(drawableHeight),
                                            znear: 0, zfar: 1))
            var uniforms = ProjectionUniforms(cameraYaw: yaw, cameraPitch: pitch,
                                             tanHalfVFOV: fov, aspectRatio: aspect,
                                             eyeIndex: display.rawValue,
                                             sourceLayout: source.rawValue)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ProjectionUniforms>.size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        mpv_player_report_swap(player)
    }

    // MARK: - IOSurface → MTLTexture

    private func metalTexture(from surface: IOSurface) -> MTLTexture? {
        let surfaceID = IOSurfaceGetID(unsafeBitCast(surface, to: IOSurfaceRef.self))
        if surfaceID == cachedSurfaceID, let cached = cachedTexture {
            return cached
        }

        let width = IOSurfaceGetWidth(unsafeBitCast(surface, to: IOSurfaceRef.self))
        let height = IOSurfaceGetHeight(unsafeBitCast(surface, to: IOSurfaceRef.self))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]

        let texture = device?.makeTexture(descriptor: desc, iosurface: surface, plane: 0)
        cachedTexture = texture
        cachedSurfaceID = surfaceID
        return texture
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
