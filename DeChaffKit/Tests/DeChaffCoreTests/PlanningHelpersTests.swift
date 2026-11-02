import Foundation
import Testing
@testable import DeChaffCore

// MARK: - Title guessing

@Suite struct TitleFieldGuesserTests {
    /// The title from the 2026-11-01 run: unspaced pipes, an extra liturgy part, and the
    /// series folded into the title part.
    let messy = "Apostles' Creed| Romans - Genuine Love| Romans 12 | Paul Shoemark | 01/11/2026"

    @Test func readsAMessyTitleByShape() {
        let g = guessSermonFields(messy)
        #expect(g.title.value == "Genuine Love")
        #expect(g.series.value == "Romans")
        #expect(g.reading == .init("Romans 12", .high))
        #expect(g.preacher.value == "Paul Shoemark")
        #expect(g.date == .init("01/11/2026", .high))
        #expect(g.unused == ["Apostles' Creed"])
    }

    @Test func knownNamesRaiseConfidence() {
        let g = guessSermonFields(messy, knownSeries: ["Romans"], knownPreachers: ["Paul Shoemark"])
        #expect(g.series.confidence == .high)
        #expect(g.preacher.confidence == .high)
    }

    @Test func missingSeriesFallsBackToKnownSeries() {
        let named = guessSermonFields("Genuine Love | Romans 12 | Paul Shoemark", knownSeries: ["Exiles", "Romans"])
        #expect(named.series.value == "Romans")
        #expect(named.series.confidence == .medium)

        let assumed = guessSermonFields("Genuine Love | Romans 12 | Paul Shoemark", knownSeries: ["Exiles"])
        #expect(assumed.series == .init("Exiles", .low, note: "not in the title — assumed the most recent series"))
    }

    @Test func aTitleThatLooksLikeANameStaysTheTitle() {
        let g = guessSermonFields("Genuine Love | Romans 12 | 01/11/2026")
        #expect(g.title.value == "Genuine Love")
        #expect(g.preacher.value.isEmpty)
    }

    @Test func recognisesBibleReferences() {
        for ref in ["Romans 12", "John 10:1–18", "1 Peter 1:3-9", "Song of Songs 2", "Ps 23", "1Cor 13"] {
            #expect(looksLikeBibleReference(ref), "\(ref)")
        }
        for notRef in ["Romans", "Chapter 12", "Week 3", "Paul Shoemark"] {
            #expect(!looksLikeBibleReference(notRef), "\(notRef)")
        }
    }
}

// MARK: - House style

@Suite struct HouseStyleTests {
    @Test func roundTripsThroughDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "dechaff-tests-\(UUID().uuidString)"))
        #expect(HouseStyle(defaults: defaults) == HouseStyle())
        let style = HouseStyle(trimStart: .reading, trimEnd: .songIntro,
                               chapterTitles: "Bible Reading: {reading}\nSermon: {title}\n{points}")
        style.save(to: defaults)
        #expect(HouseStyle(defaults: defaults) == style)
    }

    @Test func fillsChapterTitles() {
        let style = HouseStyle(chapterTitles: "Bible Reading: {reading}\n\nSermon: {title}\n{points}")
        let tags = SermonTags(title: "Genuine Love", reading: "Romans 12")
        #expect(style.chapterTitles(for: tags) == ["Bible Reading: Romans 12", "Sermon: Genuine Love", "{points}"])
        #expect(style.guidance.contains("one chapter per main point"))
    }
}

// MARK: - Episode history and video IDs

