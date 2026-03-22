import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var manager: YtDlpManager
    @AppStorage("dechaff.youtube.channelURL") private var channelURL = "https://www.youtube.com/@cityonahillnz"
    @AppStorage("dechaff.youtube.videoLimit") private var videoLimit = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // YouTube section
                settingsGroup("YouTube") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Channel URL or Handle")
                            .font(.subheadline)
                        TextField("@YourChurch or https://youtube.com/@…", text: $channelURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Divider().padding(.leading, 16)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Videos to show").font(.subheadline)
                            Text("Number of recent videos to display")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $videoLimit) {
                            Text("5").tag(5)
                            Text("10").tag(10)
                            Text("20").tag(20)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 130)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                // yt-dlp section
                settingsGroup("yt-dlp") {
                    HStack(spacing: 12) {
                        statusIcon
                        VStack(alignment: .leading, spacing: 2) {
                            Text(statusTitle).font(.subheadline)
                            Text(statusSubtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if case .downloading(let p) = manager.installStatus {
                            ProgressView(value: p)
                                .frame(width: 80)
                                .progressViewStyle(.linear)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Divider().padding(.leading, 16)

                    HStack {
                        Spacer()
                        Button("Check for Updates") {
                            Task { await manager.checkAndUpdate() }
                        }
                        .disabled({
                            if case .checking = manager.installStatus { return true }
                            if case .downloading = manager.installStatus { return true }
                            return false
                        }())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .padding(24)
        }
        .frame(width: 440)
    }

    // MARK: - Status display helpers

    @ViewBuilder
    private var statusIcon: some View {
        switch manager.installStatus {
        case .notInstalled:
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        case .checking:
            ProgressView().scaleEffect(0.7)
        case .downloading:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var statusTitle: String {
        switch manager.installStatus {
        case .notInstalled:       return "Not installed"
        case .checking:           return "Checking for updates…"
        case .downloading:        return "Downloading…"
        case .installed(let v):   return "Installed — \(v)"
        case .error:              return "Update failed"
        }
    }

    private var statusSubtitle: String {
        switch manager.installStatus {
        case .notInstalled:           return "Tap \"Check for Updates\" to install"
        case .checking:               return "Contacting GitHub…"
        case .downloading(let p):     return String(format: "%.0f%%", p * 100)
        case .installed:              return "Kept up to date automatically on launch"
        case .error(let msg):         return msg
        }
    }

    // MARK: - Settings card helper

    func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(spacing: 0) { content() }
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
