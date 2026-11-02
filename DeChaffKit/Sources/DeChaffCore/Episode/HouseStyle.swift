import Foundation

/// How a church's services run and how it likes its episodes cut — Settings → Service.
/// Nothing here changes the app's own editing: the AI assistant (MCP server) and its
/// suggest_trim tool follow these instead of assuming one church's format.
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
    /// The episode's end is only looked for this long after the sermon starts, so a prayer
    /// early in the sermon isn't taken for the closing one.
    public var minimumSermonMinutes: Int
    /// Whether the church changes its cover art with each series (the assistant then checks
    /// the saved artwork whenever the series changes) or always uses the same image.
    public var artworkPerSeries: Bool
    /// The phrases suggest_trim listens for, by kind. Kinds not set use the defaults.
    public var cues: [ServiceLandmark.Kind: [String]]

    public static let trimStartKey = "dechaff.style.trimStart"
    public static let trimEndKey = "dechaff.style.trimEnd"
    public static let chapterTitlesKey = "dechaff.style.chapterTitles"
    public static let minimumSermonMinutesKey = "dechaff.style.minimumSermonMinutes"
    public static let artworkPerSeriesKey = "dechaff.style.artworkPerSeries"

    public static let defaultMinimumSermonMinutes = 8

    public init(trimStart: TrimStart = .sermon, trimEnd: TrimEnd = .amen, chapterTitles: String = "",
                minimumSermonMinutes: Int = HouseStyle.defaultMinimumSermonMinutes, artworkPerSeries: Bool = true,
                cues: [ServiceLandmark.Kind: [String]] = [:]) {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.chapterTitles = chapterTitles
        self.minimumSermonMinutes = minimumSermonMinutes
        self.artworkPerSeries = artworkPerSeries
        self.cues = cues
    }

    public init(defaults: UserDefaults) {
        var cues: [ServiceLandmark.Kind: [String]] = [:]
        for kind in ServiceLandmark.Kind.spoken {
            if let text = defaults.string(forKey: kind.storageKey) { cues[kind] = ServiceLandmark.Kind.phrases(from: text) }
        }
        self.init(
            trimStart: defaults.string(forKey: Self.trimStartKey).flatMap(TrimStart.init) ?? .sermon,
            trimEnd: defaults.string(forKey: Self.trimEndKey).flatMap(TrimEnd.init) ?? .amen,
            chapterTitles: defaults.string(forKey: Self.chapterTitlesKey) ?? "",
            minimumSermonMinutes: (defaults.object(forKey: Self.minimumSermonMinutesKey) as? Int)
                ?? Self.defaultMinimumSermonMinutes,
            artworkPerSeries: (defaults.object(forKey: Self.artworkPerSeriesKey) as? Bool) ?? true,
            cues: cues)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(trimStart.rawValue, forKey: Self.trimStartKey)
        defaults.set(trimEnd.rawValue, forKey: Self.trimEndKey)
        defaults.set(chapterTitles, forKey: Self.chapterTitlesKey)
        defaults.set(minimumSermonMinutes, forKey: Self.minimumSermonMinutesKey)
        defaults.set(artworkPerSeries, forKey: Self.artworkPerSeriesKey)
        for kind in ServiceLandmark.Kind.spoken {
            if let phrases = cues[kind] { defaults.set(phrases.joined(separator: ", "), forKey: kind.storageKey) }
        }
    }

    /// The phrases to listen for, by kind: the church's own where set, else the defaults.
    public var cuePhrases: [ServiceLandmark.Kind: [String]] {
        var all: [ServiceLandmark.Kind: [String]] = [:]
        for kind in ServiceLandmark.Kind.spoken { all[kind] = cues[kind] ?? kind.defaultPhrases }
        return all
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
                + "the preacher picking up after the reader, or opening in prayer.")
        case .reading:
            lines.append("Trim start: the start of the Bible reading, so the episode includes it — the reader's "
                + "first words, after the leader hands over. If there are several readings, start at the first.")
        }
        switch trimEnd {
        case .amen:
            lines.append("Trim end: the \"Amen\" of the prayer that closes the sermon.")
        case .songIntro:
            lines.append("Trim end: just before the closing song is introduced — keep the closing prayer, drop the "
                + "introduction to the song.")
        }
        lines.append("Sermons here run at least \(minimumSermonMinutes) minutes, so the end won't be earlier than that.")
        if chapterLines.isEmpty {
            lines.append("Chapters: 3–6 at clear turns in the sermon, the first at the trim start.")
        } else {
            let list = chapterLines.map { $0 == "{points}" ? "then one chapter per main point of the sermon" : "\"\($0)\"" }
            lines.append("Chapters, in this order, filling in the placeholders: " + list.joined(separator: ", ")
                + ". The first starts at the trim start.")
        }
        if artworkPerSeries {
            lines.append("Artwork: the church uses new cover art for each series. DeChaff keeps the last episode's "
                + "artwork, so when the series differs from last_series, show the saved artwork (get_artwork) and ask "
                + "the user for the new series' image (tags.artwork_path; update_settings saves it as the default).")
        } else {
            lines.append("Artwork: the church uses the same cover art for every episode — use the saved artwork "
                + "without asking.")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Spoken cues

extension ServiceLandmark.Kind {
    /// The kinds found by listening for phrases (the rest come from music detection).
    public static let spoken: [Self] = [.readingHandover, .readingAnnounced, .readingEnd, .sermonOpening,
                                        .prayer, .amen, .songIntro]

    public var storageKey: String { "dechaff.style.cues.\(rawValue)" }

    /// Short name for Settings.
    public var label: String {
        switch self {
        case .readingHandover:  return "Handing over to the reader"
        case .readingAnnounced: return "Announcing the reading"
        case .readingEnd:       return "End of the reading"
        case .sermonOpening:    return "Preacher starting"
        case .prayer:           return "Start of a prayer"
        case .amen:             return "End of a prayer"
        case .songIntro:        return "Introducing the closing song"
        case .musicEnds:        return "Music ends"
        case .musicStarts:      return "Music starts"
        }
    }

    /// What the phrases are for, in Settings.
    public var usage: String {
        switch self {
        case .readingHandover:
            return "What the service leader says when bringing up the Bible reader. When episodes start at the "
                + "reading, they start with the reader's first words after this."
        case .readingAnnounced:
            return "What the reader says to introduce the passage. Also marks the start of the reading."
        case .readingEnd:
            return "Words that close a reading. The sermon is looked for straight after the last of these."
        case .sermonOpening:
            return "What the preacher says as they begin, such as thanking the reader. When episodes start at the "
                + "sermon, this is where."
        case .prayer:
            return "Words that start a prayer. Used to find the prayer that closes the sermon, and as the sermon's "
                + "start if nothing else is found."
        case .amen:
            return "The word that ends a prayer. When episodes end on the “Amen”, it's the last one before the "
                + "service moves on."
        case .songIntro:
            return "What's said as the closing song begins. When episodes end before the song, they stop just "
                + "before these words."
        case .musicEnds, .musicStarts:
            return "Found by music detection."
        }
    }

    public var defaultPhrases: [String] {
        switch self {
        case .readingHandover:
            return ["come up and read", "come and read", "going to read", "gonna read", "read for us", "read to us",
                    "reading for us", "do the reading", "do our reading", "bring us the reading", "bring us our reading"]
        case .readingAnnounced:
            return ["our reading today", "reading today is", "today's reading", "reading is from", "reading comes from",
                    "reading this morning", "reading this evening", "we're reading from", "reading tonight"]
        case .readingEnd:
            return ["this is the word of the lord", "the word of the lord", "thanks be to god", "this is god's word",
                    "here ends the reading"]
        case .sermonOpening:
            return ["thanks so much", "thank you so much", "thanks for reading", "thank you for reading",
                    "thanks for that reading", "thank you for that reading"]
        case .prayer:
            return ["let's pray", "let us pray", "pray with me", "i'll pray", "i will pray", "let me pray"]
        case .amen:
            return ["amen"]
        case .songIntro:
            return ["invite you to stand", "stand and sing", "sing in response", "respond in song", "let's stand",
                    "let's sing", "we're going to sing", "going to sing", "band to come", "closing song", "as we sing",
                    "come and lead us", "lead us in singing"]
        case .musicEnds, .musicStarts:
            return []
        }
    }

    /// Phrases from the Settings text box: separated by commas or new lines, matched
    /// ignoring case and punctuation.
    public static func phrases(from text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.split(whereSeparator: \.isWhitespace).map { normalizedTranscriptToken(String($0)) }
                .filter { !$0.isEmpty }.joined(separator: " ") }
            .filter { !$0.isEmpty }
    }
}
