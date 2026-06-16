import Foundation

/// Global logger that writes to a per-session log file (by process startup time).
/// All logs (both C layer mpv events and Swift app events) go to the same file.
enum Logger {

    enum Level: String {
        case debug = "DEBUG"
        case info  = "INFO"
        case warn  = "WARN"
        case error = "ERROR"
    }

    /// Log file path for the current session (nil if not yet initialized).
    static var logFilePath: String? {
        guard let cStr = mpv_player_get_log_path() else { return nil }
        return String(cString: cStr)
    }

    static func debug(_ message: String, file: String = #fileID, line: Int = #line) {
        log(level: .debug, message: message, file: file, line: line)
    }

    static func info(_ message: String, file: String = #fileID, line: Int = #line) {
        log(level: .info, message: message, file: file, line: line)
    }

    static func warn(_ message: String, file: String = #fileID, line: Int = #line) {
        log(level: .warn, message: message, file: file, line: line)
    }

    static func error(_ message: String, file: String = #fileID, line: Int = #line) {
        log(level: .error, message: message, file: file, line: line)
    }

    private static func log(level: Level, message: String, file: String, line: Int) {
        let tag = "\(level.rawValue)|\(file):\(line)"
        mpv_player_log_message(tag, message)
    }
}
