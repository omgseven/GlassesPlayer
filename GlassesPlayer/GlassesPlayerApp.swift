import SwiftUI

@main
struct GlassesPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 760)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
        }
    }
}
