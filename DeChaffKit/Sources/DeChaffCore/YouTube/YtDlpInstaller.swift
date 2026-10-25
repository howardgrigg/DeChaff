import Foundation

/// Installs and updates the yt-dlp bundle in DeChaff's Application Support folder.
/// Shared by the app (which shows download progress) and the MCP server, so YouTube
/// breakages can be fixed from either side.
public enum YtDlpInstaller {
    /// UserDefaults key (in the app's domain) holding the installed release tag.
    public static let versionKey = "dechaff.ytdlp.version"

    public struct Release: Sendable {
        public let tag: String
        public let bundleURL: URL
    }

    public enum UpdateResult: Sendable {
        case upToDate(version: String)
        case updated(from: String?, to: String)
    }

    /// The latest yt-dlp release and its macOS bundle (`yt-dlp_macos.zip`).
    public static func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = release.assets.first(where: { $0.name == "yt-dlp_macos.zip" }) else {
            throw YtDlpError.processFailed("Release \(release.tag_name) has no macOS bundle.")
        }
        return Release(tag: release.tag_name, bundleURL: asset.browser_download_url)
    }

    /// The installed yt-dlp's own version string, or nil if it's missing or won't run.
    public static func installedVersion() -> String? {
        guard let binary = YtDlpPaths.installedBinary else { return nil }
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--version"]
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Installs the latest release unless the working copy already matches it.
    public static func update(defaults: UserDefaults) async throws -> UpdateResult {
        let release = try await latestRelease()
        let installed = installedVersion()
        if installed == release.tag {
            defaults.set(release.tag, forKey: versionKey)
            return .upToDate(version: release.tag)
        }
        let (zip, _) = try await URLSession.shared.download(from: release.bundleURL)
        defer { try? FileManager.default.removeItem(at: zip) }
        try installBundle(zip: zip)
        defaults.set(release.tag, forKey: versionKey)
        return .updated(from: installed, to: release.tag)
    }

    /// Unpacks a downloaded `yt-dlp_macos.zip` into Application Support, replacing the
    /// previous copy. The whole bundle moves together: the binary must stay paired with
    /// the `_internal/` tree it was built with, or it fails to import at launch.
    public static func installBundle(zip: URL) throws {
        let fm = FileManager.default
        let support = YtDlpPaths.supportDirectory
        try fm.createDirectory(at: support, withIntermediateDirectories: true)

        let extractDir = support.appendingPathComponent("yt-dlp.unzip")
        try? fm.removeItem(at: extractDir)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extractDir) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", zip.path, "-d", extractDir.path]
        unzip.standardInput = FileHandle.nullDevice
        unzip.standardOutput = Pipe()
        unzip.standardError = Pipe()
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw YtDlpError.processFailed("Couldn't unzip the yt-dlp bundle.") }

        // Move all extracted contents into place, replacing anything already there —
        // this keeps _internal/ (required by PyInstaller onedir bundles) beside the binary.
        let executableNames: Set<String> = ["yt-dlp", "yt-dlp_macos", "ffmpeg", "ffprobe"]
        for item in (try? fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)) ?? [] {
            let dest = support.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try? fm.moveItem(at: item, to: dest)
            if executableNames.contains(item.lastPathComponent) {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
        }
        // The zip names the binary yt-dlp_macos; DeChaff runs it as yt-dlp. Always replace
        // it, since a stale copy would be paired with the _internal/ tree just installed.
        let alt = support.appendingPathComponent("yt-dlp_macos")
        if fm.fileExists(atPath: alt.path) {
            try? fm.removeItem(at: YtDlpPaths.binary)
            try fm.copyItem(at: alt, to: YtDlpPaths.binary)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: YtDlpPaths.binary.path)
        }
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
    }
}
