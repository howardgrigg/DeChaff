import Foundation

/// How sure a parse is about one field.
public enum FieldConfidence: String, Sendable, Codable, Comparable {
    case low, medium, high

    public static func < (a: Self, b: Self) -> Bool {
        let order: [Self] = [.low, .medium, .high]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}

/// Sermon fields guessed from a video title by what each part looks like, with a
/// confidence per field so the assistant knows which to double-check.
public struct GuessedSermonFields: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public var value: String
        public var confidence: FieldConfidence
        /// Why the value was chosen, when that isn't obvious (e.g. "assumed the last series").
        public var note: String?

        public init(_ value: String = "", _ confidence: FieldConfidence = .low, note: String? = nil) {
            self.value = value
            self.confidence = confidence
            self.note = note
        }
    }

    public var title = Field()
    public var reading = Field()
    public var preacher = Field()
    public var series = Field()
    public var date = Field()
    /// Parts of the title that didn't fit any field (e.g. "Apostles' Creed").
    public var unused: [String] = []

    public init() {}
}

/// Guesses sermon fields from a hand-typed title that may not follow the church's format.
///
/// The title is split on "|" whether or not it has spaces around it (or on dashes when there
/// are no pipes), then each part is recognised by its shape: a date, a Bible reference
/// ("Romans 12", "John 10:1–18"), a known or name-like preacher, a known series, or a
/// "Series - Title" pair. Whatever is left becomes the title. A missing series is taken
/// from `knownSeries` — first one mentioned in the title, else the most recent — at low
/// confidence.
///
/// - Parameters:
///   - knownSeries: Series names the church has used, most recent first.
///   - knownPreachers: Preachers the church has had, most recent first.
public func guessSermonFields(_ title: String, knownSeries: [String] = [],
                              knownPreachers: [String] = []) -> GuessedSermonFields {
    var result = GuessedSermonFields()
    let parts = splitTitle(title)
    var assigned = Array(repeating: false, count: parts.count)

    func matchKnown(_ part: String, in list: [String]) -> String? {
        list.first { !$0.isEmpty && $0.compare(part, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    // Unambiguous shapes first: dates and Bible references.
    for (i, part) in parts.enumerated() where result.date.value.isEmpty && looksLikeDate(part) {
        result.date = .init(part, .high); assigned[i] = true
    }
    for (i, part) in parts.enumerated() where !assigned[i] && result.reading.value.isEmpty && looksLikeBibleReference(part) {
        result.reading = .init(part, .high); assigned[i] = true
    }

    // Known names, then name-shaped parts (the last one — preachers tend to come late in titles,
    // after the sermon title and reading).
    for (i, part) in parts.enumerated() where !assigned[i] {
        if result.preacher.value.isEmpty, let known = matchKnown(part, in: knownPreachers) {
            result.preacher = .init(known, .high); assigned[i] = true
        } else if result.series.value.isEmpty, let known = matchKnown(part, in: knownSeries) {
            result.series = .init(known, .high); assigned[i] = true
        }
    }
    if result.preacher.value.isEmpty,
       // The first part is usually the sermon title, which can look like a name ("Genuine Love").
       let i = parts.indices.last(where: { $0 > 0 && !assigned[$0] && looksLikePersonName(parts[$0]) }) {
        result.preacher = .init(parts[i], .medium); assigned[i] = true
    }

    // "Series - Title" in one part.
    for (i, part) in parts.enumerated() where !assigned[i] && result.title.value.isEmpty {
        guard let (left, right) = splitSeriesAndTitle(part) else { continue }
        if let known = matchKnown(left, in: knownSeries) {
            if result.series.value.isEmpty { result.series = .init(known, .high) }
            result.title = .init(right, .medium); assigned[i] = true
        } else if result.series.value.isEmpty && isBibleBook(left) {
            result.series = .init(left, .medium, note: "a book name before the title, read as the series")
            result.title = .init(right, .medium); assigned[i] = true
        }
    }

    // Whatever's left: the first part is the title, the rest are unused.
    for (i, part) in parts.enumerated() where !assigned[i] {
        if result.title.value.isEmpty {
            result.title = .init(part, parts.count == 1 ? .low : .medium); assigned[i] = true
        } else {
            result.unused.append(part)
        }
    }

    if result.series.value.isEmpty {
        let lower = title.lowercased()
        if let mentioned = knownSeries.first(where: { !$0.isEmpty && containsWord(lower, $0.lowercased()) }) {
            result.series = .init(mentioned, .medium, note: "a known series named in the title")
        } else if let last = knownSeries.first(where: { !$0.isEmpty }) {
            result.series = .init(last, .low, note: "not in the title — assumed the most recent series")
        }
    }
    return result
}

// MARK: - Shapes

/// Splits on "|" with or without surrounding spaces; with no pipes, on spaced dashes.
private func splitTitle(_ title: String) -> [String] {
    let separators: [String] = title.contains("|") ? ["|"] : [" – ", " — ", " - "]
    var parts = [title]
    for sep in separators {
        parts = parts.flatMap { $0.components(separatedBy: sep) }
    }
    return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

/// "Romans - Genuine Love" → ("Romans", "Genuine Love").
private func splitSeriesAndTitle(_ part: String) -> (String, String)? {
    for sep in [" – ", " — ", " - ", ": "] {
        let pieces = part.components(separatedBy: sep)
        if pieces.count == 2 {
            let l = pieces[0].trimmingCharacters(in: .whitespaces), r = pieces[1].trimmingCharacters(in: .whitespaces)
            if !l.isEmpty && !r.isEmpty { return (l, r) }
        }
    }
    return nil
}

func looksLikeDate(_ s: String) -> Bool {
    if parseExtractedDate(s) != nil { return true }
    return s.range(of: #"^\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4}$"#, options: .regularExpression) != nil
}

/// A book name followed by a chapter: "Romans 12", "1 Peter 1:3–9", "Song of Songs 2".
func looksLikeBibleReference(_ s: String) -> Bool {
    guard let r = s.range(of: #"^(.+?)\s+\d+([:.]\d+)?([\-–—]\d+([:.]\d+)?)?([,;].*)?$"#, options: .regularExpression),
          r.lowerBound == s.startIndex else { return false }
    // The book is everything before the first chapter number.
    guard let firstNumber = s.range(of: #"\s+\d+([:.\-–—]|$|[,;])"#, options: .regularExpression) else { return false }
    return isBibleBook(String(s[s.startIndex..<firstNumber.lowerBound]))
}

func isBibleBook(_ s: String) -> Bool {
    let name = s.lowercased().replacingOccurrences(of: ".", with: "")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    if bibleBooks.contains(name) { return true }
    // Numbered books, abbreviated or not: "1Cor", "2 Tim", "II Peter".
    if let r = name.range(of: #"^(1|2|3|i|ii|iii) ?"#, options: .regularExpression) {
        return numberedBooks.contains(String(name[r.upperBound...]))
    }
    return false
}

private let numberedBooks: Set<String> = [
    "samuel", "sam", "kings", "kgs", "chronicles", "chr", "corinthians", "cor", "thessalonians", "thess",
    "timothy", "tim", "peter", "pet", "john", "jn",
]

/// Two to four capitalised words, optionally after a title like "Rev." — "Paul Shoemark".
private func looksLikePersonName(_ s: String) -> Bool {
    let pattern = #"^(?:(?:Rev|Revd|Pastor|Ps|Dr|Bishop|Fr|Canon)\.?\s+)?\p{Lu}[\p{L}'’\-]+(?:\s+\p{Lu}[\p{L}'’\-]+){1,3}$"#
    guard s.range(of: pattern, options: .regularExpression) != nil else { return false }
    // Possessives ("Apostles' Creed") and Bible books aren't names.
    let words = s.split(separator: " ").map(String.init)
    if words.contains(where: { $0.hasSuffix("'") || $0.hasSuffix("’") }) { return false }
    return !words.contains(where: isBibleBook)
}

private func containsWord(_ text: String, _ word: String) -> Bool {
    text.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#, options: .regularExpression) != nil
}

private let bibleBooks: Set<String> = {
    let names = """
    genesis exodus leviticus numbers deuteronomy joshua judges ruth 1 samuel 2 samuel 1 kings 2 kings \
    1 chronicles 2 chronicles ezra nehemiah esther job psalm psalms proverbs ecclesiastes song of songs \
    song of solomon isaiah jeremiah lamentations ezekiel daniel hosea joel amos obadiah jonah micah nahum \
    habakkuk zephaniah haggai zechariah malachi matthew mark luke john acts romans 1 corinthians \
    2 corinthians galatians ephesians philippians colossians 1 thessalonians 2 thessalonians 1 timothy \
    2 timothy titus philemon hebrews james 1 peter 2 peter 1 john 2 john 3 john jude revelation \
    gen exod lev num deut josh judg sam kgs chr neh esth ps prov eccl isa jer lam ezek dan hos obad mic nah \
    hab zeph hag zech mal matt mk lk jn rom cor gal eph phil col thess tim tit phlm heb jas pet rev
    """
    // Multi-word books are listed with spaces; split carefully so "1 samuel" stays together.
    var set = Set<String>()
    let tokens = names.split(separator: " ").map(String.init)
    var i = 0
    while i < tokens.count {
        if ["1", "2", "3"].contains(tokens[i]), i + 1 < tokens.count {
            set.insert(tokens[i] + " " + tokens[i + 1]); i += 2
        } else if tokens[i] == "song", i + 2 < tokens.count, tokens[i + 1] == "of" {
            set.insert("song of " + tokens[i + 2]); i += 3
        } else {
            set.insert(tokens[i]); i += 1
        }
    }
    // Numbered books are also written without the space ("1Peter") or with Roman numerals.
    for name in set where name.first?.isNumber == true {
        set.insert(name.replacingOccurrences(of: " ", with: ""))
        let roman = ["1": "i", "2": "ii", "3": "iii"][String(name.prefix(1))]!
        set.insert(roman + name.dropFirst())
    }
    return set
}()
