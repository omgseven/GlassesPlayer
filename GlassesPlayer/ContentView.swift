import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = VideoPlayerModel()
    @State private var showFileImporter = false
    @State private var showStereoPanel = false
    @State private var showSettings = false
    @State private var isHoveringTransport = false
    @State private var hideTask: Task<Void, Never>?
    @AppStorage("maxFOVDegrees") private var maxFOVDegrees: Double = 120
    @AppStorage("showControlsOnPause") private var showControlsOnPause: Bool = true

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
            .onChange(of: model.isPlaying) { _, playing in
                handlePlayingChange(playing)
            }
            .onChange(of: maxFOVDegrees) { _, newValue in
                model.maxTanHalf = tan(Float(newValue / 2.0) * .pi / 180.0)
            }
            .onAppear {
                model.maxTanHalf = tan(Float(maxFOVDegrees / 2.0) * .pi / 180.0)
            }
    }

    private var mainStack: some View {
        ZStack {
            backgroundLayer
            MetalPlayerView(model: model).ignoresSafeArea()
            transportOverlay
        }
        .frame(minWidth: 320, minHeight: 200)
    }

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

    private func handlePlayingChange(_ playing: Bool) {
        if !playing {
            hideTask?.cancel()
            if showControlsOnPause { model.controlsVisible = true }
        } else if model.controlsVisible {
            scheduleHide()
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
                transportButton(icon: "gearshape", action: { showSettings.toggle() })
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
            Text("Stereo & source")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 5) {
                Text("SOURCE")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                sourceSegments
            }

            VStack(spacing: 5) {
                Text("DISPLAY")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                displaySegments
                    .opacity(model.sourceLayout == 2 ? 0.4 : 1)
                    .disabled(model.sourceLayout == 2)
            }
        }
        .padding(20)
        .frame(width: 210)
    }

    private var sourceSegments: some View {
        HStack(spacing: 1) {
            segmentButton(isSelected: model.sourceLayout == 0, action: { model.sourceLayout = 0 }) {
                Image(systemName: "rectangle.split.2x1.fill")
            }
            segmentButton(isSelected: model.sourceLayout == 1, action: { model.sourceLayout = 1 }) {
                Image(systemName: "rectangle.split.1x2.fill")
            }
            segmentButton(isSelected: model.sourceLayout == 2, action: { model.sourceLayout = 2 }) {
                Image(systemName: "circle.circle.fill")
            }
        }
        .padding(2)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var displaySegments: some View {
        let icon = model.sourceLayout == 0
            ? "rectangle.split.2x1.fill" : "rectangle.split.1x2.fill"
        let horizontal = model.sourceLayout == 0
        return HStack(spacing: 1) {
            segmentButton(isSelected: model.displayMode == 0, action: { model.displayMode = 0 }) {
                Image(systemName: icon)
                    .mask {
                        if horizontal {
                            HStack(spacing: 0) { Color.black; Color.black.opacity(0.25) }
                        } else {
                            VStack(spacing: 0) { Color.black; Color.black.opacity(0.25) }
                        }
                    }
            }
            segmentButton(isSelected: model.displayMode == 1, action: { model.displayMode = 1 }) {
                Image(systemName: icon)
                    .mask {
                        if horizontal {
                            HStack(spacing: 0) { Color.black.opacity(0.25); Color.black }
                        } else {
                            VStack(spacing: 0) { Color.black.opacity(0.25); Color.black }
                        }
                    }
            }
            segmentButton(isSelected: model.displayMode == 2, action: { model.displayMode = 2 }) {
                Image(systemName: icon)
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

    // MARK: - Helpers

    @ViewBuilder
    private var stereoIcon: some View {
        if model.sourceLayout == 2 {
            Image(systemName: "globe")
        } else if model.displayMode == 2 {
            Image(systemName: "visionpro.fill")
        } else {
            let fillFirst = model.displayMode == 0
            let horizontal = model.sourceLayout == 0
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
            try? await Task.sleep(for: .seconds(3))
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

#Preview {
    ContentView()
}
