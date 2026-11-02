import Foundation

/// One finished episode, as recorded when it was processed — by the app or the MCP server.
public struct EpisodeRecord: Codable, Equatable, Sendable {
    public struct ChapterMark: Codable, Equatable, Sendable {
        public var title: String
        /// Seconds into the finished episode.
        public var time: Double

        public init(title: String, time: Double) {
            self.title = title
            self.time = time
        }
    }

    public var outputPath: String
    public var sourcePath: String
    /// The YouTube video it came from, when known.
    public var videoID: String?
    public var processedAt: Date
    public var title: String
    public var reading: String
    public var preacher: String
    public var series: String
    public var date: Date
    /// Trim on the source recording's timeline.
    public var trimIn: Double
    public var trimOut: Double
    public var chapters: [ChapterMark]
    /// "app" or "assistant".
    public var processedBy: String

    public init(outputPath: String, sourcePath: String, videoID: String? = nil, processedAt: Date = Date(),
                title: String, reading: String, preacher: String, series: String, date: Date,
                trimIn: Double, trimOut: Double, chapters: [ChapterMark], processedBy: String) {
        self.outputPath = outputPath
        self.sourcePath = sourcePath
        self.videoID = videoID
        self.processedAt = processedAt
        self.title = title
        self.reading = reading
        self.preacher = preacher
        self.series = series
        self.date = date
        self.trimIn = trimIn
        self.trimOut = trimOut
        self.chapters = chapters
        self.processedBy = processedBy
    }
}

/// The episodes DeChaff has made, newest first, kept in Application Support so the
/// record survives the MP3s being moved or tidied away.
public enum EpisodeHistory {
    public static let maxRecords = 200

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DeChaff/episode-history.json")
    }

    public static func load(from url: URL = defaultURL) -> [EpisodeRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? decoder.decode([EpisodeRecord].self, from: data) else { return [] }
        return records
    }

    /// Adds a record (replacing any earlier one for the same output file) and saves.
    public static func record(_ record: EpisodeRecord, to url: URL = defaultURL) {
        var records = load(from: url).filter { $0.outputPath != record.outputPath }
        records.insert(record, at: 0)
        records = Array(records.prefix(maxRecords))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(records) { try? data.write(to: url, options: .atomic) }
    }

    /// Distinct non-empty values of a field across records, most recent first — e.g. the
    /// series and preachers a church has used, for recognising them in video titles.
    public static func recentValues(_ records: [EpisodeRecord], _ field: (EpisodeRecord) -> String) -> [String] {
        var seen = Set<String>()
        return records.compactMap { record in
            let value = field(record).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }
    }

    /// The YouTube video ID in a downloaded recording's file name (`dechaff-yt-<id>.<ext>`).
    /// Older downloads used a random UUID there, which isn't a video ID.
    public static func videoID(fromSourcePath path: String) -> String? {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        guard name.hasPrefix(youTubeDownloadPrefix) else { return nil }
        let id = String(name.dropFirst(youTubeDownloadPrefix.count))
        return isYouTubeVideoID(id) ? id : nil
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - YouTube video IDs

/// YouTube video IDs are 11 characters of [A-Za-z0-9_-].
public func isYouTubeVideoID(_ s: String) -> Bool {
    s.count == 11 && s.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil
}

/// The video ID in a YouTube URL (watch?v=, youtu.be/, /live/, /shorts/, /embed/), or a bare ID.
public func youTubeVideoID(from string: String) -> String? {
    let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if isYouTubeVideoID(s) { return s }
    guard let url = URL(string: s), let host = url.host?.lowercased(),
          host.hasSuffix("youtube.com") || host.hasSuffix("youtu.be") else { return nil }
    if host.hasSuffix("youtu.be") {
        let id = url.pathComponents.dropFirst().first ?? ""
        return isYouTubeVideoID(id) ? id : nil
    }
    if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
       isYouTubeVideoID(v) {
        return v
    }
    let parts = url.pathComponents
    if let i = parts.firstIndex(where: { ["live", "shorts", "embed", "v"].contains($0) }), i + 1 < parts.count,
       isYouTubeVideoID(parts[i + 1]) {
        return parts[i + 1]
    }
    return nil
}

/// Downloads kept by video ID in ~/Library/Caches, so a recording survives the session
/// and tools can refer to it by ID.
public enum DownloadCache {
    public static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DeChaff/Downloads", isDirectory: true)
    }

    /// The cached recording for a video, if it's been downloaded.
    public static func file(forVideoID id: String, in directory: URL = directory) -> URL? {
        let prefix = "\(youTubeDownloadPrefix)\(id)."
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.lastPathComponent.hasPrefix(prefix) }
    }

    /// Moves a fresh download into the cache as `dechaff-yt-<id>.<ext>`.
    public static func store(_ file: URL, videoID id: String, in directory: URL = directory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent("\(youTubeDownloadPrefix)\(id).\(file.pathExtension)")
        if let old = self.file(forVideoID: id, in: directory) { try? FileManager.default.removeItem(at: old) }
        try FileManager.default.moveItem(at: file, to: dest)
        return dest
    }
}
