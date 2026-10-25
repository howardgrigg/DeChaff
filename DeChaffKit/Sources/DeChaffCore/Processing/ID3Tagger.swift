import AVFoundation

extension VoiceIsolationProcessor {

    // MARK: - ID3v2 tagging

    /// Write (or rewrite) all ID3 tags — metadata, artwork, and chapters — into an existing MP3.
    public func writeTags(chapters: [Chapter], metadata: ID3Metadata, to mp3Path: String,
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
        mp3Data = ID3Tag.strip(from: mp3Data)
        var output = ID3Tag.build(chapters: chapters, metadata: metadata, durationMs: durationMs)
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
}
