import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("maxFOVDegrees") private var maxFOVDegrees: Double = 120
    @AppStorage("showControlsOnPause") private var showControlsOnPause: Bool = true

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
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Maximum Field of View")
                            Spacer()
                            Text("\(Int(maxFOVDegrees))\u{00B0}")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $maxFOVDegrees, in: 60...150, step: 5) {
                            Text("Max FOV")
                        }
                        Text("The maximum viewing angle when fully zoomed out. Higher values show more content but may introduce edge stretching.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Section("Controls") {
                    Toggle("Show toolbar when paused", isOn: $showControlsOnPause)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 320)
    }
}

#Preview {
    SettingsView()
}
