import SwiftUI

struct SettingsView: View {
    @AppStorage("maxFOVDegrees") private var maxFOVDegrees: Double = 120

    var body: some View {
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
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 180)
        .navigationTitle("Settings")
    }
}

#Preview {
    SettingsView()
}
