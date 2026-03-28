import Foundation

@MainActor
class YouTubeViewModel: ObservableObject {
    @Published var videos: [VideoEntry] = []
    @Published var isFetchingList = false
    @Published var listError: String? = nil
    @Published var downloadingVideoID: String? = nil
    @Published var downloadError: String? = nil
    private var downloadCancelled = false

    func refresh(manager: YtDlpManager, channelURL: String, limit: Int) {
        guard !channelURL.isEmpty else {
            listError = "No channel configured — add one in Settings."
            return
        }
        guard manager.binaryURL != nil else {
            listError = "yt-dlp not installed — tap the gear icon and check for updates."
            return
        }
        isFetchingList = true
        listError = nil
        Task {
            do {
                let result = try await manager.fetchVideoList(channelURL: channelURL, limit: limit)
                videos = result
            } catch {
                listError = error.localizedDescription
            }
            isFetchingList = false
        }
    }

    func select(_ entry: VideoEntry, manager: YtDlpManager,
                onLoaded: @escaping (URL, SermonMetadata?, Date?) -> Void) {
        guard downloadingVideoID == nil else { return }
        downloadingVideoID = entry.id
        downloadError = nil
        downloadCancelled = false
        Task {
            do {
                // Run AI metadata extraction concurrently with the audio download.
                // Inference on a short title finishes long before the download completes.
                async let audioURL = manager.downloadAudio(videoID: entry.id)
                async let metadata = extractSermonMetadata(from: entry.title)

                let url     = try await audioURL
                let details = await metadata
                let date    = parseYouTubeUploadDate(entry.uploadDate)

                downloadingVideoID = nil
                downloadCancelled = false
                onLoaded(url, details, date)
            } catch {
                downloadingVideoID = nil
                if !downloadCancelled {
                    downloadError = error.localizedDescription
                }
                downloadCancelled = false
            }
        }
    }

    /// Downloads audio from an arbitrary YouTube URL (not from the channel list).
    func selectURL(_ rawURL: String, manager: YtDlpManager,
                   onLoaded: @escaping (URL) -> Void) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, downloadingVideoID == nil else { return }
        downloadingVideoID = "direct-url"
        downloadError = nil
        downloadCancelled = false
        Task {
            do {
                let url = try await manager.downloadAudio(url: trimmed)
                downloadingVideoID = nil
                downloadCancelled = false
                onLoaded(url)
            } catch {
                downloadingVideoID = nil
                if !downloadCancelled {
                    downloadError = error.localizedDescription
                }
                downloadCancelled = false
            }
        }
    }

    func cancel(manager: YtDlpManager) {
        downloadCancelled = true
        manager.cancelDownload()
        downloadingVideoID = nil
        manager.downloadProgress = nil
    }
}

// MARK: - Date helpers

/// Parses a yt-dlp upload date string like "20240317" into a Date, or nil if unparseable.
func parseYouTubeUploadDate(_ raw: String) -> Date? {
    guard raw.count == 8 else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: raw)
}

func formatYouTubeDate(_ raw: String) -> String {
    // raw is "20240317"
    guard raw.count == 8,
          let year  = Int(raw.prefix(4)),
          let month = Int(raw.dropFirst(4).prefix(2)),
          let day   = Int(raw.suffix(2)) else { return raw }
    let months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
    guard month >= 1 && month <= 12 else { return raw }
    return "\(day) \(months[month - 1]) \(year)"
}
