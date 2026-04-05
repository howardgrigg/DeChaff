import SwiftUI
import FoundationModels

struct SettingsView: View {
    @EnvironmentObject var manager: YtDlpManager

    var body: some View {
        TabView {
            GeneralSettingsView()
                .environmentObject(manager)
                .tabItem { Label("General", systemImage: "gear") }
            AIAssistantSettingsView()
                .tabItem { Label("AI Assistant", systemImage: "sparkles") }
            TemplatesSettingsView()
                .tabItem { Label("Templates", systemImage: "doc.text") }
        }
        .frame(width: 480, height: 520)
    }
}

// MARK: - General tab

struct GeneralSettingsView: View {
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
}

// MARK: - AI Assistant tab

struct AIAssistantSettingsView: View {
    @AppStorage("dechaff.ai.enabled") private var aiEnabled = false
    @AppStorage("dechaff.ai.prompt") private var promptTemplate = Self.defaultPrompt
    @AppStorage("dechaff.ai.model") private var storedModel = ClaudeModel.defaultID

    @State private var apiKeyInput = ""
    @State private var hasStoredKey = false
    @State private var pickerValue = ""       // tracks picker selection; "custom" or a known model ID
    @State private var customModelInput = ""  // text field content when custom is selected

    static let defaultPrompt = """
        You are a helpful church media assistant. Given the following sermon transcript, please suggest:
        1. A short podcast episode title (not the same as the sermon title)
        2. A 2-3 sentence podcast episode description
        3. 3-5 key themes or takeaways

        Sermon: "{title}" by {preacher}
        Series: {series}
        Bible Reading: {reading}
        """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsGroup("AI Assistant") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable AI Assistant").font(.subheadline)
                            Text("Send transcript to Claude API after processing")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $aiEnabled).labelsHidden()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                if aiEnabled {
                    settingsGroup("Claude API Key") {
                        VStack(alignment: .leading, spacing: 8) {
                            if hasStoredKey {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    Text("API key saved").font(.subheadline)
                                    Spacer()
                                    Button("Remove") {
                                        KeychainHelper.delete(account: "claude-api-key")
                                        hasStoredKey = false
                                        apiKeyInput = ""
                                    }
                                    .buttonStyle(.bordered).controlSize(.small)
                                }
                            } else {
                                SecureField("sk-ant-…", text: $apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                HStack {
                                    Text("Get a key at [console.anthropic.com](https://console.anthropic.com/settings/keys)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Save") {
                                        guard !apiKeyInput.isEmpty else { return }
                                        KeychainHelper.save(account: "claude-api-key", data: Data(apiKeyInput.utf8))
                                        hasStoredKey = true
                                        apiKeyInput = ""
                                    }
                                    .buttonStyle(.borderedProminent).controlSize(.small)
                                    .disabled(apiKeyInput.isEmpty)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }

                    settingsGroup("Claude Model") {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text("Model").font(.subheadline)
                                Spacer()
                                Picker("", selection: $pickerValue) {
                                    ForEach(ClaudeModel.knownModels, id: \.id) { m in
                                        Text(m.name).tag(m.id)
                                    }
                                    Divider()
                                    Text("Custom…").tag("custom")
                                }
                                .labelsHidden()
                                .frame(width: 240)
                                .onChange(of: pickerValue) { newValue in
                                    if newValue != "custom" {
                                        storedModel = newValue
                                    }
                                    // When switching to custom, pre-fill with current storedModel
                                    // if it's already a custom value
                                    if newValue == "custom" && !ClaudeModel.knownModels.contains(where: { $0.id == storedModel }) {
                                        customModelInput = storedModel
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)

                            if pickerValue == "custom" {
                                Divider().padding(.leading, 16)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Model ID").font(.subheadline)
                                    HStack {
                                        TextField("e.g. claude-sonnet-4-6", text: $customModelInput)
                                            .textFieldStyle(.roundedBorder)
                                        Button("Save") {
                                            let trimmed = customModelInput.trimmingCharacters(in: .whitespaces)
                                            if !trimmed.isEmpty { storedModel = trimmed }
                                        }
                                        .buttonStyle(.borderedProminent).controlSize(.small)
                                        .disabled(customModelInput.trimmingCharacters(in: .whitespaces).isEmpty)
                                    }
                                    Text("Find model IDs at [docs.anthropic.com/en/docs/about-claude/models](https://docs.anthropic.com/en/docs/about-claude/models)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }
                        }
                    }

                    settingsGroup("Prompt Template") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("The transcript is sent as the user message. This template becomes the system prompt.")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $promptTemplate)
                                .font(.system(.subheadline, design: .monospaced))
                                .frame(minHeight: 120, maxHeight: 200)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1))
                            HStack {
                                Text("Placeholders: {title} {preacher} {series} {reading}")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Reset to Default") { promptTemplate = Self.defaultPrompt }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .disabled(promptTemplate == Self.defaultPrompt)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            hasStoredKey = KeychainHelper.load(account: "claude-api-key") != nil
            let isKnown = ClaudeModel.knownModels.contains(where: { $0.id == storedModel })
            pickerValue = isKnown ? storedModel : "custom"
            if !isKnown { customModelInput = storedModel }
        }
    }
}

// MARK: - Templates tab

struct TemplatesSettingsView: View {
    @AppStorage("dechaff.titleFormat")      private var titleFormat      = defaultTitleFormat
    @AppStorage("dechaff.filenameTemplate") private var filenameTemplate = defaultFilenameTemplate

    // Example values used for the filename live preview
    private let exampleValues: [String: String] = [
        "date":     "2026-04-06",
        "title":    "The Good Shepherd",
        "reading":  "John 10:1–18",
        "preacher": "Rev. James Hart",
        "series":   "Foundations",
    ]

    private func previewFilename(template: String) -> String {
        let segments = template.components(separatedBy: "|")
        let resolved = segments.compactMap { segment -> String? in
            var s = segment
            for (key, value) in exampleValues { s = s.replacingOccurrences(of: "{\(key)}", with: value) }
            let stripped = s.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",-–"))
                .trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty ? nil : s.trimmingCharacters(in: .whitespaces)
        }
        var result = resolved.joined(separator: " | ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return (result.isEmpty ? "sermon_dechaff" : result) + ".mp3"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                settingsGroup("YouTube Title Format") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tell DeChaff the format your church uses for YouTube titles. The AI will use this to extract sermon metadata.")
                            .font(.caption).foregroundStyle(.secondary)

                        TextField("Format template", text: $titleFormat)
                            .textFieldStyle(.roundedBorder)

                        PlaceholderChipsView(text: $titleFormat,
                                            placeholders: ["{title}", "{reading}", "{preacher}", "{series}", "{date}"])

                        HStack {
                            Spacer()
                            Button("Reset to Default") { titleFormat = defaultTitleFormat }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(titleFormat == defaultTitleFormat)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                settingsGroup("Output Filename") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Template for the exported file name. The file extension is added automatically.")
                            .font(.caption).foregroundStyle(.secondary)

                        TextField("Filename template", text: $filenameTemplate)
                            .textFieldStyle(.roundedBorder)

                        PlaceholderChipsView(text: $filenameTemplate,
                                            placeholders: ["{date}", "{title}", "{reading}", "{preacher}", "{series}"])

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Preview:").font(.caption).foregroundStyle(.secondary)
                                Text(previewFilename(template: filenameTemplate))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button("Reset to Default") { filenameTemplate = defaultFilenameTemplate }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(filenameTemplate == defaultFilenameTemplate)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Reusable placeholder chip strip

struct PlaceholderChipsView: View {
    @Binding var text: String
    let placeholders: [String]

    var body: some View {
        HStack(spacing: 6) {
            Text("Insert:").font(.caption).foregroundStyle(.secondary)
            ForEach(placeholders, id: \.self) { chip in
                Button(chip) { text += chip }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .font(.system(.caption, design: .monospaced))
            }
        }
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
