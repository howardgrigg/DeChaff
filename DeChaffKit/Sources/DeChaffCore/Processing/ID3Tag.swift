import Foundation

/// Builds and reads the ID3v2.3 tags DeChaff writes: text frames, cover art and
/// CTOC/CHAP chapter frames.
public enum ID3Tag {

    // MARK: - Building

    public static func build(chapters: [Chapter], metadata: ID3Metadata, durationMs: UInt32) -> Data {
        var frames = Data()

        // Text frames
        if !metadata.title.isEmpty  { frames.append(makeTextFrame("TIT2", metadata.title)) }
        if !metadata.artist.isEmpty { frames.append(makeTextFrame("TPE1", metadata.artist)) }
        if !metadata.album.isEmpty  { frames.append(makeTextFrame("TALB", metadata.album)) }
        if !metadata.year.isEmpty   { frames.append(makeTextFrame("TYER", metadata.year)) }

        // Album art (APIC — Cover front)
        if let art = metadata.artwork {
            var body = Data([0x00])                    // encoding: Latin-1 (for MIME string)
            body.append(contentsOf: "image/jpeg".utf8)
            body.append(0x00)                          // null-terminate MIME
            body.append(0x03)                          // picture type: Cover (front)
            body.append(0x00)                          // description: empty, null-terminated
            body.append(art)
            frames.append(makeID3Frame(id: "APIC", body: body))
        }

        // Chapter frames
        if !chapters.isEmpty {
            let sorted = chapters.sorted { $0.timeSeconds < $1.timeSeconds }
            let chapIDs = sorted.indices.map { "ch\($0)" }

            var ctoc = Data()
            ctoc.append(contentsOf: "toc".utf8); ctoc.append(0x00)
            ctoc.append(0x03)
            ctoc.append(UInt8(sorted.count))
            for cid in chapIDs { ctoc.append(contentsOf: cid.utf8); ctoc.append(0x00) }
            frames.append(makeID3Frame(id: "CTOC", body: ctoc))

            for (i, chapter) in sorted.enumerated() {
                let startMs = UInt32(max(0, chapter.timeSeconds) * 1000)
                let endMs   = i + 1 < sorted.count
                    ? UInt32(max(0, sorted[i + 1].timeSeconds) * 1000) : durationMs
                var chap = Data()
                chap.append(contentsOf: chapIDs[i].utf8); chap.append(0x00)
                chap.append(contentsOf: toBE32(startMs))
                chap.append(contentsOf: toBE32(endMs))
                chap.append(contentsOf: toBE32(0xFFFF_FFFF))
                chap.append(contentsOf: toBE32(0xFFFF_FFFF))
                if !chapter.title.isEmpty {
                    var tit2 = Data([0x01])  // UTF-16 with BOM — the only Unicode encoding ID3v2.3 defines
                    tit2.append(utf16WithBOM(chapter.title))
                    chap.append(makeID3Frame(id: "TIT2", body: tit2))
                }
                frames.append(makeID3Frame(id: "CHAP", body: chap))
            }
        }

        var tag = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00])
        tag.append(contentsOf: toSyncsafe32(UInt32(frames.count)))
        tag.append(frames)
        return tag
    }

    /// Removes a leading ID3v2 tag, returning the audio that follows it.
    public static func strip(from data: Data) -> Data {
        guard let size = tagSize(data) else { return data }
        return data.subdata(in: data.startIndex + size..<data.endIndex)
    }

    private static func makeTextFrame(_ id: String, _ text: String) -> Data {
        var body = Data([0x01])  // UTF-16 with BOM — the only Unicode encoding ID3v2.3 defines
        body.append(utf16WithBOM(text))
        return makeID3Frame(id: id, body: body)
    }

    /// Little-endian BOM (FF FE) followed by UTF-16LE code units.
    private static func utf16WithBOM(_ text: String) -> Data {
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian) ?? Data())
        return data
    }

    /// Builds a single ID3v2.3 frame. Frame size is plain big-endian (NOT syncsafe — that's v2.4).
    private static func makeID3Frame(id: String, body: Data) -> Data {
        var frame = Data(id.utf8.prefix(4))
        frame.append(contentsOf: toBE32(UInt32(body.count)))
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(body)
        return frame
    }

    static func toBE32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func toSyncsafe32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
    }

    // MARK: - Reading

    public struct Contents: Sendable {
        public var version: Int
        /// Text frames by ID, e.g. "TIT2" → title.
        public var text: [String: String] = [:]
        public var artwork: Data?
        public var artworkMIME: String?
        public var chapters: [ReadChapter] = []
    }

    public struct ReadChapter: Sendable {
        public var id: String
        public var startSeconds: Double
        public var endSeconds: Double
        public var title: String
    }

    /// Total size (header + frames) of a leading ID3v2 tag, or nil if there isn't one.
    public static func tagSize(_ data: Data) -> Int? {
        let b = [UInt8](data.prefix(10))
        guard b.count == 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return nil }
        let size = (Int(b[6] & 0x7F) << 21) | (Int(b[7] & 0x7F) << 14) | (Int(b[8] & 0x7F) << 7) | Int(b[9] & 0x7F)
        let total = 10 + size
        return total <= data.count ? total : nil
    }

    /// Reads text frames, cover art and chapters from a leading ID3v2.3/2.4 tag.
    public static func read(_ data: Data) -> Contents? {
        guard let total = tagSize(data) else { return nil }
        let bytes = [UInt8](data.prefix(total))
        let version = Int(bytes[3])
        guard version == 3 || version == 4 else { return Contents(version: version) }
        var contents = Contents(version: version)
        parseFrames(bytes, from: 10, to: total, version: version, into: &contents)
        contents.chapters.sort { $0.startSeconds < $1.startSeconds }
        return contents
    }

    private static func parseFrames(_ b: [UInt8], from start: Int, to end: Int, version: Int,
                                    into contents: inout Contents, chapter: Int? = nil) {
        var pos = start
        while pos + 10 <= end {
            let idBytes = b[pos..<pos + 4]
            guard idBytes.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) }) else { break }  // padding
            let id = String(decoding: idBytes, as: UTF8.self)
            let size = version == 4
                ? (Int(b[pos + 4] & 0x7F) << 21) | (Int(b[pos + 5] & 0x7F) << 14) | (Int(b[pos + 6] & 0x7F) << 7) | Int(b[pos + 7] & 0x7F)
                : (Int(b[pos + 4]) << 24) | (Int(b[pos + 5]) << 16) | (Int(b[pos + 6]) << 8) | Int(b[pos + 7])
            let bodyStart = pos + 10
            let bodyEnd = bodyStart + size
            guard size >= 0, bodyEnd <= end else { break }
            let body = Array(b[bodyStart..<bodyEnd])

            if let ci = chapter {
                // Sub-frames inside a CHAP: only the title matters.
                if id == "TIT2" { contents.chapters[ci].title = decodeText(body) }
            } else if id.hasPrefix("T") && id != "TXXX" {
                contents.text[id] = decodeText(body)
            } else if id == "APIC", !body.isEmpty {
                var p = 1
                let mimeEnd = body[p...].firstIndex(of: 0) ?? body.endIndex
                contents.artworkMIME = String(decoding: body[p..<mimeEnd], as: UTF8.self)
                p = mimeEnd + 2  // skip null + picture type
                p = skipTerminatedString(body, from: p, encoding: body[0])
                contents.artwork = p < body.count ? Data(body[p...]) : Data()
            } else if id == "CHAP", let idEnd = body.firstIndex(of: 0), idEnd + 17 <= body.count {
                let be32 = { (i: Int) -> UInt32 in
                    (UInt32(body[i]) << 24) | (UInt32(body[i + 1]) << 16) | (UInt32(body[i + 2]) << 8) | UInt32(body[i + 3])
                }
                contents.chapters.append(ReadChapter(
                    id: String(decoding: body[0..<idEnd], as: UTF8.self),
                    startSeconds: Double(be32(idEnd + 1)) / 1000,
                    endSeconds: Double(be32(idEnd + 5)) / 1000,
                    title: ""))
                let sub = bodyStart + idEnd + 17
                parseFrames(b, from: sub, to: bodyEnd, version: version, into: &contents,
                            chapter: contents.chapters.count - 1)
            }
            pos = bodyEnd
        }
    }

    private static func skipTerminatedString(_ body: [UInt8], from p: Int, encoding: UInt8) -> Int {
        var i = p
        if encoding == 1 || encoding == 2 {
            while i + 1 < body.count, !(body[i] == 0 && body[i + 1] == 0) { i += 2 }
            return min(i + 2, body.count)
        }
        while i < body.count, body[i] != 0 { i += 1 }
        return min(i + 1, body.count)
    }

    private static func decodeText(_ body: [UInt8]) -> String {
        guard let enc = body.first else { return "" }
        var payload = Array(body.dropFirst())
        let string: String
        switch enc {
        case 1:  // UTF-16 with BOM
            var littleEndian = true
            if payload.count >= 2 {
                if payload[0] == 0xFE && payload[1] == 0xFF { littleEndian = false; payload.removeFirst(2) }
                else if payload[0] == 0xFF && payload[1] == 0xFE { payload.removeFirst(2) }
            }
            string = String(data: Data(payload), encoding: littleEndian ? .utf16LittleEndian : .utf16BigEndian) ?? ""
        case 2:  // UTF-16BE (v2.4)
            string = String(data: Data(payload), encoding: .utf16BigEndian) ?? ""
        case 3:  // UTF-8 (v2.4)
            string = String(decoding: payload, as: UTF8.self)
        default: // ISO-8859-1
            string = String(data: Data(payload), encoding: .isoLatin1) ?? ""
        }
        return string.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}
