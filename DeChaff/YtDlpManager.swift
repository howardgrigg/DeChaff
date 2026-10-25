import Foundation
import DeChaffCore

// MARK: - Data models

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
    @Published var downloadProgress: Double? = nil   // nil = not downloading; 0.0–1.0 = in progress
    /// Diagnostic only — deliberately not @Published: publishing per output line
    /// re-renders every observing view for each line yt-dlp prints.
    var downloadLog: [String] = []

    private var activeDownloadProcess: Process?

    func cancelDownload() {
        activeDownloadProcess?.terminate()
        activeDownloadProcess = nil
    }

    func cleanupTempFiles() {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let files = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
        // Keep the recording the shared episode plan points at — the MCP server may
        // still be working on it after the app quits.
        let planSource = EpisodePlanFile.load()?.sourcePath
        for file in files where file.lastPathComponent.hasPrefix("dechaff-yt-") && file.path != planSource {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Paths

    private static var supportDir: URL { YtDlpPaths.supportDirectory }
    private static var binaryPath: URL { YtDlpPaths.binary }
    private static var ffmpegPath: URL { YtDlpPaths.bundledFFmpeg }

    var binaryURL: URL? { YtDlpPaths.installedBinary }

    var ffmpegURL: URL? { YtDlpPaths.installedFFmpeg }

    enum FFmpegSource { case bundled, system(path: String) }

    /// Where ffmpeg was found, or nil if not yet available.
    var ffmpegSource: FFmpegSource? {
        if FileManager.default.fileExists(atPath: Self.ffmpegPath.path) { return .bundled }
        for path in YtDlpPaths.systemFFmpegPaths where FileManager.default.fileExists(atPath: path) {
            return .system(path: path)
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
            if release.tag_name == storedVersion, let bin = binaryURL, await isBinaryWorking(bin) {
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
        return try await YtDlpClient(binary: bin, ffmpeg: ffmpegURL)
            .fetchVideoList(channelURL: channelURL, limit: limit)
    }

    // MARK: - Download audio

    func downloadAudio(videoID: String) async throws -> URL {
        try await downloadAudio(url: "https://youtu.be/\(videoID)")
    }

    func downloadAudio(url videoURL: String) async throws -> URL {
        guard let bin = binaryURL else { throw YtDlpError.notInstalled }
        let client = YtDlpClient(binary: bin, ffmpeg: ffmpegURL)

        downloadLog = []
        downloadProgress = 0
        defer {
            downloadProgress = nil
            activeDownloadProcess = nil
        }
        return try await client.downloadAudio(
            url: videoURL,
            onStart: { process in
                await MainActor.run { self.activeDownloadProcess = process }
            },
            onLine: { line in
                await MainActor.run {
                    self.downloadLog.append(line)
                    // Publish only meaningful progress changes — every assignment
                    // invalidates all views observing this object.
                    if let pct = YtDlpClient.parseProgress(line),
                       abs(pct - (self.downloadProgress ?? -1)) >= 0.001 {
                        self.downloadProgress = pct
                    }
                }
            }
        )
    }

    // MARK: - Private helpers

    /// Runs `yt-dlp --version` and returns true if it exits 0.
    private func isBinaryWorking(_ bin: URL) async -> Bool {
        let p = Process()
        p.executableURL = bin
        p.arguments = ["--version"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        guard (try? p.run()) != nil else { return false }
        await YtDlpClient.awaitTermination(of: p)
        return p.terminationStatus == 0
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

        let tempZip = try await downloadFile(from: url) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.installStatus = .downloading(progress: progress)
            }
        }
        defer { try? FileManager.default.removeItem(at: tempZip) }

        // Shared with the MCP server's update_yt_dlp tool.
        try YtDlpInstaller.installBundle(zip: tempZip)

        UserDefaults.standard.set(version, forKey: "dechaff.ytdlp.version")
        installStatus = .installed(version: version)
    }

    private func downloadBinary(from url: URL, version: String) async throws {
        try FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)

        let tempFile = try await downloadFile(from: url) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.installStatus = .downloading(progress: progress)
            }
        }

        let finalURL = Self.binaryPath
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempFile, to: finalURL)
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

        let tempZip = try await downloadFile(from: asset.browser_download_url) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.installStatus = .downloading(progress: progress)
            }
        }
        defer { try? FileManager.default.removeItem(at: tempZip) }

        let extractDir = Self.supportDir.appendingPathComponent("ffmpeg.unzip")
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", tempZip.path, "-d", extractDir.path]
        unzip.standardOutput = Pipe()
        unzip.standardError = Pipe()
        try unzip.run()
        unzip.waitUntilExit()

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

    /// Downloads a file at full speed using URLSessionDownloadTask, reporting fractional progress.
    /// Returns the URL of a temporary file that the caller is responsible for deleting.
    private nonisolated func downloadFile(
        from url: URL,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = FileDownloadDelegate(progressHandler: progressHandler) { result in
                continuation.resume(with: result)
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: url).resume()
            delegate.session = session   // retain session until download completes
        }
    }

}

// MARK: - FileDownloadDelegate

private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: (Double) -> Void
    private let completion: (Result<URL, Error>) -> Void
    private var finished = false
    private var lastReportedFraction: Double = -1
    var session: URLSession?

    init(progressHandler: @escaping (Double) -> Void,
         completion: @escaping (Result<URL, Error>) -> Void) {
        self.progressHandler = progressHandler
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard !finished else { return }
        finished = true
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dechaff-dl-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            completion(.success(dest))
        } catch {
            completion(.failure(error))
        }
        self.session?.finishTasksAndInvalidate()
        self.session = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        // This fires per received chunk (hundreds/sec on fast connections) and each
        // report spawns a main-actor task + published update — cap it at 0.5% steps.
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        guard fraction - lastReportedFraction >= 0.005 || fraction >= 1.0 else { return }
        lastReportedFraction = fraction
        progressHandler(fraction)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, !finished else { return }
        finished = true
        completion(.failure(error))
        self.session?.invalidateAndCancel()
        self.session = nil
    }
}

// MARK: - Private decodable models

private struct GitHubRelease: Decodable {
    let tag_name: String
    let assets: [GitHubAsset]
}

private struct GitHubAsset: Decodable {
    let name: String
    let browser_download_url: URL
}
