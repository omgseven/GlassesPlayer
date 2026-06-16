import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = VideoPlayerModel()
    @State private var showFileImporter = false
    @State private var showStereoPanel = false
    @State private var showSettings = false
    @State private var isDropTargeted = false
    @State private var isHoveringTransport = false
    @State private var hideTask: Task<Void, Never>?
    @State private var showVolumeOSD = false
    @State private var volumeOSDTask: Task<Void, Never>?
    @State private var playlistExpanded = false
    @AppStorage("playlistMode") private var playlistMode: Int = PlaylistShowMode.manual.rawValue
    @AppStorage("showPlaylistButton") private var showPlaylistButton: Bool = true
    @AppStorage("maxFOVDegrees") private var maxFOVDegrees: Double = 120
    @AppStorage("showControlsOnPause") private var showControlsOnPause: Bool = true
    @AppStorage("autoHideDelay") private var autoHideDelay: Double = 3
    @AppStorage("playMode") private var playMode: Int = PlayMode.stopAfterCurrent.rawValue

    private let videoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg2Video]

    var body: some View {
        mainStack
            .modifier(KeyboardShortcuts(model: model))
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: videoTypes,
                          allowsMultipleSelection: false,
                          onCompletion: handleFileImport)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onChange(of: model.controlsVisible) { _, visible in
                hideTask?.cancel()
                if visible && model.isPlaying { scheduleHide() }
            }
            .onChange(of: model.playbackState) { _, state in
                handlePlaybackStateChange(state)
            }
            .onChange(of: maxFOVDegrees) { _, newValue in
                model.maxTanHalf = tan(Float(newValue / 2.0) * .pi / 180.0)
            }
            .onChange(of: playlistMode) { _, newValue in
                if PlaylistShowMode(rawValue: newValue) == .manual {
                    playlistExpanded = true
                }
            }
            .onAppear {
                model.maxTanHalf = tan(Float(maxFOVDegrees / 2.0) * .pi / 180.0)
            }
    }

    private var mainStack: some View {
        ZStack {
            backgroundLayer
            MetalPlayerView(model: model)
                .ignoresSafeArea()
                .onTapGesture(count: 2) {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .onTapGesture(count: 1) {
                    guard clickToPlayPause else { return }
                    model.togglePlayPause()
                }
            if showStereoPanel {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { showStereoPanel = false }
            }
            transportOverlay
            volumeOSD
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.1))
                    .padding(12)
                    .ignoresSafeArea()
                    .overlay {
                        Label {
                            Text(L10n.Common.dropToPlay)
                        } icon: {
                            Image(systemName: "film")
                        }
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.white)
                    }
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 320, minHeight: 200)
        .overlay(alignment: .trailing) {
            playlistLayer
        }
        .dropDestination(for: URL.self) { urls, _ in
            if let url = urls.first {
                model.openFile(url)
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .onChange(of: model.volume) { _, _ in
            showVolumeOSD = true
            volumeOSDTask?.cancel()
            volumeOSDTask = Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                showVolumeOSD = false
            }
        }
    }

    private var volumeOSD: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .medium))
            Text("\(Int(model.volume))")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
        .opacity(showVolumeOSD ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: showVolumeOSD)
        .allowsHitTesting(false)
    }

    @AppStorage("clickToPlayPause") private var clickToPlayPause: Bool = true

    private func handleFileImport(_ result: Result<[URL], Error>) {
        if case .success(let urls) = result, let url = urls.first {
            model.openFile(url)
        }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if model.isFullScreen {
            Color.black.ignoresSafeArea()
        } else {
            VisualEffectBlur().ignoresSafeArea()
        }
    }

    private func handlePlaybackStateChange(_ state: PlaybackState) {
        switch state {
        case .playing:
            if model.controlsVisible { scheduleHide() }
        case .paused:
            hideTask?.cancel()
            if showControlsOnPause { model.controlsVisible = true }
        case .ended:
            hideTask?.cancel()
            let mode = PlayMode(rawValue: playMode) ?? .stopAfterCurrent
            switch mode {
            case .stopAfterCurrent:
                if showControlsOnPause { model.controlsVisible = true }
            case .loopOne:
                model.seek(to: 0)
                model.togglePlayPause()
            case .playList:
                if model.hasNextFile {
                    model.openNextFile()
                } else {
                    if showControlsOnPause { model.controlsVisible = true }
                }
            case .loopList:
                if model.hasNextFile {
                    model.openNextFile()
                } else {
                    model.seek(to: 0)
                    model.togglePlayPause()
                }
            }
        case .idle:
            hideTask?.cancel()
            model.controlsVisible = true
        }
    }

    // MARK: - Transport Overlay

    private var transportOverlay: some View {
        VStack {
            Spacer()
            transportBar
                .frame(maxWidth: 660)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
                .onHover { hovering in
                    isHoveringTransport = hovering
                    if hovering {
                        hideTask?.cancel()
                    } else if model.controlsVisible && model.isPlaying {
                        scheduleHide()
                    }
                }
        }
        .opacity(model.controlsVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: model.controlsVisible)
    }

    private var transportBar: some View {
        VStack(spacing: 8) {
            controlsRow
            scrubberRow
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        }
    }

    // MARK: - Controls Row

    private var controlsRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                transportButton(icon: "folder", action: { showFileImporter = true })
                VolumeKnob(volume: model.volume)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                transportButton(icon: "backward.end.fill", action: { model.openPreviousFile() })
                    .disabled(!model.hasPreviousFile)

                Button(action: { model.togglePlayPause() }) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!model.isFileOpen)

                transportButton(icon: "forward.end.fill", action: { model.openNextFile() })
                    .disabled(!model.hasNextFile)
            }

            HStack(spacing: 4) {
                Button(action: { showStereoPanel.toggle() }) {
                    stereoIcon
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showStereoPanel, arrowEdge: .bottom) {
                    stereoPanel
                }
                moreMenu
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: - Scrubber Row

    private var scrubberRow: some View {
        HStack(spacing: 10) {
            Text(formatTime(model.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            Slider(
                value: Binding(
                    get: { model.currentTime },
                    set: { model.seek(to: $0) }
                ),
                in: 0...(max(model.duration, 0.01))
            )
            .disabled(!model.isFileOpen)

            Text(formatTime(model.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: - Stereo Panel

    private var stereoPanel: some View {
        VStack(spacing: 14) {
            Text(L10n.Stereo.panelTitle)
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 5) {
                Text(L10n.Stereo.labelSource)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                sourceSegments
            }

            VStack(spacing: 5) {
                Text(L10n.Stereo.labelDisplay)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                displaySegments
                    .opacity(model.sourceLayout.is360 || model.sourceLayout.is2D ? 0.4 : 1)
                    .disabled(model.sourceLayout.is360 || model.sourceLayout.is2D)
            }

            VStack(spacing: 5) {
                Text(L10n.Stereo.labelCamera)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                cameraControlSegments
                    .opacity(model.sourceLayout.is2D ? 0.4 : 1)
                    .disabled(model.sourceLayout.is2D)
            }
        }
        .padding(20)
        .frame(width: 230)
    }

    private var sourceSegments: some View {
        HStack(spacing: 1) {
            segmentButton(isSelected: model.sourceLayout == .mono2D, action: { model.sourceLayout = .mono2D }) {
                Image(systemName: "rectangle.fill")
            }
            segmentButton(isSelected: model.sourceLayout == .sideBySide, action: { model.sourceLayout = .sideBySide }) {
                Image(systemName: "rectangle.split.2x1.fill")
            }
            segmentButton(isSelected: model.sourceLayout == .topBottom, action: { model.sourceLayout = .topBottom }) {
                Image(systemName: "rectangle.split.1x2.fill")
            }
            segmentButton(isSelected: model.sourceLayout == .mono360, action: { model.sourceLayout = .mono360 }) {
                Image(systemName: "circle.circle.fill")
            }
        }
        .padding(2)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var displaySegments: some View {
        let icon = model.sourceLayout.isHorizontal
            ? "rectangle.split.2x1.fill" : "rectangle.split.1x2.fill"
        let horizontal = model.sourceLayout.isHorizontal
        return HStack(spacing: 1) {
            segmentButton(isSelected: model.displayMode == .leftEye, action: { model.displayMode = .leftEye }) {
                Image(systemName: icon)
                    .mask {
                        if horizontal {
                            HStack(spacing: 0) { Color.black; Color.black.opacity(0.25) }
                        } else {
                            VStack(spacing: 0) { Color.black; Color.black.opacity(0.25) }
                        }
                    }
            }
            segmentButton(isSelected: model.displayMode == .rightEye, action: { model.displayMode = .rightEye }) {
                Image(systemName: icon)
                    .mask {
                        if horizontal {
                            HStack(spacing: 0) { Color.black.opacity(0.25); Color.black }
                        } else {
                            VStack(spacing: 0) { Color.black.opacity(0.25); Color.black }
                        }
                    }
            }
            segmentButton(isSelected: model.displayMode == .both, action: { model.displayMode = .both }) {
                Image(systemName: icon)
            }
        }
        .padding(2)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var cameraControlSegments: some View {
        HStack(spacing: 1) {
            segmentButton(isSelected: model.cameraControl == .move, action: { model.cameraControl = .move }) {
                Image(systemName: "cursorarrow.motionlines")
            }
            segmentButton(isSelected: model.cameraControl == .drag, action: { model.cameraControl = .drag }) {
                Image(systemName: "hand.draw")
            }
        }
        .padding(2)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func segmentButton<Content: View>(
        isSelected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .contentShape(Rectangle())
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(0.12))
                            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Playlist Panel

    private var playlistLayer: some View {
        Group {
            let mode = PlaylistShowMode(rawValue: playlistMode) ?? .manual
            if mode == .manual && showPlaylistButton {
                playlistManual
            } else if mode == .auto {
                playlistAuto
            }
        }
    }

    /// Manual mode: floating button + sliding panel, animated as one unit
    private var playlistManual: some View {
        ZStack(alignment: .trailing) {
            // 面板：260px，滑入/滑出
            if playlistExpanded {
                PlaylistPanel(
                    model: model,
                    mode: Binding(
                        get: { PlaylistShowMode(rawValue: playlistMode) ?? .manual },
                        set: { playlistMode = $0.rawValue }
                    )
                )
                .frame(width: 260)
                .frame(maxHeight: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.35), radius: 14, x: -6)
                .transition(.move(edge: .trailing))
            }

            // 悬浮按钮：始终在右边缘，展开时随面板左移
            playlistToggle
                .offset(x: playlistExpanded ? -260 : 0)
        }
        .frame(width: playlistExpanded ? 260 : 32)
        .frame(maxHeight: .infinity)
        .ignoresSafeArea()
        .opacity(model.controlsVisible ? 1 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: playlistExpanded)
        .animation(.easeOut(duration: 0.15), value: model.controlsVisible)
        .allowsHitTesting(model.controlsVisible)
    }

    /// 悬浮展开按钮
    private var playlistToggle: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                playlistExpanded.toggle()
            }
        } label: {
            Image(systemName: "chevron.compact.left")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .rotationEffect(.degrees(playlistExpanded ? 180 : 0))
                .frame(width: 20, height: 44)
                .contentShape(Rectangle())
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 6)
    }

    /// Auto mode: panel slides in/out via offset
    private var playlistAuto: some View {
        ZStack(alignment: .trailing) {
            PlaylistPanel(
                model: model,
                mode: Binding(
                    get: { PlaylistShowMode(rawValue: playlistMode) ?? .manual },
                    set: { playlistMode = $0.rawValue }
                )
            )
            .frame(width: 260)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            )
            .offset(x: playlistExpanded ? 0 : 280)
        }
        .frame(width: 260)
        .clipped()
        .shadow(color: .black.opacity(0.35), radius: 14, x: -6)
        .onContinuousHover { phase in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                switch phase {
                case .active(let location):
                    // 只在右侧 24px 内触发
                    if location.x > 236 {
                        playlistExpanded = true
                    }
                case .ended:
                    if PlaylistShowMode(rawValue: playlistMode) == .auto {
                        playlistExpanded = false
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Helpers

    @ViewBuilder
    private var stereoIcon: some View {
        if model.sourceLayout.is2D {
            Image(systemName: "rectangle.fill")
        } else if model.sourceLayout.is360 {
            Image(systemName: "circle.circle.fill")
        } else if model.displayMode == .both {
            Image(systemName: "visionpro.fill")
        } else {
            let fillFirst = model.displayMode == .leftEye
            let horizontal = model.sourceLayout.isHorizontal
            ZStack {
                Image(systemName: "visionpro.fill")
                    .mask { splitMask(showFirst: fillFirst, horizontal: horizontal) }
                Image(systemName: "visionpro")
                    .mask { splitMask(showFirst: !fillFirst, horizontal: horizontal) }
            }
        }
    }

    @ViewBuilder
    private func splitMask(showFirst: Bool, horizontal: Bool) -> some View {
        let visible = Color.black
        let hidden = Color.black.opacity(0.25)
        if horizontal {
            HStack(spacing: 0) { if showFirst { visible; hidden } else { hidden; visible } }
        } else {
            VStack(spacing: 0) { if showFirst { visible; hidden } else { hidden; visible } }
        }
    }

    @AppStorage("playbackSpeed") private var playbackSpeed: Double = 1.0

    private var moreMenu: some View {
        Menu {
            Button { showSettings.toggle() } label: {
                Label { Text(L10n.Menu.settings) } icon: { Image(systemName: "wrench.adjustable.fill") }
            }
            Picker(selection: $playMode) {
                Label { Text(L10n.PlayMode.stopAfterCurrent) } icon: { Image(systemName: "stop.circle") }
                    .tag(PlayMode.stopAfterCurrent.rawValue)
                Label { Text(L10n.PlayMode.loopOne) } icon: { Image(systemName: "repeat.1") }
                    .tag(PlayMode.loopOne.rawValue)
                Label { Text(L10n.PlayMode.playAll) } icon: { Image(systemName: "text.line.first.and.arrowtriangle.forward") }
                    .tag(PlayMode.playList.rawValue)
                Label { Text(L10n.PlayMode.loopAll) } icon: { Image(systemName: "repeat") }
                    .tag(PlayMode.loopList.rawValue)
            } label: {
                Label { Text(L10n.Menu.playMode) } icon: { Image(systemName: "flag.pattern.checkered") }
            }
            Picker(selection: $playbackSpeed) {
                Text("1×").tag(1.0)
                Text("1.1×").tag(1.1)
                Text("1.2×").tag(1.2)
                Text("1.3×").tag(1.3)
                Text("1.5×").tag(1.5)
                Text("1.7×").tag(1.7)
                Text("2×").tag(2.0)
                Text("2.3×").tag(2.3)
                Text("2.6×").tag(2.6)
                Text("3×").tag(3.0)
            } label: {
                Label { Text(L10n.Menu.playbackSpeed) } icon: { Image(systemName: "hare.fill") }
            }
        } label: {
            Image(systemName: "square.3.layers.3d.top.filled")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 32, height: 32)
        .onChange(of: playbackSpeed) { _, speed in
            model.setSpeed(speed)
        }
    }

    private func transportButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(autoHideDelay))
            guard !Task.isCancelled, !isHoveringTransport else { return }
            model.controlsVisible = false
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Metal Player View (NSViewRepresentable)

struct MetalPlayerView: NSViewRepresentable {
    var model: VideoPlayerModel

    func makeNSView(context: Context) -> PlayerMetalView {
        let view = PlayerMetalView(frame: .zero, player: model.player)
        view.model = model

        view.onMouseMoved = { [weak model] point, size in
            model?.handleMouseMoved(point, viewSize: size)
        }
        view.onScrollWheel = { [weak model] delta in
            model?.handleScrollWheel(delta)
        }

        return view
    }

    func updateNSView(_ nsView: PlayerMetalView, context: Context) {}
}

// MARK: - Keyboard Shortcuts

struct KeyboardShortcuts: ViewModifier {
    var model: VideoPlayerModel

    func body(content: Content) -> some View {
        content
            .onKeyPress(.space) {
                model.togglePlayPause()
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard model.isFileOpen else { return .ignored }
                model.seek(to: max(0, model.currentTime - 5))
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard model.isFileOpen else { return .ignored }
                model.seek(to: min(model.duration, model.currentTime + 5))
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: ",<")) { _ in
                model.frameBackStep()
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: ".>")) { _ in
                model.frameStep()
                return .handled
            }
    }
}

// MARK: - Visual Effect Background

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Volume Knob

struct VolumeKnob: View {
    var volume: Double

    var body: some View {
        Image(systemName: "speaker.circle", variableValue: volume / 100)
            .symbolVariableValueMode(.draw)
            .font(.system(size: 17, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 32, height: 32)
    }
}

#Preview {
    ContentView()
}
