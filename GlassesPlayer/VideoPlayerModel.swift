import Foundation
import Observation
import QuartzCore

enum PlaybackState: Int {
    case idle = 0
    case playing = 1
    case paused = 2
    case ended = 3
}

enum SourceLayout: Int32 {
    case sideBySide = 0
    case topBottom = 1
    case mono360 = 2

    var is360: Bool { self == .mono360 }
    var isHorizontal: Bool { self == .sideBySide }
}

enum DisplayMode: Int32 {
    case leftEye = 0
    case rightEye = 1
    case both = 2
}

enum CameraControl: Int {
    case move = 0
    case drag = 1
}

enum PlayMode: Int {
    case stopAfterCurrent = 0
    case loopOne = 1
    case playList = 2
    case loopList = 3
}

@Observable
@MainActor
final class VideoPlayerModel {
    var playbackState: PlaybackState = .idle
    var currentTime: Double = 0
    var duration: Double = 0
    var videoWidth: Int = 0
    var videoHeight: Int = 0

    var isPlaying: Bool { playbackState == .playing }
    var isFileOpen: Bool { playbackState != .idle }

    var cameraYaw: Float = 0
    var cameraPitch: Float = 0

    var controlsVisible = true
    var isFullScreen = false
    var displayMode: DisplayMode = .leftEye
    var cameraControl: CameraControl = .move
    var sourceLayout: SourceLayout = .sideBySide {
        didSet { zoomFactor = sourceLayout.is360 ? 2.0 : 1.0 }
    }

    var volume: Double = 100

    func setVolume(_ value: Double) {
        volume = min(100, max(0, value))
        if let p = player { mpv_player_set_volume(p, volume) }
    }

    func setSpeed(_ speed: Double) {
        if let p = player { mpv_player_set_speed(p, speed) }
    }

    var zoomFactor: Float = 1.0
    var maxTanHalf: Float = 1.732

    var effectiveTanHalfVFOV: Float {
        min(1.0 / zoomFactor, maxTanHalf)
    }

    nonisolated(unsafe) var player: OpaquePointer?
    private var pollTimer: Timer?
    nonisolated(unsafe) private var fileURL: URL?
    private var directoryFiles: [URL] = []
    private var currentFileIndex: Int = -1

    init() {
        player = mpv_player_create()
    }

    func openFile(_ url: URL) {
        if url.path == fileURL?.path && isFileOpen {
            seek(to: 0)
            if !isPlaying { togglePlayPause() }
            return
        }

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

        playbackState = .playing
        startPolling()
        mpv_player_play(p)
        scanDirectory(for: url)
    }

    private static let videoExtensions: Set<String> = [
        "mp4", "mkv", "mov", "avi", "m4v", "wmv", "flv", "webm", "ts", "mpg", "mpeg", "3gp"
    ]

    private func scanDirectory(for url: URL) {
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            directoryFiles = []
            currentFileIndex = -1
            return
        }
        directoryFiles = contents
            .filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        currentFileIndex = directoryFiles.firstIndex(where: { $0.path == url.path }) ?? -1
    }

    func openNextFile() {
        guard !directoryFiles.isEmpty, currentFileIndex >= 0 else { return }
        let next = currentFileIndex + 1
        guard next < directoryFiles.count else { return }
        openFile(directoryFiles[next])
    }

    func openPreviousFile() {
        guard !directoryFiles.isEmpty, currentFileIndex > 0 else { return }
        openFile(directoryFiles[currentFileIndex - 1])
    }

    var hasNextFile: Bool { currentFileIndex >= 0 && currentFileIndex < directoryFiles.count - 1 }
    var hasPreviousFile: Bool { currentFileIndex > 0 }

    func closeFile() {
        stopPolling()
        if let p = player {
            mpv_player_stop(p)
        }
        if let url = fileURL {
            url.stopAccessingSecurityScopedResource()
            fileURL = nil
        }
        playbackState = .idle
        currentTime = 0
        duration = 0
        videoWidth = 0
        videoHeight = 0
    }

    func togglePlayPause() {
        guard let p = player, isFileOpen else { return }
        switch playbackState {
        case .playing:
            mpv_player_pause(p)
            playbackState = .paused
        case .paused:
            mpv_player_play(p)
            playbackState = .playing
        case .ended:
            seek(to: 0)
            mpv_player_play(p)
            playbackState = .playing
        case .idle:
            break
        }
    }

    func frameStep() {
        guard let p = player, isFileOpen else { return }
        mpv_player_frame_step(p)
        playbackState = .paused
    }

    func frameBackStep() {
        guard let p = player, isFileOpen else { return }
        mpv_player_frame_back_step(p)
        playbackState = .paused
    }

    func seek(to time: Double) {
        guard let p = player else { return }
        if playbackState == .ended { playbackState = .paused }
        mpv_player_seek(p, time)
        currentTime = time
    }

    func handleMouseMoved(_ location: CGPoint, viewSize: CGSize) {
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
        cameraYaw = nx * maxYaw
        cameraPitch = ny * maxPitch
    }


    func handleScrollWheel(_ deltaY: CGFloat) {
        let factor: Float = 0.1
        zoomFactor *= 1.0 + Float(deltaY) * factor
        let minZoom = 1.0 / maxTanHalf
        zoomFactor = max(minZoom, min(5.0, zoomFactor))
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
            let mpvPlaying = mpv_player_is_paused(p) == 0
            if mpvPlaying && playbackState != .playing {
                playbackState = .playing
            } else if !mpvPlaying && playbackState == .playing {
                playbackState = .paused
            }
        }
        if flags & MPV_PROP_VIDEO_SIZE != 0 {
            videoWidth = Int(mpv_player_get_video_width(p))
            videoHeight = Int(mpv_player_get_video_height(p))
        }
        if flags & MPV_PROP_EOF != 0 {
            playbackState = .ended
        }
    }

    deinit {
        if let p = player {
            mpv_player_destroy(p)
        }
        fileURL?.stopAccessingSecurityScopedResource()
    }
}
