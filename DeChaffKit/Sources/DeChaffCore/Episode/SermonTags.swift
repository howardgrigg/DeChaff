import Foundation

/// The episode details a user fills in on the Info step.
public struct SermonTags: Sendable {
    public var title: String
    public var reading: String
    public var preacher: String
    public var series: String
    public var date: Date
    public var artwork: Data?

    public init(title: String = "", reading: String = "", preacher: String = "",
                series: String = "", date: Date = Date(), artwork: Data? = nil) {
        self.title = title
        self.reading = reading
        self.preacher = preacher
        self.series = series
        self.date = date
        self.artwork = artwork
    }

    public var year: String { String(Calendar.current.component(.year, from: date)) }

    public var datePrefix: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }

    /// Placeholder values for filename templates.
    public var templateValues: [String: String] {
        ["date": datePrefix, "title": title, "reading": reading, "preacher": preacher, "series": series]
    }

    /// The ID3 tags written to the episode: "Title, Reading" / preacher / series / year.
    public var id3: ID3Metadata {
        ID3Metadata(
            title: [title, reading].filter { !$0.isEmpty }.joined(separator: ", "),
            artist: preacher, album: series, year: year, artwork: artwork
        )
    }
}

// MARK: - Output naming

public enum FilenameTemplate {
    /// Resolves a filename template into a sanitised file name (without extension), or nil
    /// when every placeholder is empty. Empty placeholder segments are collapsed so the
    /// result is clean.
    public static func resolve(_ template: String, values: [String: String]) -> String? {
        // Split template on | so we can drop empty pipe-segments entirely
        let segments = template.components(separatedBy: "|")
        let resolved = segments.compactMap { segment -> String? in
            var s = segment
            for (key, value) in values {
                s = s.replacingOccurrences(of: "{\(key)}", with: value)
            }
            // If this segment is now only whitespace and punctuation (no real content), drop it
            let stripped = s.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",-–"))
                .trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty ? nil : s.trimmingCharacters(in: .whitespaces)
        }

        let result = resolved.joined(separator: " | ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)

        return result.isEmpty ? nil : result
    }
}

/// Files downloaded by yt-dlp land in the temp directory with this prefix.
public let youTubeDownloadPrefix = "dechaff-yt-"

/// Where the processed episode for `input` is saved: next to the source file, or
/// ~/Downloads when the source is a temporary yt-dlp download.
public func defaultOutputDirectory(for input: URL) -> URL {
    if input.lastPathComponent.hasPrefix(youTubeDownloadPrefix),
       let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
        return downloads
    }
    return input.deletingLastPathComponent()
}

/// Appends " (2)", " (3)", … to the file name until it doesn't collide.
public func uniqueOutputPath(for path: String) -> String {
    let url  = URL(fileURLWithPath: path)
    let dir  = url.deletingLastPathComponent()
    let base = url.deletingPathExtension().lastPathComponent
    let ext  = url.pathExtension
    var n = 2
    var candidate = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
    while FileManager.default.fileExists(atPath: candidate.path) {
        n += 1
        candidate = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
    }
    return candidate.path
}
