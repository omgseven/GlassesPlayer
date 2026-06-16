import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    var maxFOVDegrees: Double {
        didSet { UserDefaults.standard.set(maxFOVDegrees, forKey: "maxFOVDegrees") }
    }
    var autoHideDelay: Double {
        didSet { UserDefaults.standard.set(autoHideDelay, forKey: "autoHideDelay") }
    }
    var clickToPlayPause: Bool {
        didSet { UserDefaults.standard.set(clickToPlayPause, forKey: "clickToPlayPause") }
    }
    var showControlsOnPause: Bool {
        didSet { UserDefaults.standard.set(showControlsOnPause, forKey: "showControlsOnPause") }
    }
    var playMode: Int {
        didSet { UserDefaults.standard.set(playMode, forKey: "playMode") }
    }
    var playlistMode: Int {
        didSet { UserDefaults.standard.set(playlistMode, forKey: "playlistMode") }
    }
    var showPlaylistButton: Bool {
        didSet { UserDefaults.standard.set(showPlaylistButton, forKey: "showPlaylistButton") }
    }
    var naturalScrollVolume: Bool {
        didSet { UserDefaults.standard.set(naturalScrollVolume, forKey: "naturalScrollVolume") }
    }
    var dragFollowsMouse: Bool {
        didSet { UserDefaults.standard.set(dragFollowsMouse, forKey: "dragFollowsMouse") }
    }
    var rememberProgress: Bool {
        didSet { UserDefaults.standard.set(rememberProgress, forKey: "rememberProgress") }
    }
    var rememberMode: Bool {
        didSet { UserDefaults.standard.set(rememberMode, forKey: "rememberMode") }
    }
    var playbackSpeed: Double {
        didSet { UserDefaults.standard.set(playbackSpeed, forKey: "playbackSpeed") }
    }
    var appLanguage: String {
        didSet { UserDefaults.standard.set(appLanguage, forKey: "appLanguage") }
    }
    var cursorOpacity: Double {
        didSet { UserDefaults.standard.set(cursorOpacity, forKey: "cursorOpacity") }
    }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "maxFOVDegrees": 120.0,
            "autoHideDelay": 3.0,
            "clickToPlayPause": true,
            "showControlsOnPause": true,
            "playMode": 0,
            "playlistMode": 0,
            "showPlaylistButton": true,
            "naturalScrollVolume": false,
            "dragFollowsMouse": false,
            "rememberProgress": true,
            "rememberMode": true,
            "playbackSpeed": 1.0,
            "appLanguage": "",
            "cursorOpacity": 45.0
        ])

        maxFOVDegrees = d.double(forKey: "maxFOVDegrees")
        autoHideDelay = d.double(forKey: "autoHideDelay")
        clickToPlayPause = d.bool(forKey: "clickToPlayPause")
        showControlsOnPause = d.bool(forKey: "showControlsOnPause")
        playMode = d.integer(forKey: "playMode")
        playlistMode = d.integer(forKey: "playlistMode")
        showPlaylistButton = d.bool(forKey: "showPlaylistButton")
        naturalScrollVolume = d.bool(forKey: "naturalScrollVolume")
        dragFollowsMouse = d.bool(forKey: "dragFollowsMouse")
        rememberProgress = d.bool(forKey: "rememberProgress")
        rememberMode = d.bool(forKey: "rememberMode")
        playbackSpeed = d.double(forKey: "playbackSpeed")
        appLanguage = d.string(forKey: "appLanguage") ?? ""
        cursorOpacity = d.double(forKey: "cursorOpacity")
    }
}
