import SwiftUI
import FoundationModels

struct SettingsView: View {
    @EnvironmentObject var manager: YtDlpManager
    @AppStorage("dechaff.youtube.channelURL") private var channelURL = "https://www.youtube.com/@cityonahillnz"
    @AppStorage("dechaff.youtube.videoLimit") private var videoLimit = 10

    @State private var aiAvailability: SystemLanguageModel.Availability?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Apple Intelligence section
                settingsGroup("Apple Intelligence") {
                    HStack(spacing: 12) {
                        aiStatusIcon
                        VStack(alignment: .leading, spacing: 2) {
                            Text(aiStatusTitle).font(.subheadline)
                            Text(aiStatusSubtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if case .unavailable(let reason) = aiAvailability,
                           reason != .deviceNotEligible {
                            Button("Set Up…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.AppleIntelligence")!)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

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
        .onAppear { aiAvailability = SystemLanguageModel.default.availability }
    }

    // MARK: - Apple Intelligence status helpers

    @ViewBuilder
    private var aiStatusIcon: some View {
        switch aiAvailability {
        case .available:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .unavailable(.deviceNotEligible):
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        case .unavailable(.appleIntelligenceNotEnabled):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .unavailable(.modelNotReady):
            Image(systemName: "arrow.down.circle").foregroundStyle(.orange)
        default:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    private var aiStatusTitle: String {
        switch aiAvailability {
        case .available:                              return "Available"
        case .unavailable(.deviceNotEligible):        return "Not supported"
        case .unavailable(.appleIntelligenceNotEnabled): return "Not enabled"
        case .unavailable(.modelNotReady):            return "Model downloading"
        default:                                      return "Unknown"
        }
    }

    private var aiStatusSubtitle: String {
        switch aiAvailability {
        case .available:
            return "Sermon metadata will be extracted automatically from YouTube titles"
        case .unavailable(.deviceNotEligible):
            return "This Mac does not support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Enable Apple Intelligence in System Settings to auto-fill sermon metadata"
        case .unavailable(.modelNotReady):
            return "The language model is still downloading — it will be ready soon"
        default:
            return "Unable to determine Apple Intelligence status"
        }
    }

    // MARK: - yt-dlp status helpers

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
