import Foundation
import CryptoKit

/// Word-level transcripts cached on disk, shared by the app and the MCP server so a
/// recording is only transcribed once whichever side gets to it first. The key includes
/// the file's size and modification date, so an edited file is transcribed afresh.
public enum TranscriptCache {
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DeChaff/transcripts", isDirectory: true)
    }

    public static func words(for url: URL) -> [TranscriptWord]? {
        guard let key = key(for: url),
              let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")) else { return nil }
        return try? JSONDecoder().decode([TranscriptWord].self, from: data)
    }

    public static func save(_ words: [TranscriptWord], for url: URL) {
        guard !words.isEmpty, let key = key(for: url) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(words) {
            try? data.write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
        }
    }

    /// Stable per file version; nil if the file can't be read.
    public static func key(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(url.path)|\(size)|\(modified)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
