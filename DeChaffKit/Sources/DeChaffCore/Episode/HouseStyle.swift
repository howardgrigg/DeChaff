import Foundation

/// How a church likes its episodes cut and chaptered — Settings → MCP → House style.
/// The MCP server's guidance and suggest_trim follow these instead of generic defaults.
public struct HouseStyle: Sendable, Equatable {
    public enum TrimStart: String, CaseIterable, Sendable {
        /// Start at the sermon itself, after the Bible reading.
        case sermon
        /// Start at the Bible reading, so the episode includes it.
        case reading

        public var label: String {
            switch self {
            case .sermon:  return "At the sermon (after the reading)"
            case .reading: return "At the Bible reading (include it)"
            }
        }
    }

    public enum TrimEnd: String, CaseIterable, Sendable {
        /// End on the "Amen" of the prayer that closes the sermon.
        case amen
        /// Keep going until the closing song is introduced, and stop just before that.
        case songIntro = "song_intro"

        public var label: String {
            switch self {
            case .amen:      return "On the closing prayer's “Amen”"
            case .songIntro: return "Just before the closing song is introduced"
            }
        }
    }

    public var trimStart: TrimStart
    public var trimEnd: TrimEnd
    /// Chapter titles, one per line, in order, with {title} {reading} {series} {preacher}.
    /// A line reading {points} stands for chapters at the sermon's main points.
    /// Empty: the assistant chooses 3–6 chapters itself.
    public var chapterTitles: String

    public static let trimStartKey = "dechaff.style.trimStart"
    public static let trimEndKey = "dechaff.style.trimEnd"
    public static let chapterTitlesKey = "dechaff.style.chapterTitles"

    public init(trimStart: TrimStart = .sermon, trimEnd: TrimEnd = .amen, chapterTitles: String = "") {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.chapterTitles = chapterTitles
    }

    public init(defaults: UserDefaults) {
        self.init(
            trimStart: defaults.string(forKey: Self.trimStartKey).flatMap(TrimStart.init) ?? .sermon,
            trimEnd: defaults.string(forKey: Self.trimEndKey).flatMap(TrimEnd.init) ?? .amen,
            chapterTitles: defaults.string(forKey: Self.chapterTitlesKey) ?? "")
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(trimStart.rawValue, forKey: Self.trimStartKey)
        defaults.set(trimEnd.rawValue, forKey: Self.trimEndKey)
        defaults.set(chapterTitles, forKey: Self.chapterTitlesKey)
    }

    /// The chapter template's lines, with "{points}" kept as a marker.
    public var chapterLines: [String] {
        chapterTitles.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Chapter titles filled in for an episode. "{points}" lines are left as they are.
    public func chapterTitles(for tags: SermonTags) -> [String] {
        chapterLines.map { line in
            line == "{points}" ? line : line
                .replacingOccurrences(of: "{title}", with: tags.title)
                .replacingOccurrences(of: "{reading}", with: tags.reading)
                .replacingOccurrences(of: "{series}", with: tags.series)
                .replacingOccurrences(of: "{preacher}", with: tags.preacher)
        }
    }

    /// Plain-English guidance for the assistant.
    public var guidance: String {
        var lines: [String] = []
        switch trimStart {
        case .sermon:
            lines.append("Trim start: the first words of the sermon itself, after the Bible reading — typically "
                + "the preacher thanking the reader or opening in prayer.")
        case .reading:
            lines.append("Trim start: the start of the Bible reading, so the episode includes it — the reader's "
                + "first words, after the leader hands over (e.g. \"…is going to come up and read\").")
        }
        switch trimEnd {
        case .amen:
            lines.append("Trim end: the \"Amen\" of the prayer that closes the sermon.")
        case .songIntro:
            lines.append("Trim end: just before the closing song is introduced (e.g. \"I invite you to stand and "
                + "sing\") — keep the closing prayer, drop the introduction to the song.")
        }
        if chapterLines.isEmpty {
            lines.append("Chapters: 3–6 at clear turns in the sermon, the first at the trim start.")
        } else {
            let list = chapterLines.map { $0 == "{points}" ? "then one chapter per main point of the sermon" : "\"\($0)\"" }
            lines.append("Chapters, in this order, filling in the placeholders: " + list.joined(separator: ", ")
                + ". The first starts at the trim start.")
        }
        return lines.joined(separator: "\n")
    }
}
