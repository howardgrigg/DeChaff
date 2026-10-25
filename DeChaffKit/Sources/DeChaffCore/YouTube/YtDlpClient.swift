import Foundation

// MARK: - Data models

public struct VideoEntry: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let durationSeconds: Int?
    public let uploadDate: String   // raw "20240317" from yt-dlp
    public let thumbnailURL: URL?

    public init(id: String, title: String, durationSeconds: Int?, uploadDate: String, thumbnailURL: URL?) {
        self.id = id
        self.title = title
        self.durationSeconds = durationSeconds
        self.uploadDate = uploadDate
        self.thumbnailURL = thumbnailURL
    }
}

public enum YtDlpError: LocalizedError {
    case notInstalled
    case processFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "yt-dlp is not installed. Check Settings."
        case .processFailed(let msg): return msg.isEmpty ? "yt-dlp process failed." : msg
        }
    }
}

// MARK: - Install locations

/// Where the app keeps the yt-dlp and ffmpeg binaries it downloads and updates.
public enum YtDlpPaths {
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("DeChaff")
    }

    public static var binary: URL { supportDirectory.appendingPathComponent("yt-dlp") }

    public static var bundledFFmpeg: URL { supportDirectory.appendingPathComponent("ffmpeg") }

    /// System ffmpeg locations used when no bundled copy exists (Homebrew Apple Silicon / Intel).
    public static let systemFFmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]

    public static var installedBinary: URL? {
        FileManager.default.fileExists(atPath: binary.path) ? binary : nil
    }

    public static var installedFFmpeg: URL? {
        // Prefer bundled ffmpeg in Application Support
        if FileManager.default.fileExists(atPath: bundledFFmpeg.path) { return bundledFFmpeg }
        return systemFFmpegPaths.first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

// MARK: - Client

/// Runs yt-dlp to list a channel's videos and download audio. Holds no UI state —
/// installation and updates are the app's job.
public struct YtDlpClient: Sendable {
    public let binary: URL
    public let ffmpeg: URL?

    public init(binary: URL, ffmpeg: URL?) {
        self.binary = binary
        self.ffmpeg = ffmpeg
    }

    /// A client for the copy the app installed, or nil if yt-dlp isn't installed yet.
    public static var installed: YtDlpClient? {
        YtDlpPaths.installedBinary.map { YtDlpClient(binary: $0, ffmpeg: YtDlpPaths.installedFFmpeg) }
    }

    // MARK: Video list

    public func fetchVideoList(channelURL: String, limit: Int) async throws -> [VideoEntry] {
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--flat-playlist",
            "--dump-json",
            "--playlist-end", "\(limit)",
            "--no-warnings",
            channelURL
        ]
        // PYTHONUNBUFFERED=1 prevents Python's block-buffering on pipes.
        // Without it, output only arrives in ~8 KB chunks instead of line-by-line.
        process.environment = ProcessInfo.processInfo.environment
            .merging(["PYTHONUNBUFFERED": "1"]) { _, new in new }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try process.run()

        var entries: [VideoEntry] = []
        let decoder = JSONDecoder()
        for try await line in outPipe.fileHandleForReading.bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            if let raw = try? decoder.decode(VideoEntryRaw.self, from: data) {
                entries.append(raw.entry)
                if entries.count >= limit {
                    // Stop reading and kill the process — leaving it running with nobody
                    // draining stdout can block it on a full pipe and hang us below.
                    process.terminate()
                    break
                }
            }
        }
        await Self.awaitTermination(of: process)
        if process.terminationStatus != 0 && entries.isEmpty {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw YtDlpError.processFailed(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return entries
    }

    /// Looks up a single video's title and upload date without downloading it.
    public func fetchInfo(url videoURL: String) async throws -> VideoEntry {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--dump-json", "--no-download", "--no-playlist", "--no-warnings", videoURL]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try process.run()
        // Drain before waiting so a large JSON blob can't fill the pipe and deadlock.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        await Self.awaitTermination(of: process)
        guard process.terminationStatus == 0,
              let raw = try? JSONDecoder().decode(VideoEntryRaw.self, from: data) else {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw YtDlpError.processFailed(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return raw.entry
    }

    // MARK: Download

    /// Downloads a URL's audio into the temp directory as `dechaff-yt-<uuid>.<ext>`.
    /// `onStart` receives the running process so callers can terminate it to cancel;
    /// `onLine` receives each line of yt-dlp output (see `parseProgress`).
    public func downloadAudio(
        url videoURL: String,
        onStart: @escaping @Sendable (Process) async -> Void = { _ in },
        onLine:  @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> URL {
        let uuid = UUID().uuidString
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let outputTemplate = tempDir.appendingPathComponent("\(youTubeDownloadPrefix)\(uuid).%(ext)s").path

        // Wrap yt-dlp in /usr/bin/script which allocates a PTY and runs the command
        // inside it. This makes Python think it's writing to a terminal, bypassing
        // PyInstaller's handling that silently swallows all pipe-based stderr output.
        // script writes the PTY output to its own stdout, which we read via outPipe.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        var args: [String] = [
            "-q", "/dev/null",      // quiet mode, discard transcript file
            binary.path,            // yt-dlp binary
            "-x",
            "-f", "bestaudio[ext=m4a]/bestaudio/best",
            "--no-playlist",
            "--no-warnings",
            "--fragment-retries", "10",
            "--retries", "10",
            "--progress",
            "--progress-delta", "1",   // at most one progress line per second
            "--newline",
            "-o", outputTemplate,
        ]
        // Pass bundled ffmpeg so yt-dlp can stitch fragmented live-stream VODs
        if let ffmpeg {
            args += ["--ffmpeg-location", ffmpeg.path]
        }
        args.append(videoURL)
        process.arguments = args
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        let (stream, continuation) = AsyncStream<String>.makeStream()
        var lineBuffer = ""
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                if !lineBuffer.isEmpty { continuation.yield(Self.stripANSI(lineBuffer)) }
                continuation.finish()
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            lineBuffer += text
            var parts = lineBuffer.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            lineBuffer = parts.removeLast()
            for part in parts where !part.trimmingCharacters(in: .whitespaces).isEmpty {
                continuation.yield(Self.stripANSI(part))
            }
        }

        try process.run()
        await onStart(process)

        var outputLines: [String] = []
        for await line in stream {
            outputLines.append(line)
            await onLine(line)
        }
        await Self.awaitTermination(of: process)

        guard process.terminationStatus == 0 else {
            // outputLines contains all PTY output; filter to lines that look like errors
            let errorPrefixes = ["ERROR:", "error:", "Warning:"]
            let errorLines = outputLines.filter { line in
                errorPrefixes.contains(where: { line.hasPrefix($0) }) ||
                (!line.hasPrefix("[download]") && !line.hasPrefix("[youtube]") &&
                 !line.hasPrefix("[info]") && !line.hasPrefix("[ExtractAudio]"))
            }
            let msg = errorLines
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
            throw YtDlpError.processFailed(msg.isEmpty
                ? "yt-dlp exited with status \(process.terminationStatus)"
                : msg)
        }

        // Locate the output file (extension determined by yt-dlp)
        let files = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
        guard let outputURL = files.first(where: { $0.lastPathComponent.hasPrefix("\(youTubeDownloadPrefix)\(uuid)") }) else {
            throw YtDlpError.processFailed("Download completed but output file not found")
        }
        return outputURL
    }

    // MARK: Helpers

    /// Parses a yt-dlp progress line like "[download]  47.3% of …" → 0.473
    public static func parseProgress(_ line: String) -> Double? {
        // Match e.g. "[download]  47.3%" or "[download] 100%"
        guard line.contains("[download]") else { return nil }
        let parts = line.components(separatedBy: .whitespaces)
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("%"), let pct = Double(trimmed.dropLast()) {
                return pct / 100.0
            }
        }
        return nil
    }

    /// Strips ANSI escape sequences (e.g. \u{1B}[K) produced by PTY output.
    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    /// Waits for a Process to exit without blocking the current thread.
    public static func awaitTermination(of process: Process) async {
        // A handler installed after the process has already exited never fires, so:
        // install the handler first, then re-check isRunning to close the race.
        // Both paths can end up eligible to resume — guard with a locked flag.
        final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func run(_ body: () -> Void) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                body()
            }
        }
        let once = ResumeOnce()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                once.run { continuation.resume() }
            }
            if !process.isRunning {
                once.run { continuation.resume() }
            }
        }
    }
}

// MARK: - Private decodable models

private struct VideoEntryRaw: Decodable {
    let id: String
    let title: String
    let duration: Double?
    let upload_date: String?

    var entry: VideoEntry {
        // YouTube thumbnail URLs are predictable from the video ID — more reliable
        // than the thumbnail field in --flat-playlist output which is often absent.
        VideoEntry(id: id, title: title, durationSeconds: duration.map { Int($0) },
                   uploadDate: upload_date ?? "",
                   thumbnailURL: URL(string: "https://img.youtube.com/vi/\(id)/mqdefault.jpg"))
    }
}
