import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = VideoPlayerModel()
    @State private var showFileImporter = false
    @State private var showStereoPanel = false
    @State private var controlsVisible = true
    @State private var isHoveringTransport = false
    @State private var hideTask: Task<Void, Never>?
    @AppStorage("maxFOVDegrees") private var maxFOVDegrees: Double = 120

    var body: some View {
        ZStack {
            VisualEffectBlur()
                .ignoresSafeArea()

            OpenGLPlayerView(model: model)
                .ignoresSafeArea()

            transportOverlay
        }
        .frame(minWidth: 640, minHeight: 400)
        .onKeyPress(.space) {
            model.togglePlayPause()
            return .handled
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg2Video],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.openFile(url)
            }
        }
        .onChange(of: model.mouseActivityTrigger) { _, _ in
            showControlsAndResetTimer()
        }
        .onChange(of: model.isPlaying) { _, playing in
            if !playing {
                controlsVisible = true
                hideTask?.cancel()
            } else {
                scheduleHide()
            }
        }
        .onChange(of: maxFOVDegrees) { _, newValue in
            model.maxTanHalf = tan(Float(newValue / 2.0) * .pi / 180.0)
        }
        .onAppear {
            model.maxTanHalf = tan(Float(maxFOVDegrees / 2.0) * .pi / 180.0)
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
                        controlsVisible = true
                        hideTask?.cancel()
                    } else if model.isPlaying {
                        scheduleHide()
                    }
                }
        }
        .opacity(controlsVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: controlsVisible)
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
                Button(action: { showStereoPanel.toggle() }) {
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showStereoPanel, arrowEdge: .bottom) {
                    stereoPanel
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                transportButton(icon: "gobackward.10", action: { model.seek(to: max(0, model.currentTime - 10)) })
                    .disabled(!model.isFileOpen)

                Button(action: { model.togglePlayPause() }) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!model.isFileOpen)

                transportButton(icon: "goforward.10", action: { model.seek(to: min(model.duration, model.currentTime + 10)) })
                    .disabled(!model.isFileOpen)
            }

            HStack(spacing: 4) {
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Stereo & source")
                    .font(.headline)
                Spacer()
                Button(action: { showStereoPanel = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("DISPLAY MODE")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $model.displayMode) {
                    Text("Left only").tag(0)
                    Text("Both").tag(2)
                    Text("Right only").tag(1)
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("SOURCE FORMAT")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $model.sourceLayout) {
                    Text("Left-Right").tag(0)
                    Text("Top-Bottom").tag(1)
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    // MARK: - Helpers

    private func transportButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func showControlsAndResetTimer() {
        controlsVisible = true
        hideTask?.cancel()
        if model.isPlaying {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !isHoveringTransport else { return }
            controlsVisible = false
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - OpenGL Player View (NSViewRepresentable)

struct OpenGLPlayerView: NSViewRepresentable {
    var model: VideoPlayerModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerOpenGLView {
        let view = PlayerOpenGLView(frame: .zero, player: model.player)
        view.model = model

        view.onMouseMoved = { [weak model] point, size in
            model?.handleMouseMoved(point, viewSize: size)
        }
        view.onScrollWheel = { [weak model] delta in
            model?.handleScrollWheel(delta)
        }

        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: PlayerOpenGLView, context: Context) {
        // The draw loop reads uniforms from model directly via the coordinator
    }

    class Coordinator {
        weak var view: PlayerOpenGLView?
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