@Suite struct EpisodeHistoryTests {
    @Test func recordsNewestFirstAndReplacesSameOutput() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        func record(_ out: String, series: String) -> EpisodeRecord {
            EpisodeRecord(outputPath: out, sourcePath: "/tmp/src.m4a", title: "T", reading: "R", preacher: "P",
                          series: series, date: Date(), trimIn: 1, trimOut: 2,
                          chapters: [.init(title: "Sermon", time: 0)], processedBy: "app")
        }
        EpisodeHistory.record(record("/a.mp3", series: "Exiles"), to: url)
        EpisodeHistory.record(record("/b.mp3", series: "Romans"), to: url)
        EpisodeHistory.record(record("/a.mp3", series: "Romans"), to: url)
        let all = EpisodeHistory.load(from: url)
        #expect(all.map(\.outputPath) == ["/a.mp3", "/b.mp3"])
        #expect(EpisodeHistory.recentValues(all, \.series) == ["Romans"])
    }

    @Test func extractsVideoIDs() {
        #expect(youTubeVideoID(from: "https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(youTubeVideoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10") == "dQw4w9WgXcQ")
        #expect(youTubeVideoID(from: "https://www.youtube.com/live/dQw4w9WgXcQ?si=x") == "dQw4w9WgXcQ")
        #expect(youTubeVideoID(from: "dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(youTubeVideoID(from: "https://example.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(EpisodeHistory.videoID(fromSourcePath: "/x/dechaff-yt-dQw4w9WgXcQ.m4a") == "dQw4w9WgXcQ")
        #expect(EpisodeHistory.videoID(fromSourcePath: "/x/dechaff-yt-\(UUID().uuidString).m4a") == nil)
    }

    @Test func cachesDownloadsByVideoID() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let download = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString).m4a")
        try Data([1, 2, 3]).write(to: download)
        #expect(DownloadCache.file(forVideoID: "dQw4w9WgXcQ", in: dir) == nil)
        let stored = try DownloadCache.store(download, videoID: "dQw4w9WgXcQ", in: dir)
        #expect(stored.lastPathComponent == "dechaff-yt-dQw4w9WgXcQ.m4a")
        #expect(DownloadCache.file(forVideoID: "dQw4w9WgXcQ", in: dir)?.lastPathComponent == stored.lastPathComponent)
    }
}

// MARK: - Music tidying

@Suite struct MusicConsolidationTests {
    @Test func dropsFragmentsAndBridgesGaps() {
        let segs = [MusicSegment(startSeconds: 0, endSeconds: 120), MusicSegment(startSeconds: 122, endSeconds: 200),
                    MusicSegment(startSeconds: 900, endSeconds: 903), MusicSegment(startSeconds: 1500, endSeconds: 1503),
                    MusicSegment(startSeconds: 3000, endSeconds: 3240)]
        let tidy = consolidateMusicSegments(segs)
        #expect(tidy.map(\.startSeconds) == [0, 3000])
        #expect(tidy.map(\.endSeconds) == [200, 3240])
    }
}

// MARK: - Trim suggestions

/// A service in miniature: worship, the hand-over, the reading, the sermon, the closing
/// prayer, then the song introduced — with times laid out as they would be spoken.
private func service() -> (words: [TranscriptWord], music: [MusicSegment]) {
    var words: [TranscriptWord] = []
    var t = 300.0  // five minutes of worship first
    func say(_ sentence: String, pauseAfter: Double = 0.6) {
        for w in sentence.split(separator: " ") {
            words.append(TranscriptWord(text: String(w), startTime: t, endTime: t + 0.3)); t += 0.4
        }
        t += pauseAfter
    }
    say("Welcome everyone, great to have you here.")
    say("Matt's going to come up and read for us now.", pauseAfter: 4)       // walk-up pause
    say("Our reading today is from Romans chapter twelve.")
    say("Let love be genuine. Abhor what is evil.")
    say("This is the word of the Lord.", pauseAfter: 2)
    say("Thanks so much, Matt.")
    say("Let's pray.")
    say("Father, open our hearts. Amen.")
    for _ in 0..<200 { say("Love is the mark of the church and we hold fast to what is good.") }  // the sermon
    say("Let's pray.")
    say("Lord, make our love genuine. Amen.", pauseAfter: 1.5)
    say("I invite you to stand and sing in response.")
    let songStart = t + 2
    return (words, [MusicSegment(startSeconds: 0, endSeconds: 298),
                    MusicSegment(startSeconds: songStart, endSeconds: songStart + 240)])
}

