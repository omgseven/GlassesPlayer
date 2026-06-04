import Foundation
import Observation
import QuartzCore

@Observable
@MainActor
final class VideoPlayerModel {
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var videoWidth: Int = 0
    var videoHeight: Int = 0
    var isFileOpen = false

    var cameraYaw: Float = 0
    var cameraPitch: Float = 0
    var mouseActivityTrigger = false

    var displayMode: Int = 0      // 0=left, 1=right, 2=both
    var sourceLayout: Int = 0     // 0=LR SBS, 1=TB SBS

    var zoomFactor: Float = 1.0
    var maxTanHalf: Float = 1.732

    var effectiveTanHalfVFOV: Float {
        min(1.0 / zoomFactor, maxTanHalf)
    }

    nonisolated(unsafe) var player: OpaquePointer?
    private var pollTimer: Timer?
    nonisolated(unsafe) private var fileURL: URL?

    init() {
        player = mpv_player_create()
    }

    func openFile(_ url: URL) {
        closeFile()

        guard url.startAccessingSecurityScopedResource() else { return }
        fileURL = url

        guard let p = player else {
            url.stopAccessingSecurityScopedResource()
            fileURL = nil
            return
        }

        let path = url.path
        if mpv_player_open_file(p, path) < 0 {
            url.stopAccessingSecurityScopedResource()
            fileURL = nil
            return
        }

        isFileOpen = true
        startPolling()
        mpv_player_play(p)
    }

    func closeFile() {
        stopPolling()
        if let p = player {
            mpv_player_stop(p)
        }
        if let url = fileURL {
            url.stopAccessingSecurityScopedResource()
            fileURL = nil
        }
        isFileOpen = false
        isPlaying = false
        currentTime = 0
        duration = 0
        videoWidth = 0
        videoHeight = 0
    }

    func togglePlayPause() {
        guard let p = player, isFileOpen else { return }
        if isPlaying {
            mpv_player_pause(p)
        } else {
            mpv_player_play(p)
        }
    }

    func seek(to time: Double) {
        guard let p = player else { return }
        mpv_player_seek(p, time)
        currentTime = time
    }

    func handleMouseMoved(_ location: CGPoint, viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        let nx = Float(location.x / viewSize.width) * 2.0 - 1.0
        let ny = Float(location.y / viewSize.height) * 2.0 - 1.0

        let aspect = Float(viewSize.width / viewSize.height)
        let effectiveHalfH = atan(effectiveTanHalfVFOV * aspect)
        let effectiveHalfV = atan(effectiveTanHalfVFOV)
        let maxYaw = max(0, Float.pi / 2.0 - effectiveHalfH)
        let maxPitch = max(0, Float.pi / 2.0 - effectiveHalfV)

        cameraYaw = nx * maxYaw
        cameraPitch = ny * maxPitch
        mouseActivityTrigger.toggle()
    }

    func handleScrollWheel(_ deltaY: CGFloat) {
        let factor: Float = 0.1
        zoomFactor *= 1.0 + Float(deltaY) * factor
        let minZoom = 1.0 / maxTanHalf
        zoomFactor = max(minZoom, min(5.0, zoomFactor))
        mouseActivityTrigger.toggle()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollMPVEvents()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollMPVEvents() {
        guard let p = player else { return }
        let flags = mpv_player_poll_events(p)
        if flags == 0 { return }

        if flags & MPV_PROP_DURATION != 0 {
            duration = mpv_player_get_duration(p)
        }
        if flags & MPV_PROP_TIME_POS != 0 {
            currentTime = mpv_player_get_time_pos(p)
        }
        if flags & MPV_PROP_PAUSE != 0 {
            isPlaying = mpv_player_is_paused(p) == 0
        }
        if flags & MPV_PROP_VIDEO_SIZE != 0 {
            videoWidth = Int(mpv_player_get_video_width(p))
            videoHeight = Int(mpv_player_get_video_height(p))
        }
        if flags & MPV_PROP_EOF != 0 {
            isPlaying = false
        }
    }

    deinit {
        if let p = player {
            mpv_player_destroy(p)
        }
        fileURL?.stopAccessingSecurityScopedResource()
    }
}
