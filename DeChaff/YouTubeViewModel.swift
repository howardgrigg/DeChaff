import Foundation

@MainActor
class YouTubeViewModel: ObservableObject {
    @Published var videos: [VideoEntry] = []
    @Published var isFetchingList = false
    @Published var listError: String? = nil
    @Published var downloadingVideoID: String? = nil
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String? = nil

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

    func select(_ entry: VideoEntry, manager: YtDlpManager, onLoaded: @escaping (URL) -> Void) {
        guard downloadingVideoID == nil else { return }
        downloadingVideoID = entry.id
        downloadProgress = 0
        downloadError = nil
        Task {
            do {
                let url = try await manager.downloadAudio(videoID: entry.id) { [weak self] p in
                    self?.downloadProgress = p
                }
                downloadingVideoID = nil
                onLoaded(url)
            } catch {
                downloadingVideoID = nil
                downloadError = error.localizedDescription
            }
        }
    }
}

// MARK: - Date formatting helper

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
