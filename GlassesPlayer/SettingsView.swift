import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("maxFOVDegrees") private var maxFOVDegrees: Double = 120
    @AppStorage("showControlsOnPause") private var showControlsOnPause: Bool = true
    @AppStorage("naturalScrollVolume") private var naturalScrollVolume: Bool = false
    @AppStorage("dragFollowsMouse") private var dragFollowsMouse: Bool = false
    @AppStorage("autoHideDelay") private var autoHideDelay: Double = 3
    @AppStorage("clickToPlayPause") private var clickToPlayPause: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
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
                Section("Projection") {
                    VStack(spacing: 16) {
                        FOVSectorControl(degrees: $maxFOVDegrees)
                            .frame(height: 120)
                        Text("Maximum field of view when fully zoomed out (double-click to reset)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Toolbar") {
                    Toggle("Show toolbar when paused", isOn: $showControlsOnPause)
                    HStack {
                        Text("Auto-hide delay")
                        Spacer()
                        Text("\(String(format: "%.1f", autoHideDelay))s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $autoHideDelay, in: 1...10, step: 0.5)
                }

                Section("Interaction") {
                    Toggle("Single click to play/pause", isOn: $clickToPlayPause)
                    Toggle("Natural scroll direction for volume", isOn: $naturalScrollVolume)
                    Toggle("360° drag follows mouse direction", isOn: $dragFollowsMouse)
                }

                Section("Advanced") {
                    Button("Open Log Directory") {
                        let path = String(cString: mpv_player_get_log_dir())
                        let url = URL(fileURLWithPath: path, isDirectory: true)
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 520)
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
