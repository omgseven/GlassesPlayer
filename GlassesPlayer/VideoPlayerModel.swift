import Foundation
import Observation
import QuartzCore
import AppKit

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
    case mono2D = 3

    var is360: Bool { self == .mono360 }
    var isHorizontal: Bool { self == .sideBySide }
    var is2D: Bool { self == .mono2D }
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

    let camera = CameraController()

    var controlsVisible = true
    var isFullScreen = false
    var displayMode: DisplayMode = .leftEye
    var sourceLayout: SourceLayout = .sideBySide {
        didSet {
            camera.resetForLayout(sourceLayout)
        }
    }

    var volume: Double = 100

    func setVolume(_ value: Double) {
        volume = min(100, max(0, value))
        if let p = player { mpv_player_set_volume(p, volume) }
    }

    func setSpeed(_ speed: Double) {
        if let p = player { mpv_player_set_speed(p, speed) }
    }

    @ObservationIgnored
    private var _playMode: Int {
        get { AppSettings.shared.playMode }
    }

    @ObservationIgnored nonisolated(unsafe) var player: OpaquePointer?
    private var pollTimer: Timer?
    private var saveTimer: Timer?
    private var pendingSeekTime: Double?
    private var pendingMetadataDetect = false
    private var filenameDetected = false
    private let memory = PlaybackMemory()
    @ObservationIgnored nonisolated(unsafe) private var fileURL: URL?
    let playlist = PlaylistManager()

    var currentFileURL: URL? { fileURL }

    init() {
        player = mpv_player_create()
        Logger.info("VideoPlayerModel initialized")
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.savePlaybackMemory()
            }
        }
    }

    func openFile(_ url: URL) {
        Logger.info("Opening file: \(url.lastPathComponent)")
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
        playlist.scanDirectory(for: url)

        // Restore saved playback state
        if let record = memory.load(url: url) {
            let rememberMode = AppSettings.shared.rememberMode
            let rememberProgress = AppSettings.shared.rememberProgress

            if rememberMode {
                if let layout = SourceLayout(rawValue: record.sourceLayout) {
                    sourceLayout = layout
                }
                if let mode = DisplayMode(rawValue: record.displayMode) {
                    displayMode = mode
                }
            }
            if rememberProgress && record.progress > 0 && record.duration > 0 && record.progress < record.duration - 3 {
                pendingSeekTime = record.progress
            }
            filenameDetected = false
            pendingMetadataDetect = false
        } else {
            // No history — try auto-detection
            if let detected = VideoTypeDetector.detectFromFilename(url.lastPathComponent) {
                sourceLayout = detected
                filenameDetected = true
                pendingMetadataDetect = false
                Logger.info("Auto-detected layout from filename: \(detected)")
            } else {
                filenameDetected = false
                pendingMetadataDetect = true
            }
        }
    }


    // MARK: - Playback End Handling

    func openFile(at index: Int) {
        guard let url = playlist.fileURL(at: index) else { return }
        openFile(url)
    }

    func openNextFile() {
        guard let url = playlist.nextFileURL() else { return }
        openFile(url)
    }

    func openPreviousFile() {
        guard let url = playlist.previousFileURL() else { return }
        openFile(url)
    }

    var hasNextFile: Bool { playlist.hasNextFile }
    var hasPreviousFile: Bool { playlist.hasPreviousFile }

    func closeFile() {
        Logger.info("Closing file: \(fileURL?.lastPathComponent ?? "nil")")
        savePlaybackMemory()
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
        camera.handleMouseMoved(location, viewSize: viewSize, sourceLayout: sourceLayout)
    }

    func handleScrollWheel(_ deltaY: CGFloat) {
        camera.handleScrollWheel(deltaY, sourceLayout: sourceLayout)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollMPVEvents()
            }
        }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.savePlaybackMemory()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        saveTimer?.invalidate()
        saveTimer = nil
    }

    private func pollMPVEvents() {
        guard let p = player else { return }
        let flags = mpv_player_poll_events(p)
        if flags == 0 { return }

        if flags & MPV_PROP_DURATION != 0 {
            duration = mpv_player_get_duration(p)
            if let t = pendingSeekTime, duration > 0 {
                pendingSeekTime = nil
                if t > 0 && t < duration - 3 {
                    seek(to: t)
                }
            }
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

            // Deferred metadata detection — only when filename didn't match
            if pendingMetadataDetect {
                pendingMetadataDetect = false
                if let cStr = mpv_player_get_stereo_mode(p) {
                    let mode = String(cString: cStr)
                    if let detected = VideoTypeDetector.detectFromMetadata(stereoMode: mode) {
                        sourceLayout = detected
                        Logger.info("Auto-detected layout from metadata: \(detected)")
                    }
                }
            }
        }
        if flags & MPV_PROP_EOF != 0 {
            handlePlaybackEnd()
        }
    }

    // MARK: - Playback End Handling

    private func handlePlaybackEnd() {
        let mode = PlayMode(rawValue: _playMode) ?? .stopAfterCurrent
        Logger.info("Playback ended, mode: \(mode)")
        switch mode {
        case .stopAfterCurrent:
            playbackState = .ended
        case .loopOne:
            seek(to: 0)
            if let p = player {
                mpv_player_play(p)
                playbackState = .playing
            }
        case .playList:
            if hasNextFile {
                openNextFile()
            } else {
                playbackState = .ended
            }
        case .loopList:
            if hasNextFile {
                openNextFile()
            } else if let first = playlist.firstFileURL() {
                openFile(first)
            } else {
                seek(to: 0)
                if let p = player {
                    mpv_player_play(p)
                    playbackState = .playing
                }
            }
        }
    }

    private func savePlaybackMemory() {
        guard let url = fileURL, isFileOpen, currentTime > 0, duration > 0 else { return }
        memory.save(url: url, progress: currentTime, duration: duration,
                    sourceLayout: sourceLayout, displayMode: displayMode)
    }

    deinit {
        if let p = player {
            mpv_player_destroy(p)
        }
        fileURL?.stopAccessingSecurityScopedResource()
    }
}
