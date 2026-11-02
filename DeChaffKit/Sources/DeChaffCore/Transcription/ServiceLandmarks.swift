import Foundation

/// A recognisable moment in a service recording: a spoken cue ("…come up and read",
/// "let's pray", "invite you to stand and sing") or the edge of a stretch of music.
public struct ServiceLandmark: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// The leader handing over to the Bible reader.
        case readingHandover = "reading_handover"
        /// The reader announcing the passage.
        case readingAnnounced = "reading_announced"
        /// The reading's closing words ("This is the word of the Lord").
        case readingEnd = "reading_end"
        /// The preacher picking up after the reading ("Thanks so much, Matt").
        case sermonOpening = "sermon_opening"
        case prayer
        case amen
        /// The closing song being introduced.
        case songIntro = "song_intro"
        /// First word after a stretch of music.
        case musicEnds = "music_ends"
        /// Last word before a stretch of music.
        case musicStarts = "music_starts"
    }

    public let kind: Kind
    public let wordIndex: Int
    public let time: Double
    public let phrase: String
}

/// Suggested trim and chapter points, from landmarks and a house style. The assistant
/// should still read the transcript around each point before using it.
public struct TrimSuggestion: Sendable {
    public struct Point: Sendable, Equatable {
        public let wordIndex: Int
        public let time: Double
        public let reason: String
        public let confidence: FieldConfidence
    }

    /// First word to keep.
    public var trimStart: Point?
    /// Last word to keep.
    public var trimEnd: Point?
    /// Where the Bible reading begins (for a "Bible Reading" chapter).
    public var readingStart: Point?
    /// Where the sermon proper begins (for a "Sermon" chapter).
    public var sermonStart: Point?
    public var landmarks: [ServiceLandmark] = []
    public var notes: [String] = []
}

// MARK: - Finding landmarks

private let cuePhrases: [(ServiceLandmark.Kind, [String])] = [
    (.readingHandover, ["come up and read", "come and read", "going to read", "gonna read", "read for us",
                        "read to us", "reading for us", "do the reading", "do our reading", "bring us the reading",
                        "bring us our reading", "come up and do"]),
    (.readingAnnounced, ["our reading today", "reading today is", "today's reading", "reading is from",
                         "reading comes from", "reading this morning", "reading this evening", "we're reading from",
                         "reading tonight"]),
    (.readingEnd, ["this is the word of the lord", "the word of the lord", "thanks be to god", "this is god's word",
                   "here ends the reading"]),
    (.sermonOpening, ["thanks so much", "thank you so much", "thanks for reading", "thank you for reading",
                      "thanks for that reading", "thank you for that reading", "thanks for that", "thank you for that"]),
    (.prayer, ["let's pray", "let us pray", "pray with me", "i'll pray", "i will pray", "let me pray"]),
    (.amen, ["amen"]),
    (.songIntro, ["invite you to stand", "stand and sing", "sing in response", "respond in song", "let's stand",
                  "let's sing", "we're going to sing", "going to sing", "band to come", "band's going to",
                  "band is going to", "closing song", "as we sing", "come and lead us", "lead us in singing"]),
]

