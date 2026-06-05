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
    private var eventMonitor: Any?
    private var lastControlsVisible = true
    private var cachedTexture: MTLTexture?
    private var cachedSurfaceID: UInt32 = 0
    private var clickTimer: DispatchWorkItem?
    private var mouseDownOrigin: NSPoint?
    private var draggedDistance: CGFloat = 0
    private var didWarpCursor = false
    private var yawWrapOffset: Float = 0
    private var lastScreenPoint: NSPoint?
    private var targetYaw: Float = 0
    private var targetPitch: Float = 0
    private var isSmoothing = false

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

        let sourceLayout = Int32(model?.sourceLayout ?? 0)
        let displayMode = sourceLayout == 2 ? 0 : (model?.displayMode ?? 0)
        let yaw = model?.cameraYaw ?? 0
        let pitch = model?.cameraPitch ?? 0
        let fov = model?.effectiveTanHalfVFOV ?? 1.0

        let drawableWidth = Int(view.drawableSize.width)
        let drawableHeight = Int(view.drawableSize.height)

        if displayMode == 2 {
            // Both eyes side-by-side
            let hw = drawableWidth / 2
            let halfAspect = Float(hw) / Float(drawableHeight)

            // Left eye
            encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                            width: Double(hw), height: Double(drawableHeight),
                                            znear: 0, zfar: 1))
            var uniforms = ProjectionUniforms(cameraYaw: yaw, cameraPitch: pitch,
                                             tanHalfVFOV: fov, aspectRatio: halfAspect,
                                             eyeIndex: 0, sourceLayout: sourceLayout)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ProjectionUniforms>.size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

            // Right eye
            encoder.setViewport(MTLViewport(originX: Double(hw), originY: 0,
                                            width: Double(hw), height: Double(drawableHeight),
                                            znear: 0, zfar: 1))
            uniforms.eyeIndex = 1
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ProjectionUniforms>.size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        } else {
            // Single eye
            let aspect = Float(drawableWidth) / Float(drawableHeight)
            encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                            width: Double(drawableWidth), height: Double(drawableHeight),
                                            znear: 0, zfar: 1))
            var uniforms = ProjectionUniforms(cameraYaw: yaw, cameraPitch: pitch,
                                             tanHalfVFOV: fov, aspectRatio: aspect,
                                             eyeIndex: Int32(displayMode), sourceLayout: sourceLayout)
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

    // MARK: - Window Configuration

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        window.isMovableByWindowBackground = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleGlobalMouseMoved(event)
            return event
        }

        NotificationCenter.default.addObserver(self, selector: #selector(windowWillEnterFullScreen),
                                               name: NSWindow.willEnterFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillExitFullScreen),
                                               name: NSWindow.willExitFullScreenNotification, object: window)
    }

    @objc private func windowWillEnterFullScreen(_ note: Notification) {
        model?.isFullScreen = true
    }

    @objc private func windowWillExitFullScreen(_ note: Notification) {
        model?.isFullScreen = false
    }

    // MARK: - Traffic Lights

    private func syncTrafficLights() {
        guard let window = self.window else { return }
        let visible = model?.controlsVisible ?? true
        guard visible != lastControlsVisible else { return }
        lastControlsVisible = visible
        let alpha: CGFloat = visible ? 1 : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(type)?.animator().alphaValue = alpha
            }
        }
    }

    // MARK: - Input

    private func handleGlobalMouseMoved(_ event: NSEvent) {
        guard let window = self.window, window.isKeyWindow else { return }
        let screenPoint = NSEvent.mouseLocation
        let windowRect = window.convertFromScreen(NSRect(origin: screenPoint, size: .zero))
        let location = convert(windowRect.origin, from: nil)

        if model?.sourceLayout == 2 {
            if didWarpCursor {
                didWarpCursor = false
                lastScreenPoint = screenPoint
                return
            }

            let nx = Float(location.x / bounds.width) * 2.0 - 1.0
            let ny = Float(location.y / bounds.height) * 2.0 - 1.0
            let newYaw = yawWrapOffset + nx * .pi
            let newPitch = min(Float.pi / 2.0, max(-.pi / 2.0, ny * (.pi / 2.0)))

            let screenDelta: CGFloat
            if let last = lastScreenPoint {
                screenDelta = hypot(screenPoint.x - last.x, screenPoint.y - last.y)
            } else {
                screenDelta = 1000
            }
            lastScreenPoint = screenPoint

            let angleDelta = abs(newYaw - targetYaw) + abs(newPitch - targetPitch)
            targetYaw = newYaw
            targetPitch = newPitch

            if screenDelta < 5 && angleDelta > 0.3 {
                isSmoothing = true
            } else if !isSmoothing {
                model?.cameraYaw = targetYaw
                model?.cameraPitch = targetPitch
            }

            if model?.isFullScreen == true {
                let margin: CGFloat = 2
                if location.x <= margin {
                    yawWrapOffset -= 2.0 * .pi
                    warpCursor(toViewX: bounds.width - margin * 2, viewY: location.y, in: window)
                } else if location.x >= bounds.width - margin {
                    yawWrapOffset += 2.0 * .pi
                    warpCursor(toViewX: margin * 2, viewY: location.y, in: window)
                }
            }
        } else {
            yawWrapOffset = 0
            lastScreenPoint = nil
            isSmoothing = false
            onMouseMoved?(location, bounds.size)
        }
    }

    private func interpolateCamera() {
        guard isSmoothing, let model = model else { return }
        let factor: Float = 0.15
        model.cameraYaw += (targetYaw - model.cameraYaw) * factor
        model.cameraPitch += (targetPitch - model.cameraPitch) * factor
        if abs(targetYaw - model.cameraYaw) < 0.002 && abs(targetPitch - model.cameraPitch) < 0.002 {
            model.cameraYaw = targetYaw
            model.cameraPitch = targetPitch
            isSmoothing = false
        }
    }

    private func warpCursor(toViewX x: CGFloat, viewY y: CGFloat, in window: NSWindow) {
        let inWindow = convert(NSPoint(x: x, y: y), to: nil)
        let screenRect = window.convertToScreen(NSRect(origin: inWindow, size: .zero))
        let screenH = NSScreen.screens.first(where: {
            $0.frame.contains(screenRect.origin)
        })?.frame.height ?? NSScreen.main!.frame.height
        let cgPoint = CGPoint(x: screenRect.origin.x, y: screenH - screenRect.origin.y)
        CGAssociateMouseAndMouseCursorPosition(0)
        CGWarpMouseCursorPosition(cgPoint)
        CGAssociateMouseAndMouseCursorPosition(1)
        didWarpCursor = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            clickTimer?.cancel()
            clickTimer = nil
            window?.toggleFullScreen(nil)
            return
        }
        mouseDownOrigin = NSEvent.mouseLocation
        draggedDistance = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window, let origin = mouseDownOrigin else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        draggedDistance += hypot(dx, dy)
        var frameOrigin = window.frame.origin
        frameOrigin.x += dx
        frameOrigin.y += dy
        window.setFrameOrigin(frameOrigin)
        mouseDownOrigin = current
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 1 && draggedDistance < 3 {
            let work = DispatchWorkItem { [weak self] in
                self?.model?.togglePlayPause()
            }
            clickTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        mouseDownOrigin = nil
        draggedDistance = 0
    }

    override func rightMouseDown(with event: NSEvent) {
        model?.controlsVisible.toggle()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10.0 : event.scrollingDeltaY
        onScrollWheel?(delta)
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
