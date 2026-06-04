import Cocoa
import OpenGL.GL3

final class PlayerOpenGLView: NSOpenGLView {
    var onMouseMoved: ((CGPoint, CGSize) -> Void)?
    var onScrollWheel: ((CGFloat) -> Void)?
    weak var model: VideoPlayerModel?
    private var player: OpaquePointer?
    private var glInitialized = false
    private var displayTimer: Timer?

    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, player: OpaquePointer?) {
        self.player = player

        let attrs: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFADepthSize), 0,
            0
        ]
        let pixelFormat = NSOpenGLPixelFormat(attributes: attrs)!
        super.init(frame: frame, pixelFormat: pixelFormat)!

        wantsBestResolutionOpenGLSurface = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareOpenGL() {
        super.prepareOpenGL()

        openGLContext?.makeCurrentContext()

        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)

        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    override func reshape() {
        super.reshape()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = openGLContext, let p = player else { return }
        ctx.makeCurrentContext()

        if !glInitialized {
            if mpv_player_init_gl(p) == 0 {
                glInitialized = true
            } else {
                return
            }
        }

        let scale = window?.backingScaleFactor ?? 2.0
        let w = Int(bounds.width * scale)
        let h = Int(bounds.height * scale)
        let aspect = Float(bounds.width / bounds.height)

        let yaw = model?.cameraYaw ?? 0
        let pitch = model?.cameraPitch ?? 0
        let fov = model?.effectiveTanHalfVFOV ?? 1.0
        let displayMode = Int32(model?.displayMode ?? 0)
        let sourceLayout = Int32(model?.sourceLayout ?? 0)

        mpv_player_render(p, Int32(w), Int32(h), yaw, pitch, fov, aspect, displayMode, sourceLayout)

        ctx.flushBuffer()
        mpv_player_report_swap(p)
    }

    override func updateTrackingAreas() {
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseMoved?(location, bounds.size)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10.0 : event.scrollingDeltaY
        onScrollWheel?(delta)
    }

    deinit {
        displayTimer?.invalidate()
    }
}