/// Lowercased with punctuation stripped, so "Pray." matches "pray" and ’ matches '.
public func normalizedTranscriptToken(_ s: String) -> String {
    String(s.lowercased().replacingOccurrences(of: "’", with: "'").unicodeScalars
        .filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" })
}

public func findServiceLandmarks(words: [TranscriptWord], music: [MusicSegment] = []) -> [ServiceLandmark] {
    let tokens = words.map { normalizedTranscriptToken($0.text) }
    var found: [ServiceLandmark] = []
    for (kind, phrases) in cuePhrases {
        for phrase in phrases {
            let p = phrase.split(separator: " ").map(String.init)
            var i = 0
            while i + p.count <= tokens.count {
                if Array(tokens[i..<i + p.count]) == p {
                    // A longer phrase of the same kind at the same word wins ("this is the word of the lord").
                    if !found.contains(where: { $0.kind == kind && abs($0.wordIndex - i) < p.count + 2 }) {
                        found.append(ServiceLandmark(kind: kind, wordIndex: i, time: words[i].startTime, phrase: phrase))
                    }
                    i += p.count
                } else {
                    i += 1
                }
            }
        }
    }
    for seg in music {
        if let before = words.lastIndex(where: { $0.endTime <= seg.startSeconds + 0.5 }) {
            found.append(ServiceLandmark(kind: .musicStarts, wordIndex: before, time: words[before].endTime,
                                         phrase: "music from \(formatCutTime(seg.startSeconds))"))
        }
        if let after = words.firstIndex(where: { $0.startTime >= seg.endSeconds - 0.5 }) {
            found.append(ServiceLandmark(kind: .musicEnds, wordIndex: after, time: words[after].startTime,
                                         phrase: "music until \(formatCutTime(seg.endSeconds))"))
        }
    }
    return found.sorted { ($0.time, $0.wordIndex) < ($1.time, $1.wordIndex) }
}

// MARK: - Suggesting a trim

/// Proposes trim and chapter points: where the Bible reading and the sermon begin, and
/// where the sermon ends — the closing prayer's "Amen", or just before the closing song is
/// introduced, as the house style asks.
public func suggestTrim(words: [TranscriptWord], music: [MusicSegment] = [],
                        style: HouseStyle = HouseStyle()) -> TrimSuggestion {
    var s = TrimSuggestion()
    guard !words.isEmpty else { s.notes.append("The transcript is empty."); return s }
    let all = findServiceLandmarks(words: words, music: music)
    s.landmarks = all
    func marks(_ kinds: ServiceLandmark.Kind..., after t: Double = -1, before end: Double = .infinity) -> [ServiceLandmark] {
        all.filter { kinds.contains($0.kind) && $0.time > t && $0.time < end }
    }
    func point(_ i: Int, _ reason: String, _ confidence: FieldConfidence) -> TrimSuggestion.Point {
        .init(wordIndex: i, time: words[i].startTime, reason: reason, confidence: confidence)
    }

    // The reading: a hand-over or announcement followed within 12 minutes by the reading's
    // end or the preacher picking up — which separates it from notices that mention reading.
    let confirmedCue = marks(.readingHandover, .readingAnnounced).first { cue in
        !marks(.readingEnd, .sermonOpening, after: cue.time, before: cue.time + 720).isEmpty
    }
    let readingCue = confirmedCue ?? marks(.readingAnnounced, .readingHandover).first
    if let cue = readingCue {
        let sure: FieldConfidence = confirmedCue != nil ? .high : .medium
        if cue.kind == .readingHandover {
            // The reader starts after the hand-over — usually after a pause as they come up.
            let afterCue = sentenceEnd(words, cue.wordIndex) + 1
            let walkUp = (afterCue..<min(words.count, afterCue + 200)).first { i in
                i > 0 && words[i].startTime - words[i - 1].endTime >= 1.5 && words[i].startTime - cue.time < 90
            }
            if let i = walkUp ?? (afterCue < words.count ? afterCue : nil) {
                s.readingStart = point(i, "the reader's first words after \"\(cue.phrase)\"",
                                       walkUp != nil ? sure : .medium)
            }
        } else {
            let i = sentenceStart(words, cue.wordIndex)
            s.readingStart = point(i, "the reader announcing the passage (\"\(cue.phrase)\")", sure)
        }
    }

    // The sermon: the preacher picking up after the reading ends, else a prayer after it.
    let readingTime = s.readingStart?.time ?? -1
    if let start = s.readingStart {
        let end = marks(.readingEnd, after: start.time, before: start.time + 720).first
        let searchFrom = end?.time ?? start.time + 20
        if let opening = marks(.sermonOpening, .prayer, after: searchFrom, before: searchFrom + 180).first {
            s.sermonStart = point(sentenceStart(words, opening.wordIndex),
                                  "the preacher picking up after the reading (\"\(opening.phrase)\")",
                                  end != nil ? .high : .medium)
        } else if let end {
            let next = sentenceEnd(words, end.wordIndex) + 1
            if next < words.count {
                s.sermonStart = point(next, "the first sentence after \"\(end.phrase)\"", .medium)
            }
        }
    }
    if s.sermonStart == nil {
        s.notes.append("Couldn't find where the sermon begins from spoken cues — read the transcript after the reading.")
    }
    if s.readingStart == nil {
        s.notes.append("Couldn't find the Bible reading — look for the reader being introduced or the passage announced.")
    }

    // Start of the episode, per the house style.
    switch style.trimStart {
    case .reading:
        s.trimStart = s.readingStart ?? s.sermonStart
        if s.readingStart == nil, s.sermonStart != nil {
            s.notes.append("The house style starts at the reading, which wasn't found; trim_start falls back to the sermon.")
        }
    case .sermon:
        s.trimStart = s.sermonStart
    }

    // The end: the first song introduction or music well after the sermon starts.
    let sermonFrom = (s.sermonStart?.time ?? s.trimStart?.time ?? readingTime) + 480
    let songCue = marks(.songIntro, after: sermonFrom).first
    let musicCue = marks(.musicStarts, after: sermonFrom).first
    let boundary = [songCue?.time, musicCue?.time].compactMap { $0 }.min() ?? .infinity
    let lastWord = words.count - 1

    switch style.trimEnd {
    case .amen:
        if let amen = marks(.amen, after: sermonFrom, before: boundary).last {
            let prayed = !marks(.prayer, after: amen.time - 300, before: amen.time).isEmpty
            s.trimEnd = point(amen.wordIndex, "the last \"Amen\" before the service moves on"
                              + (prayed ? ", closing a prayer" : ""), prayed ? .high : .medium)
        } else if boundary.isFinite {
            s.notes.append("No \"Amen\" between the sermon and the closing song — check the end by reading the transcript.")
        }
    case .songIntro:
        if let cue = songCue, cue.time <= boundary {
            let i = max(0, sentenceStart(words, cue.wordIndex) - 1)
            s.trimEnd = point(i, "the end of the sentence before the song is introduced (\"\(cue.phrase)\")", .high)
        } else if let music = musicCue {
            s.trimEnd = point(music.wordIndex, "the last words before the music starts", .medium)
        }
    }
    if s.trimEnd == nil && !boundary.isFinite {
        s.notes.append("No closing song or music found after the sermon; the recording may end with it.")
        s.trimEnd = point(lastWord, "the end of the transcript", .low)
    }
    return s
}

// MARK: - Sentences

/// First word of the sentence containing `i`: back to the previous . ? ! or a 1 s pause.
public func sentenceStart(_ words: [TranscriptWord], _ i: Int) -> Int {
    var j = min(max(i, 0), words.count - 1)
    while j > 0 {
        let prev = words[j - 1]
        if let last = prev.text.last, ".?!".contains(last) { break }
        if words[j].startTime - prev.endTime >= 1.0 { break }
        j -= 1
    }
    return j
}

/// Last word of the sentence containing `i`.
public func sentenceEnd(_ words: [TranscriptWord], _ i: Int) -> Int {
    var j = min(max(i, 0), words.count - 1)
    while j < words.count - 1 {
        if let last = words[j].text.last, ".?!".contains(last) { break }
        if words[j + 1].startTime - words[j].endTime >= 1.0 { break }
        j += 1
    }
    return j
}
