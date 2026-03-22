import Foundation

// MARK: - Data models

struct VideoEntry: Identifiable {
    let id: String
    let title: String
    let durationSeconds: Int?
    let uploadDate: String   // raw "20240317" from yt-dlp
    let thumbnailURL: URL?
}

enum YtDlpInstallStatus {
    case notInstalled
    case checking
    case downloading(progress: Double)
    case installed(version: String)
    case error(String)
}

// MARK: - YtDlpManager

@MainActor
class YtDlpManager: ObservableObject {

    @Published var installStatus: YtDlpInstallStatus = .notInstalled
    @Published var downloadLog: [String] = []
    @Published var downloadProgress: Double? = nil   // nil = not downloading; 0.0–1.0 = in progress

    private var activeDownloadProcess: Process?

    func cancelDownload() {
        activeDownloadProcess?.terminate()
        activeDownloadProcess = nil
    }

    func cleanupTempFiles() {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let files = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("dechaff-yt-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Paths

    private static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("DeChaff")
    }

    private static var binaryPath: URL {
        supportDir.appendingPathComponent("yt-dlp")
    }

    private static var ffmpegPath: URL {
        supportDir.appendingPathComponent("ffmpeg")
    }

    var binaryURL: URL? {
        let url = Self.binaryPath
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var ffmpegURL: URL? {
        // Prefer bundled ffmpeg in Application Support
        let bundled = Self.ffmpegPath
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        // Fall back to system ffmpeg (Homebrew Apple Silicon / Intel)
        let systemPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        for path in systemPaths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    // MARK: - Version check & auto-update

    func checkAndUpdate() async {
        installStatus = .checking
        do {
            // Download yt-dlp if needed
            let release = try await fetchLatestRelease()
            let storedVersion = UserDefaults.standard.string(forKey: "dechaff.ytdlp.version") ?? ""
            if release.tag_name == storedVersion, let bin = binaryURL, isBinaryWorking(bin) {
                installStatus = .installed(version: release.tag_name)
            } else {
                // Stored version doesn't match, binary missing, or binary is broken — re-download
                UserDefaults.standard.removeObject(forKey: "dechaff.ytdlp.version")
                if let zipAsset = release.assets.first(where: { $0.name == "yt-dlp_macos.zip" }) {
                    try await downloadBundle(from: zipAsset.browser_download_url, version: release.tag_name)
                } else if let asset = release.assets.first(where: { $0.name == "yt-dlp_macos" })
                                   ?? release.assets.first(where: { $0.name == "yt-dlp" }) {
                    try await downloadBinary(from: asset.browser_download_url, version: release.tag_name)
                } else {
                    installStatus = .error("No compatible binary found in release \(release.tag_name)")
                    return
                }
            }

            // Download ffmpeg if not already bundled (needed to stitch DASH live-stream fragments)
            if !FileManager.default.fileExists(atPath: Self.ffmpegPath.path) {
                try await downloadFFmpeg()
                // Restore installed status after ffmpeg download (may have overwritten it with .downloading)
                if case .installed = installStatus {} else {
                    let v = UserDefaults.standard.string(forKey: "dechaff.ytdlp.version") ?? ""
                    installStatus = .installed(version: v)
                }
            }
        } catch {
            installStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Fetch video list

    func fetchVideoList(channelURL: String, limit: Int) async throws -> [VideoEntry] {
        guard let bin = binaryURL else { throw YtDlpError.notInstalled }
        let process = Process()
        process.executableURL = bin
        process.arguments = [
            "--flat-playlist",
            "--dump-json",
            "--playlist-end", "\(limit)",
            "--no-warnings",
            channelURL
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        try process.run()

        var entries: [VideoEntry] = []
        let decoder = JSONDecoder()
        for try await line in outPipe.fileHandleForReading.bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            if let raw = try? decoder.decode(VideoEntryRaw.self, from: data) {
                // YouTube thumbnail URLs are predictable from the video ID — more reliable
                // than the thumbnail field in --flat-playlist output which is often absent.
                let thumbnailURL = URL(string: "https://img.youtube.com/vi/\(raw.id)/mqdefault.jpg")
                entries.append(VideoEntry(
                    id: raw.id,
                    title: raw.title,
                    durationSeconds: raw.duration,
                    uploadDate: raw.upload_date ?? "",
                    thumbnailURL: thumbnailURL
                ))
                if entries.count >= limit { break }  // enforce limit in case --playlist-end is unreliable
            }
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 && entries.isEmpty {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw YtDlpError.processFailed(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return entries
    }

    // MARK: - Download audio

    func downloadAudio(videoID: String) async throws -> URL {
        guard let bin = binaryURL else { throw YtDlpError.notInstalled }
        let uuid = UUID().uuidString
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let outputTemplate = tempDir.appendingPathComponent("dechaff-yt-\(uuid).%(ext)s").path

        // Wrap yt-dlp in /usr/bin/script which allocates a PTY and runs the command
        // inside it. This makes Python think it's writing to a terminal, bypassing
        // PyInstaller's handling that silently swallows all pipe-based stderr output.
        // script writes the PTY output to its own stdout, which we read via outPipe.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        var args: [String] = [
            "-q", "/dev/null",      // quiet mode, discard transcript file
            bin.path,               // yt-dlp binary
            "-x",
            "-f", "bestaudio[ext=m4a]/bestaudio/best",
            "--no-playlist",
            "--no-warnings",
            "--fragment-retries", "10",
            "--retries", "10",
            "--progress",
            "--newline",
            "-o", outputTemplate,
        ]
        // Pass bundled ffmpeg so yt-dlp can stitch fragmented live-stream VODs
        if let ffmpeg = ffmpegURL {
            args += ["--ffmpeg-location", ffmpeg.path]
        }
        args.append("https://youtu.be/\(videoID)")
        process.arguments = args
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

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

        downloadLog = []
        downloadProgress = 0
        activeDownloadProcess = process
        try process.run()

        var outputLines: [String] = []
        for await line in stream {
            outputLines.append(line)
            downloadLog.append(line)
            if let pct = Self.parseProgress(line) {
                downloadProgress = pct
            }
        }
        downloadProgress = nil
        process.waitUntilExit()
        activeDownloadProcess = nil

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
        guard let outputURL = files.first(where: { $0.lastPathComponent.hasPrefix("dechaff-yt-\(uuid)") }) else {
            throw YtDlpError.processFailed("Download completed but output file not found")
        }
        return outputURL
    }

    // MARK: - Private helpers

    /// Runs `yt-dlp --version` and returns true if it exits 0.
    private func isBinaryWorking(_ bin: URL) -> Bool {
        let p = Process()
        p.executableURL = bin
        p.arguments = ["--version"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Strips ANSI escape sequences (e.g. \u{1B}[K) produced by PTY output.
    private nonisolated static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    /// Parses a yt-dlp progress line like "[download]  47.3% of …" → 0.473
    private nonisolated static func parseProgress(_ line: String) -> Double? {
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

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func downloadBundle(from url: URL, version: String) async throws {
        try FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        let totalBytes = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Length").flatMap { Int($0) } ?? 0

        let zipURL = Self.supportDir.appendingPathComponent("yt-dlp.zip.download")
        FileManager.default.createFile(atPath: zipURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: zipURL)
        defer { try? handle.close() }

        var received = 0
        var buffer = Data(capacity: 256 * 1024)
        for try await byte in asyncBytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 256 * 1024 {
                handle.write(buffer)
                buffer.removeAll(keepingCapacity: true)
                if totalBytes > 0 {
                    installStatus = .downloading(progress: Double(received) / Double(totalBytes))
                }
            }
        }
        if !buffer.isEmpty { handle.write(buffer) }
        try? handle.close()

        // Extract zip into a temp subdirectory then move binaries into place
        let extractDir = Self.supportDir.appendingPathComponent("yt-dlp.unzip")
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", zipURL.path, "-d", extractDir.path]
        unzip.standardOutput = Pipe()
        unzip.standardError = Pipe()
        try unzip.run()
        unzip.waitUntilExit()
        try? FileManager.default.removeItem(at: zipURL)

        // Move ALL extracted contents into supportDir, replacing anything already there.
        // This preserves _Internal/ (required by PyInstaller onedir bundles) alongside the binary.
        let extracted = (try? FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)) ?? []
        let executableNames: Set<String> = ["yt-dlp", "yt-dlp_macos", "ffmpeg", "ffprobe"]
        for item in extracted {
            let dest = Self.supportDir.appendingPathComponent(item.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try? FileManager.default.moveItem(at: item, to: dest)
            if executableNames.contains(item.lastPathComponent) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
        }
        try? FileManager.default.removeItem(at: extractDir)
        // Ensure yt-dlp is at the canonical path — zip names the binary yt-dlp_macos
        if !FileManager.default.fileExists(atPath: Self.binaryPath.path) {
            let alt = Self.supportDir.appendingPathComponent("yt-dlp_macos")
            if FileManager.default.fileExists(atPath: alt.path) {
                try? FileManager.default.copyItem(at: alt, to: Self.binaryPath)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.binaryPath.path)
            }
        }

        UserDefaults.standard.set(version, forKey: "dechaff.ytdlp.version")
        installStatus = .installed(version: version)
    }

    private func downloadBinary(from url: URL, version: String) async throws {
        try FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        let totalBytes = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Length").flatMap { Int($0) } ?? 0

        let tempURL = Self.supportDir.appendingPathComponent("yt-dlp.download")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        var received = 0
        var buffer = Data(capacity: 256 * 1024)
        for try await byte in asyncBytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 256 * 1024 {
                handle.write(buffer)
                buffer.removeAll(keepingCapacity: true)
                if totalBytes > 0 {
                    let p = Double(received) / Double(totalBytes)
                    installStatus = .downloading(progress: p)
                }
            }
        }
        if !buffer.isEmpty { handle.write(buffer) }

        let finalURL = Self.binaryPath
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: finalURL.path)
        UserDefaults.standard.set(version, forKey: "dechaff.ytdlp.version")
        installStatus = .installed(version: version)
    }

    /// Downloads a static ffmpeg binary from yt-dlp/FFmpeg-Builds (GitHub).
    /// Extracts it and places it at `supportDir/ffmpeg`.
    private func downloadFFmpeg() async throws {
        // yt-dlp/FFmpeg-Builds releases a macOS static build; pick the right arch.
        #if arch(arm64)
        let assetSuffix = "macos-arm64-gpl.zip"
        #else
        let assetSuffix = "macos64-gpl.zip"
        #endif

        var req = URLRequest(url: URL(string: "https://api.github.com/repos/yt-dlp/FFmpeg-Builds/releases/latest")!)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        let ffRelease = try JSONDecoder().decode(GitHubRelease.self, from: data)

        guard let asset = ffRelease.assets.first(where: { $0.name.hasSuffix(assetSuffix) }) else {
            return  // no matching asset — not fatal, Homebrew fallback still works
        }

        installStatus = .downloading(progress: 0)

        let (asyncBytes, response) = try await URLSession.shared.bytes(from: asset.browser_download_url)
        let totalBytes = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Length").flatMap { Int($0) } ?? 0

        let zipURL = Self.supportDir.appendingPathComponent("ffmpeg.zip.download")
        FileManager.default.createFile(atPath: zipURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: zipURL)
        defer { try? handle.close() }

        var received = 0
        var buffer = Data(capacity: 256 * 1024)
        for try await byte in asyncBytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 256 * 1024 {
                handle.write(buffer)
                buffer.removeAll(keepingCapacity: true)
                if totalBytes > 0 {
                    installStatus = .downloading(progress: Double(received) / Double(totalBytes))
                }
            }
        }
        if !buffer.isEmpty { handle.write(buffer) }
        try? handle.close()

        let extractDir = Self.supportDir.appendingPathComponent("ffmpeg.unzip")
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", zipURL.path, "-d", extractDir.path]
        unzip.standardOutput = Pipe()
        unzip.standardError = Pipe()
        try unzip.run()
        unzip.waitUntilExit()
        try? FileManager.default.removeItem(at: zipURL)

        // The zip contains a top-level folder; search recursively for the ffmpeg binary.
        let executableNames: Set<String> = ["ffmpeg", "ffprobe"]
        if let enumerator = FileManager.default.enumerator(at: extractDir, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let itemURL as URL in enumerator {
                guard executableNames.contains(itemURL.lastPathComponent) else { continue }
                let dest = Self.supportDir.appendingPathComponent(itemURL.lastPathComponent)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                try? FileManager.default.copyItem(at: itemURL, to: dest)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
        }
        try? FileManager.default.removeItem(at: extractDir)
    }

}

// MARK: - Errors

enum YtDlpError: LocalizedError {
    case notInstalled
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "yt-dlp is not installed. Check Settings."
        case .processFailed(let msg): return msg.isEmpty ? "yt-dlp process failed." : msg
        }
    }
}

// MARK: - Private decodable models

private struct VideoEntryRaw: Decodable {
    let id: String
    let title: String
    let duration: Int?
    let upload_date: String?
    let thumbnail: String?
}

private struct GitHubRelease: Decodable {
    let tag_name: String
    let assets: [GitHubAsset]
}

private struct GitHubAsset: Decodable {
    let name: String
    let browser_download_url: URL
}
