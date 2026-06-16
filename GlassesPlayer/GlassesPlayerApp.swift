import SwiftUI

@main
struct GlassesPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // 进入 SwiftUI Scene 之前应用用户选择的语言（覆盖 AppleLanguages）。
        AppLanguage.applyStoredSelection()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .pasteboard) {}
            CommandGroup(replacing: .textEditing) {}
            CommandGroup(replacing: .textFormatting) {}
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(replacing: .help) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "clickToPlayPause": true,
            "autoHideDelay": 3.0,
            "rememberProgress": true,
            "rememberMode": true,
            "showPlaylistButton": true,
            "playlistMode": 0,
        ])
        DispatchQueue.main.async {
            self.removeUnwantedMenus()
        }
    }

    private func removeUnwantedMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // 同时按英文与本地化标题匹配，避免中文系统下匹配失败。
        let englishTitles = ["View", "Window"]
        let removeTitles: Set<String> = Set(
            englishTitles + englishTitles.map {
                NSLocalizedString($0, tableName: nil, bundle: .main, value: $0, comment: "")
            }
        )
        for item in mainMenu.items where removeTitles.contains(item.title) {
            mainMenu.removeItem(item)
        }
    }
}
