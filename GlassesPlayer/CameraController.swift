import Foundation
import Observation

@Observable
@MainActor
final class CameraController {
    var cameraYaw: Float = 0
    var cameraPitch: Float = 0
    var zoomFactor: Float = 1.0
    var maxTanHalf: Float = 1.732
    var cameraControl: CameraControl = .move

    var effectiveTanHalfVFOV: Float {
        min(1.0 / zoomFactor, maxTanHalf)
    }

    /// Unified camera state write entry point.
    /// All camera yaw/pitch updates must go through this method.
    func updateCamera(yaw: Float, pitch: Float) {
        cameraYaw = yaw
        cameraPitch = min(.pi / 2, max(-.pi / 2, pitch))
    }

    func handleMouseMoved(_ location: CGPoint, viewSize: CGSize, sourceLayout: SourceLayout) {
        guard !sourceLayout.is2D else { return }
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        var nx = Float(location.x / viewSize.width) * 2.0 - 1.0
        var ny = Float(location.y / viewSize.height) * 2.0 - 1.0

        let maxComp = max(abs(nx), abs(ny))
        if maxComp > 1.0 {
            nx /= maxComp
            ny /= maxComp
        }

        let aspect = Float(viewSize.width / viewSize.height)
        let effectiveHalfH = atan(effectiveTanHalfVFOV * aspect)
        let effectiveHalfV = atan(effectiveTanHalfVFOV)
        let maxYaw = max(0, Float.pi / 2.0 - effectiveHalfH)
        let maxPitch = max(0, Float.pi / 2.0 - effectiveHalfV)
        updateCamera(yaw: nx * maxYaw, pitch: ny * maxPitch)
    }

    func handleScrollWheel(_ deltaY: CGFloat, sourceLayout: SourceLayout) {
        guard !sourceLayout.is2D else { return }
        let factor: Float = 0.1
        zoomFactor *= 1.0 + Float(deltaY) * factor
        let minZoom = 1.0 / maxTanHalf
        zoomFactor = max(minZoom, min(5.0, zoomFactor))
    }

    func resetForLayout(_ layout: SourceLayout) {
        zoomFactor = layout.is360 ? 2.0 : 1.0
        if layout.is2D { cameraYaw = 0; cameraPitch = 0 }
    }
}
