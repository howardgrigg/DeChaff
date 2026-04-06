import AppIntents
import AppKit

/// A Shortcuts action that downloads audio from a URL and opens it in DeChaff ready to trim.
struct DownloadSermonIntent: AppIntent {

    static let title: LocalizedStringResource = "Download & Open in DeChaff"
    static let description = IntentDescription(
        "Downloads audio from a YouTube URL (or any URL supported by yt-dlp) and opens it in DeChaff at the Trim step.",
        categoryName: "DeChaff"
    )
    static let openAppWhenRun = true

    @Parameter(title: "URL", description: "A YouTube video or playlist URL, or any URL supported by yt-dlp.")
    var url: URL

    func perform() async throws -> some IntentResult {
        guard var components = URLComponents(string: "dechaff://download") else {
            throw IntentError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let deChaffURL = components.url else {
            throw IntentError.invalidURL
        }
        NSWorkspace.shared.open(deChaffURL)
        return .result()
    }
}

struct DeChaffShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DownloadSermonIntent(),
            phrases: [
                "Download sermon in \(.applicationName)",
                "Open URL in \(.applicationName)",
            ],
            shortTitle: "Download Sermon",
            systemImageName: "arrow.down.circle"
        )
    }
}

private enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case invalidURL

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalidURL: return "Could not build the DeChaff URL. Make sure the input is a valid URL."
        }
    }
}
