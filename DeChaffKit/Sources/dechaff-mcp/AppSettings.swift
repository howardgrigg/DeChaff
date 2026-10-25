import Foundation
import CryptoKit
import MCPServer
import DeChaffCore

/// The DeChaff app's saved preferences, read from its defaults domain so the server
/// uses the same channel, templates, compressor settings and artwork as the app.
struct AppSettings {
    static let appDomain = "com.dechaff.app"
    /// Embedded in DeChaff.app the main bundle *is* the app, and its own domain is
    /// `.standard` (UserDefaults won't open your own bundle ID as a suite).
    private let defaults = Bundle.main.bundleIdentifier == AppSettings.appDomain
        ? .standard
        : (UserDefaults(suiteName: AppSettings.appDomain) ?? .standard)

    var channelURL: String { defaults.string(forKey: "dechaff.youtube.channelURL") ?? "https://www.youtube.com/@cityonahillnz" }
    var videoLimit: Int { (defaults.object(forKey: "dechaff.youtube.videoLimit") as? Int) ?? 10 }
    var titleFormat: String { defaults.string(forKey: "dechaff.titleFormat") ?? defaultTitleFormat }
    var filenameTemplate: String { defaults.string(forKey: "dechaff.filenameTemplate") ?? defaultFilenameTemplate }
    /// The church's own instructions for the assistant, from Settings → MCP.
    var assistantInstructions: String {
        (defaults.string(forKey: "dechaff.mcp.instructions") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The AI Assistant prompt from Settings → AI Assistant, when the assistant is on
    /// and the user has saved a prompt. The MCP client is itself an AI, so it follows
    /// this directly instead of the app calling the Claude API.
    var aiAssistantPrompt: String? {
        guard defaults.bool(forKey: "dechaff.ai.enabled"),
              let prompt = defaults.string(forKey: "dechaff.ai.prompt"),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return prompt
    }
    var lastPreacher: String { defaults.string(forKey: "dechaff.preacher") ?? "" }
    var lastSeries: String { defaults.string(forKey: "dechaff.series") ?? "" }
    /// Cover art the app keeps between episodes — it's changed when the series changes.
    var artwork: Data? { defaults.data(forKey: "dechaff.artwork") }

    /// Remembers what an episode used, as the app does when these fields are edited,
    /// so the next episode — in the app or here — starts from them.
    func rememberLastUsed(preacher: String, series: String, artwork: Data?) {
        if !preacher.isEmpty { defaults.set(preacher, forKey: "dechaff.preacher") }
        if !series.isEmpty { defaults.set(series, forKey: "dechaff.series") }
        if let artwork { defaults.set(artwork, forKey: "dechaff.artwork") }
    }

    private func double(_ key: String, _ fallback: Double) -> Double {
        (defaults.object(forKey: key) as? Double) ?? fallback
    }

    var compressorThreshold: Double  { double("dechaff.compressor.threshold", -28.0) }
    var compressorHeadRoom: Double   { double("dechaff.compressor.headRoom", 6.0) }
    var compressorAttack: Double     { double("dechaff.compressor.attack", 0.003) }
    var compressorRelease: Double    { double("dechaff.compressor.release", 0.150) }
    var compressorMakeupGain: Double { double("dechaff.compressor.makeupGain", 8.0) }

    /// The LAME encoder: $DECHAFF_LAME, the copy bundled in DeChaff.app, or a Homebrew install.
    var lamePath: String? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["DECHAFF_LAME"] { candidates.append(env) }
        // Running from inside DeChaff.app/Contents/MacOS: the app's Resources sit beside us.
        if let bundled = Bundle.main.path(forResource: "lame", ofType: nil) { candidates.append(bundled) }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exe.deletingLastPathComponent()
                .appendingPathComponent("../Resources/lame").standardizedFileURL.path)
        }
        candidates += [
            "/Applications/DeChaff.app/Contents/Resources/lame",
            NSHomeDirectory() + "/Applications/DeChaff.app/Contents/Resources/lame",
            "/opt/homebrew/bin/lame",
            "/usr/local/bin/lame",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var json: JSONValue {
        [
            "youtube_channel_url": .string(channelURL),
            "youtube_video_limit": .number(Double(videoLimit)),
            "title_format": .string(titleFormat),
            "filename_template": .string(filenameTemplate),
            "church_instructions": .string(assistantInstructions),
            "last_preacher": .string(lastPreacher),
            "last_series": .string(lastSeries),
            "artwork": artwork.map { art -> JSONValue in
                var o: [String: JSONValue] = [
                    "saved": true, "bytes": .number(Double(art.count)),
                    "note": "The app reuses this until it's changed for a new series. Call get_artwork to see it.",
                ]
                if let size = imageSize(art) {
                    o["width"] = .number(Double(size.width)); o["height"] = .number(Double(size.height))
                }
                return .object(o)
            } ?? ["saved": false],
            "compressor": [
                "threshold_db": .number(compressorThreshold), "headroom_db": .number(compressorHeadRoom),
                "attack_seconds": .number(compressorAttack), "release_seconds": .number(compressorRelease),
                "makeup_gain_db": .number(compressorMakeupGain),
            ],
            "tools": [
                "lame": JSONValue(lamePath),
                "yt_dlp": JSONValue(YtDlpPaths.installedBinary?.path),
                "ffmpeg": JSONValue(YtDlpPaths.installedFFmpeg?.path),
            ],
        ]
    }
}

/// Word-level transcripts, kept in memory and cached on disk so a file is only
/// transcribed once. The cache key includes size and modification date, so an
/// edited file is transcribed afresh.
actor TranscriptStore {
    private var memory: [String: [TranscriptWord]] = [:]

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DeChaff/transcripts", isDirectory: true)
    }

    func words(for url: URL) -> [TranscriptWord]? {
        guard let key = Self.key(for: url) else { return nil }
        if let words = memory[key] { return words }
        guard let data = try? Data(contentsOf: Self.cacheDirectory.appendingPathComponent(key + ".json")),
              let words = try? JSONDecoder().decode([TranscriptWord].self, from: data) else { return nil }
        memory[key] = words
        return words
    }

    func save(_ words: [TranscriptWord], for url: URL) {
        guard let key = Self.key(for: url) else { return }
        memory[key] = words
        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(words) {
            try? data.write(to: Self.cacheDirectory.appendingPathComponent(key + ".json"), options: .atomic)
        }
    }

    private static func key(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(url.path)|\(size)|\(modified)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
