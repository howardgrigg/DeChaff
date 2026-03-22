import SwiftUI

extension ContentView {

    // MARK: - YouTube section (shown in Step 1 below the drop zone)

    // Appends /videos or /streams to the channel URL based on the selected tab
    private var tabbedChannelURL: String {
        let base = ytChannelURL
            .trimmingCharacters(in: .init(charactersIn: "/"))
            .replacingOccurrences(of: "/videos", with: "")
            .replacingOccurrences(of: "/streams", with: "")
        let suffix = ytTab == 1 ? "/streams" : "/videos"
        return base + suffix
    }

    var youtubeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack {
                Label("From YouTube", systemImage: "play.rectangle")
                    .font(.headline)
                Spacer()
                Picker("", selection: $ytTab) {
                    Text("Videos").tag(0)
                    Text("Live Streams").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .controlSize(.small)
                .opacity(0.7)
                .onChange(of: ytTab) { _ in
                    youtube.videos = []
                    youtube.listError = nil
                    if !ytChannelURL.isEmpty && ytManager.binaryURL != nil {
                        youtube.refresh(manager: ytManager, channelURL: tabbedChannelURL, limit: ytVideoLimit)
                    }
                }
                // Fixed-size container so the spinner and button don't shift the layout
                ZStack {
                    ProgressView()
                        .scaleEffect(0.75)
                        .opacity(youtube.isFetchingList ? 1 : 0)
                    Button {
                        youtube.refresh(manager: ytManager, channelURL: tabbedChannelURL, limit: ytVideoLimit)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(ytChannelURL.isEmpty || ytManager.binaryURL == nil || youtube.isFetchingList)
                    .help("Refresh video list")
                    .opacity(youtube.isFetchingList ? 0 : 1)
                }
                .frame(width: 20, height: 20)
            }

            // Body
            VStack(spacing: 0) {
                if ytManager.binaryURL == nil {
                    emptyState(
                        icon: "arrow.down.circle",
                        text: "yt-dlp not installed",
                        detail: "Open Settings and tap \"Check for Updates\" to install."
                    )
                } else if ytChannelURL.isEmpty {
                    emptyState(
                        icon: "gear",
                        text: "No channel configured",
                        detail: "Open Settings and enter a YouTube channel URL or handle."
                    )
                } else if let err = youtube.listError {
                    errorBanner(err) { youtube.listError = nil }
                } else if youtube.isFetchingList && youtube.videos.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Loading videos…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 24)
                        Spacer()
                    }
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                } else if youtube.videos.isEmpty {
                    emptyState(
                        icon: "list.bullet",
                        text: "No videos loaded",
                        detail: "Tap the refresh button to fetch recent videos."
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(youtube.videos) { entry in
                            videoRow(entry)
                            if entry.id != youtube.videos.last?.id {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }

            // Download error banner
            if let dlErr = youtube.downloadError {
                errorBanner(dlErr) { youtube.downloadError = nil }
            }
        }
        .onAppear {
            if youtube.videos.isEmpty && !ytChannelURL.isEmpty && ytManager.binaryURL != nil {
                youtube.refresh(manager: ytManager, channelURL: tabbedChannelURL, limit: ytVideoLimit)
            }
        }
    }

    // MARK: - Video row

    private func videoRow(_ entry: VideoEntry) -> some View {
        let isDownloading = youtube.downloadingVideoID == entry.id
        let anyDownloading = youtube.downloadingVideoID != nil

        return HStack(spacing: 10) {
            // Thumbnail
            AsyncImage(url: entry.thumbnailURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color.secondary.opacity(0.15)
                        .overlay(Image(systemName: "play.rectangle").foregroundStyle(.quaternary))
                }
            }
            .frame(width: 72, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            // Text info
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let dur = entry.durationSeconds {
                        Text(formatPlaybackTime(Double(dur)))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if !entry.uploadDate.isEmpty {
                        Text(formatYouTubeDate(entry.uploadDate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // State indicator
            if isDownloading {
                VStack(spacing: 4) {
                    if let pct = ytManager.downloadProgress {
                        ProgressView(value: pct)
                            .progressViewStyle(.linear)
                            .frame(width: 72)
                        Text(String(format: "%.0f%%", pct * 100))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .scaleEffect(0.75)
                        Text("Finishing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel") {
                        youtube.cancel(manager: ytManager)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                .frame(width: 80)
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(anyDownloading ? .quaternary : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !anyDownloading else { return }
            youtube.select(entry, manager: ytManager) { url in
                model.loadFile(url: url)
                withAnimation(.easeInOut(duration: 0.2)) { currentStep = 1 }
            }
        }
        .opacity(anyDownloading && !isDownloading ? 0.5 : 1)
    }

    // MARK: - Helpers

    private func emptyState(icon: String, text: String, detail: String) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.quaternary)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
                Text(detail).font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 20)
            Spacer()
        }
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func errorBanner(_ message: String, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.primary).lineLimit(3)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}
