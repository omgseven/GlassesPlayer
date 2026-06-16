import Cocoa

// MARK: - Window Configuration

extension PlayerMetalView {

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

    @objc func windowWillEnterFullScreen(_ note: Notification) {
        model?.isFullScreen = true
    }

    @objc func windowWillExitFullScreen(_ note: Notification) {
        model?.isFullScreen = false
    }

    // MARK: - Traffic Lights

    func syncTrafficLights() {
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
        window.invalidateCursorRects(for: self)
    }
}
