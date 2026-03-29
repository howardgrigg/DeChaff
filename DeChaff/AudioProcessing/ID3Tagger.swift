import AVFoundation

extension VoiceIsolationProcessor {

    // MARK: - ID3v2 tagging

    /// Write (or rewrite) all ID3 tags — metadata, artwork, and chapters — into an existing MP3.
    func writeTags(chapters: [Chapter], metadata: ID3Metadata, to mp3Path: String,
                   logHandler: @escaping (String) -> Void) {
        self.logHandler = logHandler
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: mp3Path)) else {
            logHandler("⚠️ Could not read file for tagging"); return
        }
        let durationMs = UInt32((Double(file.length) / file.fileFormat.sampleRate) * 1000.0)
        let url = URL(fileURLWithPath: mp3Path)
        guard var mp3Data = try? Data(contentsOf: url) else {
            logHandler("⚠️ Could not read MP3 for tagging"); return
        }
        mp3Data = stripID3v2Header(from: mp3Data)
        var output = buildID3v2Tag(chapters: chapters, metadata: metadata, durationMs: durationMs)
        output.append(mp3Data)
        do {
            try output.write(to: url, options: .atomic)
            var parts: [String] = []
            if !chapters.isEmpty { parts.append("\(chapters.count) chapter\(chapters.count == 1 ? "" : "s")") }
            if metadata.artwork != nil { parts.append("artwork") }
            let hasText = !metadata.title.isEmpty || !metadata.artist.isEmpty || !metadata.album.isEmpty
            if hasText { parts.append("tags") }
            logHandler("🔖 Saved \(parts.isEmpty ? "ID3 tag" : parts.joined(separator: ", "))")
        } catch {
            logHandler("⚠️ Tag write failed: \(error.localizedDescription)")
        }
    }

    func buildID3v2Tag(chapters: [Chapter], metadata: ID3Metadata, durationMs: UInt32) -> Data {
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
                    var tit2 = Data([0x03])
                    tit2.append(contentsOf: chapter.title.utf8)
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

    private func makeTextFrame(_ id: String, _ text: String) -> Data {
        var body = Data([0x03])  // UTF-8
        body.append(contentsOf: text.utf8)
        return makeID3Frame(id: id, body: body)
    }

    /// Builds a single ID3v2.3 frame. Frame size is plain big-endian (NOT syncsafe — that's v2.4).
    private func makeID3Frame(id: String, body: Data) -> Data {
        var frame = Data(id.utf8.prefix(4))
        frame.append(contentsOf: toBE32(UInt32(body.count)))
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(body)
        return frame
    }

    func stripID3v2Header(from data: Data) -> Data {
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return data }
        let size = (UInt32(data[6] & 0x7F) << 21) | (UInt32(data[7] & 0x7F) << 14)
                 | (UInt32(data[8] & 0x7F) <<  7) |  UInt32(data[9] & 0x7F)
        let end = Int(10 + size)
        guard end <= data.count else { return data }
        return data.subdata(in: end..<data.count)
    }

    func toBE32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    func toSyncsafe32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
    }
}
