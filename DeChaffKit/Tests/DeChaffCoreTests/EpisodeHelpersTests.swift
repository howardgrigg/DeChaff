import Foundation
import Testing
@testable import DeChaffCore

@Suite struct ID3TagTests {
    @Test func roundTripsTextArtworkAndChapters() throws {
        let metadata = ID3Metadata(title: "The Good Shepherd, John 10:1–18", artist: "Rev. Ōtaki",
                                   album: "Foundations", year: "2026", artwork: Data(repeating: 0xAB, count: 1234))
        let chapters = [Chapter(timeSeconds: 125.5, title: "Point two — “sheep”"),
                        Chapter(timeSeconds: 0, title: "Introduction")]
        let tag = ID3Tag.build(chapters: chapters, metadata: metadata, durationMs: 1_800_000)
        var file = tag
        file.append(Data([0xFF, 0xFB, 0x90, 0x00]))  // the start of an MP3 frame

        let read = try #require(ID3Tag.read(file))
        #expect(read.version == 3)
        #expect(read.text["TIT2"] == metadata.title)
        #expect(read.text["TPE1"] == metadata.artist)
        #expect(read.text["TALB"] == "Foundations")
        #expect(read.text["TYER"] == "2026")
        #expect(read.artwork == Data(repeating: 0xAB, count: 1234))
        #expect(read.artworkMIME == "image/jpeg")
        #expect(read.chapters.map(\.title) == ["Introduction", "Point two — “sheep”"])
        #expect(read.chapters.map(\.startSeconds) == [0, 125.5])
        #expect(read.chapters.map(\.endSeconds) == [125.5, 1800])

        #expect(ID3Tag.strip(from: file) == Data([0xFF, 0xFB, 0x90, 0x00]))
    }

    @Test func untaggedDataIsLeftAlone() {
        let audio = Data([0xFF, 0xFB, 0x90, 0x00])
        #expect(ID3Tag.read(audio) == nil)
        #expect(ID3Tag.strip(from: audio) == audio)
    }
}

@Suite struct FilenameTemplateTests {
    let values = ["date": "2026-04-06", "title": "The Good Shepherd", "reading": "John 10:1–18",
                  "preacher": "Rev. James Hart", "series": ""]

    @Test func dropsEmptySegmentsAndSanitises() {
        #expect(FilenameTemplate.resolve(defaultFilenameTemplate, values: values)
                == "2026-04-06 The Good Shepherd, John 10-1–18 | Rev. James Hart")
    }

    @Test func allEmptyIsNil() {
        #expect(FilenameTemplate.resolve("{title} | {series}", values: ["title": "", "series": ""]) == nil)
    }
}

@Suite struct SermonTitleTemplateTests {
    @Test func parsesDefaultFormat() throws {
        let p = try #require(parseSermonTitle("Living Hope, 1 Peter 1:3–9 | Jane Doe | Exiles | 23 Mar 2025",
                                              format: defaultTitleFormat))
        #expect(p == ParsedSermonTitle(title: "Living Hope", reading: "1 Peter 1:3–9", preacher: "Jane Doe",
                                       series: "Exiles", date: "23 Mar 2025"))
    }

    @Test func toleratesMissingTrailingFields() throws {
        let p = try #require(parseSermonTitle("Living Hope, 1 Peter 1:3–9 | Jane Doe", format: defaultTitleFormat))
        #expect(p.preacher == "Jane Doe")
        #expect(p.series.isEmpty)
    }

    @Test func toleratesSpacingAroundSeparators() throws {
        let p = try #require(parseSermonTitle(
            "A Story of Mercy for All, Romans 11 | Andrew Southerton | The Power of the Gospel| 25/10/2026",
            format: defaultTitleFormat))
        #expect(p == ParsedSermonTitle(title: "A Story of Mercy for All", reading: "Romans 11",
                                       preacher: "Andrew Southerton", series: "The Power of the Gospel",
                                       date: "25/10/2026"))
    }

    @Test func parsesUploadDates() {
        #expect(parseYouTubeUploadDate("20240317") != nil)
        #expect(parseYouTubeUploadDate("2024031") == nil)
        #expect(parseYouTubeUploadDate("20241317") == nil)
    }
}

@Suite struct ChapterRemapTests {
    // 10–14 s is silent; 1 s of it is kept, so 3 s are removed from 10 to 13.
    let segments = [SilenceSegment(startSeconds: 10, endSeconds: 14, keptSeconds: 1)]

    @Test func shiftsChaptersAfterRemovedSilence() {
        #expect(remapChapterTime(5, using: segments) == 5)
        #expect(remapChapterTime(20, using: segments) == 17)
    }

    @Test func chaptersInsideRemovedSilenceSnapToItsEnd() {
        #expect(remapChapterTime(12, using: segments) == 10)
    }
}

@Suite struct EpisodePlanTests {
    private func plan(editedBy: EpisodePlan.Editor = .assistant) -> EpisodePlan {
        EpisodePlan(sourcePath: "/tmp/service.m4a", trimIn: 2486, trimOut: 4790,
                    excluded: [.init(start: 3000, end: 3060)],
                    chapters: [.init(time: 2486, title: "Reading: Romans 11"), .init(time: 2800, title: "Sermon")],
                    title: "A Story of Mercy for All", reading: "Romans 11", preacher: "Andrew Southerton",
                    series: "The Power of the Gospel", date: Date(timeIntervalSince1970: 1_793_000_000),
                    artwork: Data([1, 2, 3]), editedBy: editedBy)
    }

    @Test func roundTripsThroughJSON() throws {
        let original = plan()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(EpisodePlan.self, from: try encoder.encode(original))
        #expect(decoded.hasSameContent(as: original))
        #expect(decoded.editedBy == .assistant)
    }

    @Test func sameContentIgnoresWhoSavedItAndWhen() {
        var a = plan(editedBy: .assistant), b = plan(editedBy: .app)
        b.updatedAt = a.updatedAt.addingTimeInterval(60)
        #expect(a.hasSameContent(as: b))
        a.chapters[1].time = 2801
        #expect(!a.hasSameContent(as: b))
    }

    @Test func processingIsNotAContentChange() {
        let a = plan()
        var b = a
        b.processedOutput = "/tmp/episode.mp3"
        #expect(a.hasSameContent(as: b))
    }
}
