import Cocoa

// MARK: - Custom Cursor

func makeCircleCursor(opacity: Double) -> NSCursor {
    let size: CGFloat = 19
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        NSColor.white.withAlphaComponent(CGFloat(opacity / 100.0)).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
    return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
}

// MARK: - Input Handling

extension PlayerMetalView {

    override func resetCursorRects() {
        discardCursorRects()
        let is2D = model?.sourceLayout.is2D ?? true
        let controlsHidden = model?.controlsVisible == false
        if !is2D && controlsHidden {
            let opacity = AppSettings.shared.cursorOpacity
            addCursorRect(bounds, cursor: makeCircleCursor(opacity: opacity))
        } else {
            addCursorRect(bounds, cursor: .arrow)
        }
    }

    func handleGlobalMouseMoved(_ event: NSEvent) {
        guard let window = self.window, window.isKeyWindow else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let screenPoint = NSEvent.mouseLocation
        let windowRect = window.convertFromScreen(NSRect(origin: screenPoint, size: .zero))
        let location = convert(windowRect.origin, from: nil)

        guard model?.camera.cameraControl == .move else {
            yawWrapOffset = 0
            lastScreenPoint = nil
            isSmoothing = false
            return
        }

        if model?.sourceLayout.is360 == true {
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
                model?.camera.updateCamera(yaw: targetYaw, pitch: targetPitch)
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

    func interpolateCamera() {
        guard isSmoothing, let model = model else { return }
        let factor: Float = 0.15
        let newYaw = model.camera.cameraYaw + (targetYaw - model.camera.cameraYaw) * factor
        let newPitch = model.camera.cameraPitch + (targetPitch - model.camera.cameraPitch) * factor
        if abs(targetYaw - newYaw) < 0.002 && abs(targetPitch - newPitch) < 0.002 {
            model.camera.updateCamera(yaw: targetYaw, pitch: targetPitch)
            isSmoothing = false
        } else {
            model.camera.updateCamera(yaw: newYaw, pitch: newPitch)
        }
    }

    func warpCursor(toViewX x: CGFloat, viewY y: CGFloat, in window: NSWindow) {
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
        if let contentRect = window?.contentLayoutRect,
           event.locationInWindow.y > contentRect.maxY {
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

        if event.modifierFlags.contains(.option) || !shouldDragCamera {
            var frameOrigin = window.frame.origin
            frameOrigin.x += dx
            frameOrigin.y += dy
            window.setFrameOrigin(frameOrigin)
        } else if model?.sourceLayout.is360 == true {
            let sensitivity: Float = 0.005
            let invert: Float = AppSettings.shared.dragFollowsMouse ? 1 : -1
            let newYaw = (model?.camera.cameraYaw ?? 0) + Float(dx) * sensitivity * invert
            let newPitch = (model?.camera.cameraPitch ?? 0) + Float(dy) * sensitivity * invert
            model?.camera.updateCamera(yaw: newYaw, pitch: newPitch)
        } else {
            let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            onMouseMoved?(location, bounds.size)
        }
        mouseDownOrigin = current
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownOrigin = nil
        draggedDistance = 0
    }

    override func rightMouseDown(with event: NSEvent) {
        model?.controlsVisible.toggle()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10.0 : event.scrollingDeltaY
        if event.modifierFlags.contains(.option) {
            let direction: Double = AppSettings.shared.naturalScrollVolume ? 1 : -1
            model?.setVolume((model?.volume ?? 100) + Double(delta) * direction)
        } else {
            onScrollWheel?(delta)
        }
    }

    var shouldDragCamera: Bool {
        model?.camera.cameraControl == .drag
    }
}
