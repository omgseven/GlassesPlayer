import Foundation
import Observation

@Observable
@MainActor
final class PlaylistManager {
    var directoryFiles: [URL] = []
    var currentFileIndex: Int = -1

    var hasNextFile: Bool { currentFileIndex >= 0 && currentFileIndex < directoryFiles.count - 1 }
    var hasPreviousFile: Bool { currentFileIndex > 0 }

    static let videoExtensions: Set<String> = [
        "mp4", "mkv", "mov", "avi", "m4v", "wmv", "flv", "webm", "ts", "mpg", "mpeg", "3gp"
    ]

    func scanDirectory(for url: URL) {
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            directoryFiles = []
            currentFileIndex = -1
            return
        }
        directoryFiles = contents
            .filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        currentFileIndex = directoryFiles.firstIndex(where: { $0.path == url.path }) ?? -1
    }

    func nextFileURL() -> URL? {
        guard !directoryFiles.isEmpty, currentFileIndex >= 0 else { return nil }
        let next = currentFileIndex + 1
        guard next < directoryFiles.count else { return nil }
        return directoryFiles[next]
    }

    func previousFileURL() -> URL? {
        guard !directoryFiles.isEmpty, currentFileIndex > 0 else { return nil }
        return directoryFiles[currentFileIndex - 1]
    }

    func fileURL(at index: Int) -> URL? {
        guard index >= 0, index < directoryFiles.count else { return nil }
        return directoryFiles[index]
    }

    func firstFileURL() -> URL? {
        directoryFiles.first
    }
}
