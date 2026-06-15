import Foundation
import CryptoKit

struct PlaybackRecord: Codable {
    var version: Int = 1
    var progress: Double
    var duration: Double
    var sourceLayout: Int32
    var displayMode: Int32
    var lastAccessed: Date
}

final class PlaybackMemory {
    private let storageKey = "playbackMemory"
    private let maxEntries = 100
    private var records: [String: PlaybackRecord]

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let dict = try? JSONDecoder().decode([String: PlaybackRecord].self, from: data) {
            records = dict
        } else {
            records = [:]
        }
    }

    func save(url: URL, progress: Double, duration: Double,
              sourceLayout: SourceLayout, displayMode: DisplayMode) {
        guard let hash = Self.fileHash(url: url) else { return }
        records[hash] = PlaybackRecord(
            progress: progress,
            duration: duration,
            sourceLayout: sourceLayout.rawValue,
            displayMode: displayMode.rawValue,
            lastAccessed: Date()
        )
        evictIfNeeded()
        persist()
    }

    func load(url: URL) -> PlaybackRecord? {
        guard let hash = Self.fileHash(url: url) else { return nil }
        guard var record = records[hash] else { return nil }
        record.lastAccessed = Date()
        records[hash] = record
        persist()
        return record
    }

    private func evictIfNeeded() {
        guard records.count > maxEntries else { return }
        let sorted = records.sorted { $0.value.lastAccessed < $1.value.lastAccessed }
        for i in 0..<(sorted.count - maxEntries) {
            records.removeValue(forKey: sorted[i].key)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func fileHash(url: URL) -> String? {
        let path = url.path
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }

        var hashInput = Data()
        var size = Int64(st.st_size)
        hashInput.append(Data(bytes: &size, count: 8))

        if let fh = try? FileHandle(forReadingFrom: url) {
            if let head = try? fh.read(upToCount: 65536) {
                hashInput.append(head)
            }
            try? fh.close()
        }

        let digest = Insecure.MD5.hash(data: hashInput)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
