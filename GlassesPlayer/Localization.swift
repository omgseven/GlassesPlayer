import Foundation
import SwiftUI

// MARK: - L10n 命名空间
//
// 所有 UI 文案的强类型入口。新增文案时：
// 1. 在 Localizable.xcstrings 增加 key 与中英翻译；
// 2. 在此文件对应分组下补一个 LocalizedStringResource 常量。
// SwiftUI 的 Text/Label/Button(_:) 等可以直接接收 LocalizedStringResource。
// 拼装到 .help() / String 上下文时，使用 String(localized:) 取值。

enum L10n {
    enum Common {
        static let dropToPlay = LocalizedStringResource("drop_to_play")
    }

    enum Stereo {
        static let panelTitle = LocalizedStringResource("stereo_panel_title")
        static let labelSource = LocalizedStringResource("stereo_label_source")
        static let labelDisplay = LocalizedStringResource("stereo_label_display")
        static let labelCamera = LocalizedStringResource("stereo_label_camera")
    }

    enum Menu {
        static let settings = LocalizedStringResource("menu_settings")
        static let playMode = LocalizedStringResource("menu_play_mode")
        static let playbackSpeed = LocalizedStringResource("menu_playback_speed")
    }

    enum PlayMode {
        static let stopAfterCurrent = LocalizedStringResource("play_mode_stop_after_current")
        static let loopOne = LocalizedStringResource("play_mode_loop_one")
        static let playAll = LocalizedStringResource("play_mode_play_all")
        static let loopAll = LocalizedStringResource("play_mode_loop_all")
    }

    enum Settings {
        static let title = LocalizedStringResource("settings_title")

        static let sectionProjection = LocalizedStringResource("settings_section_projection")
        static let sectionToolbar = LocalizedStringResource("settings_section_toolbar")
        static let sectionInteraction = LocalizedStringResource("settings_section_interaction")
        static let sectionPlaybackMemory = LocalizedStringResource("settings_section_playback_memory")
        static let sectionPlaylist = LocalizedStringResource("settings_section_playlist")
        static let sectionAdvanced = LocalizedStringResource("settings_section_advanced")
        static let sectionLanguage = LocalizedStringResource("settings_section_language")

        static let fovHint = LocalizedStringResource("settings_fov_hint")
        static let cursorOpacity = LocalizedStringResource("settings_cursor_opacity")
        static let showToolbarPaused = LocalizedStringResource("settings_show_toolbar_paused")
        static let autoHideDelay = LocalizedStringResource("settings_auto_hide_delay")
        static let clickToPlay = LocalizedStringResource("settings_click_to_play")
        static let naturalScroll = LocalizedStringResource("settings_natural_scroll")
        static let dragFollowsMouse = LocalizedStringResource("settings_drag_follows_mouse")
        static let rememberProgress = LocalizedStringResource("settings_remember_progress")
        static let rememberMode = LocalizedStringResource("settings_remember_mode")
        static let showPlaylistButton = LocalizedStringResource("settings_show_playlist_button")
        static let openLogDir = LocalizedStringResource("settings_open_log_dir")

        static let languageSystem = LocalizedStringResource("settings_language_system")
        static let languageEnglish = LocalizedStringResource("settings_language_english")
        static let languageChinese = LocalizedStringResource("settings_language_chinese")
        static let languageJapanese = LocalizedStringResource("settings_language_japanese")
        static let languageKorean = LocalizedStringResource("settings_language_korean")
        static let languageFrench = LocalizedStringResource("settings_language_french")
        static let languageRussian = LocalizedStringResource("settings_language_russian")
        static let languageGerman = LocalizedStringResource("settings_language_german")
        static let languageRestartHint = LocalizedStringResource("settings_language_restart_hint")
        static let restartNow = LocalizedStringResource("settings_restart_now")
    }

    enum Playlist {
        static let title = LocalizedStringResource("playlist_title")
        static let modeManualHelp = LocalizedStringResource("playlist_mode_manual_help")
        static let modeAutoHelp = LocalizedStringResource("playlist_mode_auto_help")
        static let emptyTitle = LocalizedStringResource("playlist_empty_title")
        static let emptySubtitle = LocalizedStringResource("playlist_empty_subtitle")
    }
}

// MARK: - 取本地化 String（用于 .help() 等需要 String 的场景）

extension LocalizedStringResource {
    var localized: String { String(localized: self) }
}

// MARK: - 应用语言选择
//
// 持久化值写入 UserDefaults["appLanguage"]：
//   - "" 或缺省 = 跟随系统
//   - "en" / "zh-Hans" = 强制使用对应语言
// 实际生效通过覆盖 UserDefaults["AppleLanguages"] 实现，需重启应用。

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case chinese = "zh-Hans"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case russian = "ru"
    case german = "de"

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .system:   return L10n.Settings.languageSystem
        case .english:  return L10n.Settings.languageEnglish
        case .chinese:  return L10n.Settings.languageChinese
        case .japanese: return L10n.Settings.languageJapanese
        case .korean:   return L10n.Settings.languageKorean
        case .french:   return L10n.Settings.languageFrench
        case .russian:  return L10n.Settings.languageRussian
        case .german:   return L10n.Settings.languageGerman
        }
    }

    /// 在 App 启动早期调用，把用户选择写入 AppleLanguages，使 SwiftUI/系统组件按所选语言加载资源。
    static func applyStoredSelection() {
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        guard let lang = AppLanguage(rawValue: raw), lang != .system else {
            // 跟随系统：移除我们的覆盖，恢复系统默认
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            return
        }
        UserDefaults.standard.set([lang.rawValue], forKey: "AppleLanguages")
    }
}
