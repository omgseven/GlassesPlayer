import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("maxFOVDegrees") private var maxFOVDegrees: Double = 120
    @AppStorage("showControlsOnPause") private var showControlsOnPause: Bool = true
    @AppStorage("naturalScrollVolume") private var naturalScrollVolume: Bool = false
    @AppStorage("dragFollowsMouse") private var dragFollowsMouse: Bool = false
    @AppStorage("autoHideDelay") private var autoHideDelay: Double = 3
    @AppStorage("clickToPlayPause") private var clickToPlayPause: Bool = true
    @AppStorage("rememberProgress") private var rememberProgress: Bool = true
    @AppStorage("rememberMode") private var rememberMode: Bool = true
    @AppStorage("showPlaylistButton") private var showPlaylistButton: Bool = true
    @AppStorage("appLanguage") private var appLanguageRaw: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.Settings.title)
                    .font(.title2.bold())
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Form {
                Section(String(localized: L10n.Settings.sectionProjection)) {
                    VStack(spacing: 16) {
                        FOVSectorControl(degrees: $maxFOVDegrees)
                            .frame(height: 120)
                        Text(L10n.Settings.fovHint)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }

                Section(String(localized: L10n.Settings.sectionToolbar)) {
                    Toggle(isOn: $showControlsOnPause) {
                        Text(L10n.Settings.showToolbarPaused)
                    }
                    HStack {
                        Text(L10n.Settings.autoHideDelay)
                        Spacer()
                        Text("\(String(format: "%.1f", autoHideDelay))s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $autoHideDelay, in: 1...10, step: 0.5)
                }

                Section(String(localized: L10n.Settings.sectionInteraction)) {
                    Toggle(isOn: $clickToPlayPause) { Text(L10n.Settings.clickToPlay) }
                    Toggle(isOn: $naturalScrollVolume) { Text(L10n.Settings.naturalScroll) }
                    Toggle(isOn: $dragFollowsMouse) { Text(L10n.Settings.dragFollowsMouse) }
                }

                Section(String(localized: L10n.Settings.sectionPlaybackMemory)) {
                    Toggle(isOn: $rememberProgress) { Text(L10n.Settings.rememberProgress) }
                    Toggle(isOn: $rememberMode) { Text(L10n.Settings.rememberMode) }
                }

                Section(String(localized: L10n.Settings.sectionPlaylist)) {
                    Toggle(isOn: $showPlaylistButton) { Text(L10n.Settings.showPlaylistButton) }
                }

                Section(String(localized: L10n.Settings.sectionLanguage)) {
                    Picker(selection: $appLanguageRaw) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    } label: {
                        Text(L10n.Settings.sectionLanguage)
                    }
                    HStack {
                        Text(L10n.Settings.languageRestartHint)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button(String(localized: L10n.Settings.restartNow)) {
                            relaunchApp()
                        }
                        .controlSize(.small)
                    }
                }

                Section(String(localized: L10n.Settings.sectionAdvanced)) {
                    Button(String(localized: L10n.Settings.openLogDir)) {
                        let path = String(cString: mpv_player_get_log_dir())
                        let url = URL(fileURLWithPath: path, isDirectory: true)
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 620)
    }

    private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        // 确保 UserDefaults 已写入磁盘
        UserDefaults.standard.synchronize()
        // 将重启逻辑放入后台子 shell，I/O 全部重定向到 /dev/null，
        // 使其完全脱离父进程（避免父进程 exit 后子 shell 因管道断裂而终止）
        let script = "(while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"\(url.path)\") </dev/null >/dev/null 2>&1 &"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
        // 强制退出：bypass terminate 流程，避免 sheet/窗口阻止退出
        exit(0)
    }
}

struct FOVSectorControl: View {
    @Binding var degrees: Double

    private let minDegrees: Double = 60
    private let maxDegrees: Double = 150
    private let rayLength: CGFloat = 90

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height - 10)
            let halfAngle = degrees / 2

            ZStack {
                sectorFill(center: center, halfAngle: halfAngle)
                sectorStroke(center: center, halfAngle: halfAngle)
                arcTicks(center: center)
                degreesLabel(center: center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                degrees = 120
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let dx = value.location.x - center.x
                        let dy = center.y - value.location.y
                        guard dy > 5 else { return }
                        let angle = atan2(abs(dx), dy) * 2 * 180 / .pi
                        let snapped = (angle / 5).rounded() * 5
                        degrees = min(maxDegrees, max(minDegrees, snapped))
                    }
            )
        }
    }

    private func sectorFill(center: CGPoint, halfAngle: Double) -> some View {
        Path { path in
            path.move(to: center)
            path.addArc(center: center, radius: rayLength,
                        startAngle: .degrees(-90 - halfAngle),
                        endAngle: .degrees(-90 + halfAngle),
                        clockwise: false)
            path.closeSubpath()
        }
        .fill(.blue.opacity(0.12))
    }

    private func sectorStroke(center: CGPoint, halfAngle: Double) -> some View {
        Path { path in
            let startAngle = Angle.degrees(-90 - halfAngle)
            let endAngle = Angle.degrees(-90 + halfAngle)
            let p1 = CGPoint(
                x: center.x + rayLength * cos(CGFloat(startAngle.radians)),
                y: center.y + rayLength * sin(CGFloat(startAngle.radians))
            )
            let p2 = CGPoint(
                x: center.x + rayLength * cos(CGFloat(endAngle.radians)),
                y: center.y + rayLength * sin(CGFloat(endAngle.radians))
            )
            path.move(to: p1)
            path.addLine(to: center)
            path.addLine(to: p2)
            path.addArc(center: center, radius: rayLength,
                        startAngle: endAngle, endAngle: startAngle,
                        clockwise: true)
        }
        .stroke(.blue.opacity(0.6), lineWidth: 1.5)
    }

    private func arcTicks(center: CGPoint) -> some View {
        Canvas { ctx, _ in
            for tick in stride(from: minDegrees, through: maxDegrees, by: 5) {
                let half = tick / 2
                let isMajor = tick.truncatingRemainder(dividingBy: 15) == 0
                let r: CGFloat = isMajor ? 1.5 : 0.75
                for sign in [-1.0, 1.0] {
                    let angle = Angle.degrees(-90 + sign * half)
                    let pt = CGPoint(
                        x: center.x + rayLength * cos(CGFloat(angle.radians)),
                        y: center.y + rayLength * sin(CGFloat(angle.radians))
                    )
                    let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.secondary.opacity(0.5)))
                }
            }
        }
    }

    private func degreesLabel(center: CGPoint) -> some View {
        Text("\(Int(degrees))°")
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .foregroundStyle(.primary)
            .position(x: center.x, y: center.y - rayLength / 2.5)
    }
}

#Preview {
    SettingsView()
}