@Suite struct TrimSuggestionTests {
    @Test func findsReadingSermonAndEnd() throws {
        let (words, music) = service()
        let s = suggestTrim(words: words, music: music, style: HouseStyle())
        let reading = try #require(s.readingStart)
        #expect(words[reading.wordIndex].text == "Our")
        #expect(reading.confidence == .high)
        let sermon = try #require(s.sermonStart)
        #expect(words[sermon.wordIndex].text == "Thanks")
        #expect(s.trimStart == s.sermonStart)
        let end = try #require(s.trimEnd)
        #expect(words[end.wordIndex].text == "Amen.")
        #expect(end.wordIndex > sermon.wordIndex + 1000)  // the closing Amen, not the opening prayer's
        #expect(end.confidence == .high)
    }

    @Test func followsTheHouseStyle() throws {
        let (words, music) = service()
        let s = suggestTrim(words: words, music: music,
                            style: HouseStyle(trimStart: .reading, trimEnd: .songIntro))
        #expect(words[try #require(s.trimStart).wordIndex].text == "Our")
        let end = try #require(s.trimEnd)
        #expect(words[end.wordIndex].text == "Amen.")           // the sentence before the song intro…
        #expect(words[end.wordIndex + 1].text == "I")           // …which is left out
    }

    @Test func readerStartsAfterTheWalkUp() throws {
        var words: [TranscriptWord] = []
        var t = 0.0
        for (w, gap) in [("Sarah", 0.1), ("will", 0.1), ("come", 0.1), ("and", 0.1), ("read.", 5.0),
                         ("Isaiah", 0.1), ("forty.", 0.1), ("Comfort,", 0.1), ("comfort", 0.1), ("my", 0.1), ("people.", 2.0)] {
            words.append(TranscriptWord(text: w, startTime: t, endTime: t + 0.3)); t += 0.3 + gap
        }
        for _ in 0..<5 { words.append(TranscriptWord(text: "Thanks", startTime: t, endTime: t + 0.3)); t += 0.4 }
        words.append(TranscriptWord(text: "Amen.", startTime: t, endTime: t + 0.3))
        let s = suggestTrim(words: words, style: HouseStyle(trimStart: .reading))
        let reading = try #require(s.readingStart)
        #expect(words[reading.wordIndex].text == "Isaiah")
        #expect(reading.confidence == .medium)  // no "word of the Lord" or thanks to confirm it
    }
}

// MARK: - Cut refinement against digital silence

@Suite struct DigitalSilenceFloorTests {
    /// The false "forced" from the 2026-11-01 run: a stretch of exact digital silence made the
    /// noise floor −120 dB, so ordinary room tone before the first word looked like sound.
    @Test func roomToneAfterDigitalSilenceIsStillSilence() {
        let fd = 0.01
        var levels: [Float] = []
        levels += Array(repeating: EnergyEnvelope.silenceDB, count: 500)  // 0–5 s: digital silence
        levels += Array(repeating: -68, count: 500)                      // 5–10 s: room tone
        levels += Array(repeating: -20, count: 40)                       // "Good" at 10.0 s
        levels += Array(repeating: -68, count: 60)
        levels += Array(repeating: -20, count: 300)
        let env = EnergyEnvelope(startTime: 0, frameDuration: fd, levelsDB: levels)
        let words = [TranscriptWord(text: "Good", startTime: 10.05, endTime: 10.4),
                     TranscriptWord(text: "morning", startTime: 11.0, endTime: 11.5)]
        let r = CutPointRefiner().refine(edge: .start, wordIndex: 0, words: words, envelope: env)
        #expect(r.quality == .clean)
        #expect(abs(r.noiseFloorDB - -68) < 1)
        #expect(abs(r.time - 9.85) < 0.02)
    }
}
