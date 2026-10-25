import Foundation

/// Everything decided about an episode before it's processed: which recording, where it's
/// trimmed and cut, its chapters and its tags. The MCP server and the app hand episodes to
/// each other through one shared plan file, so an assistant can prepare an episode, the
/// user can adjust it in the app, and either side can finish it.
///
/// All times are source seconds (S) — the same timeline as trim points and chapters
/// everywhere else.
public struct EpisodePlan: Codable, Equatable, Sendable {
    public struct Span: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    public struct Marker: Codable, Equatable, Sendable {
        public var time: Double
        public var title: String
        public init(time: Double, title: String) { self.time = time; self.title = title }
    }

    /// Who wrote the plan last, so each side can tell its own writes from the other's.
    public enum Editor: String, Codable, Sendable { case app, assistant }

    public var sourcePath: String
    public var trimIn: Double
    public var trimOut: Double
    public var excluded: [Span]
    public var chapters: [Marker]
    public var title: String
    public var reading: String
    public var preacher: String
    public var series: String
    public var date: Date
    public var artwork: Data?
    public var editedBy: Editor
    public var updatedAt: Date

    public init(sourcePath: String, trimIn: Double, trimOut: Double, excluded: [Span] = [],
                chapters: [Marker] = [], title: String = "", reading: String = "", preacher: String = "",
                series: String = "", date: Date = Date(), artwork: Data? = nil,
                editedBy: Editor, updatedAt: Date = Date()) {
        self.sourcePath = sourcePath
        self.trimIn = trimIn
        self.trimOut = trimOut
        self.excluded = excluded
        self.chapters = chapters
        self.title = title
        self.reading = reading
        self.preacher = preacher
        self.series = series
        self.date = date
        self.artwork = artwork
        self.editedBy = editedBy
        self.updatedAt = updatedAt
    }

    /// Equal apart from who saved it and when — used to skip writes that change nothing.
    public func hasSameContent(as other: EpisodePlan) -> Bool {
        var a = self, b = other
        a.editedBy = .app; b.editedBy = .app
        a.updatedAt = .distantPast; b.updatedAt = .distantPast
        return a == b
    }
}

/// The shared plan file in DeChaff's Application Support folder.
public enum EpisodePlanFile {
    public static var url: URL { YtDlpPaths.supportDirectory.appendingPathComponent("episode-plan.json") }

    public static func load() -> EpisodePlan? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(EpisodePlan.self, from: data)
    }

    public static func save(_ plan: EpisodePlan) throws {
        try FileManager.default.createDirectory(at: YtDlpPaths.supportDirectory, withIntermediateDirectories: true)
        try encoder.encode(plan).write(to: url, options: .atomic)
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
