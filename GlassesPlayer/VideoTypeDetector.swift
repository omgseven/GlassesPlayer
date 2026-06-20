import Foundation

/// Automatic video type detection from filename patterns and mpv metadata.
/// Priority: PlaybackMemory > filename > metadata > default (unchanged).
enum VideoTypeDetector {

    // MARK: - Filename Detection

    /// Infer SourceLayout from filename keywords. Returns nil if no pattern matched.
    static func detectFromFilename(_ filename: String) -> SourceLayout? {
        let name = filename.lowercased()

        // SBS patterns
        let sbsPatterns = ["_sbs", ".sbs", "-sbs", " sbs",
                           "_lr", ".lr", "-lr",
                           "_3dh", ".3dh", "-3dh",
                           "sbs3d", "half-sbs", "halfsbs"]
        for p in sbsPatterns where name.contains(p) {
            return .sideBySide
        }

        // Top-Bottom patterns
        let tbPatterns = ["_tb", ".tb", "-tb", " tb",
                          "_ou", ".ou", "-ou", " ou",
                          "_3dv", ".3dv", "-3dv",
                          "tab3d", "half-ou", "halfou"]
        for p in tbPatterns where name.contains(p) {
            return .topBottom
        }

        // 360° patterns (including VR180 — same projection for now)
        let panoPatterns = ["_360", ".360", "-360", " 360",
                            "_vr360", "_equirect", "_eac",
                            "_180", ".180", "-180",
                            "_vr180"]
        for p in panoPatterns where name.contains(p) {
            return .mono360
        }

        // Explicit 2D patterns
        let flatPatterns = ["_2d", ".2d", "-2d", "_flat", "-flat"]
        for p in flatPatterns where name.contains(p) {
            return .mono2D
        }

        return nil
    }

    // MARK: - Metadata Detection

    /// Infer SourceLayout from mpv's "video-params/stereo-in" string.
    /// Returns nil if metadata indicates mono or is unavailable.
    static func detectFromMetadata(stereoMode: String?) -> SourceLayout? {
        guard let mode = stereoMode, !mode.isEmpty else { return nil }

        switch mode {
        case "sbs2l", "sbs2r", "sbs_left", "sbs_right":
            return .sideBySide
        case "ab2l", "ab2r", "ab_left", "ab_right", "over-under":
            return .topBottom
        default:
            // "mono" or unknown — don't override
            return nil
        }
    }
}
