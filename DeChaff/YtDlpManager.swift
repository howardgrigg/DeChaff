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

    // MARK: Paths

    private static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("DeChaff")
    }

    private static var binaryPath: URL {
        supportDir.appendingPathComponent("yt-dlp")
    }

    var binaryURL: URL? {
        let url = Self.binaryPath
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Version check & auto-update

    func checkAndUpdate() async {
        installStatus = .checking
        do {
            let release = try await fetchLatestRelease()
            let storedVersion = UserDefaults.standard.string(forKey: "dechaff.ytdlp.version") ?? ""
            if release.tag_name == storedVersion, let _ = binaryURL {
                installStatus = .installed(version: release.tag_name)
                return
            }
            guard let asset = release.assets.first(where: { $0.name == "yt-dlp_macos" })
                           ?? release.assets.first(where: { $0.name == "yt-dlp" }) else {
                installStatus = .error("No compatible binary found in release \(release.tag_name)")
                return
            }
            try await downloadBinary(from: asset.browser_download_url, version: release.tag_name)
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
                entries.append(VideoEntry(
                    id: raw.id,
                    title: raw.title,
                    durationSeconds: raw.duration,
                    uploadDate: raw.upload_date ?? "",
                    thumbnailURL: raw.thumbnail.flatMap { URL(string: $0) }
                ))
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

    func downloadAudio(videoID: String, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let bin = binaryURL else { throw YtDlpError.notInstalled }
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dechaff-yt-\(UUID().uuidString).wav")
        let process = Process()
        process.executableURL = bin
        process.arguments = [
            "-x",
            "--audio-format", "wav",
            "--audio-quality", "0",
            "--no-playlist",
            "--no-warnings",
            "-o", tempURL.path,
            "https://youtu.be/\(videoID)"
        ]
        let errPipe = Pipe()
        process.standardOutput = Pipe()   // discard stdout
        process.standardError = errPipe
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        try process.run()

        for try await line in errPipe.fileHandleForReading.bytes.lines {
            if let pct = parseDownloadPercent(line) {
                let p = pct
                await MainActor.run { progress(p) }
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tempURL.path) else {
            throw YtDlpError.processFailed("yt-dlp exited with status \(process.terminationStatus)")
        }
        return tempURL
    }

    // MARK: - Private helpers

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
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

    private func parseDownloadPercent(_ line: String) -> Double? {
        // Matches "[download]  47.3% of ..."
        guard line.contains("[download]"), line.contains("%") else { return nil }
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        for part in parts {
            if part.hasSuffix("%"), let val = Double(part.dropLast()) {
                return val / 100.0
            }
        }
        return nil
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
