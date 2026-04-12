import SwiftUI
import FoundationModels

struct SettingsView: View {
    @EnvironmentObject var manager: YtDlpManager
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            YouTubeSettingsView()
                .environmentObject(manager)
                .tabItem { Label("YouTube", systemImage: "play.rectangle") }
                .tag(0)
            AudioSettingsView()
                .tabItem { Label("Audio", systemImage: "waveform") }
                .tag(1)
            AIAssistantSettingsView()
                .tabItem { Label("AI Assistant", systemImage: "sparkles") }
                .tag(2)
            TemplatesSettingsView()
                .tabItem { Label("Templates", systemImage: "doc.text") }
                .tag(3)
        }
        .frame(width: 480, height: 560)
    }
}

// MARK: - YouTube tab

struct YouTubeSettingsView: View {
    @EnvironmentObject var manager: YtDlpManager
    @AppStorage("dechaff.youtube.channelURL") private var channelURL = "https://www.youtube.com/@cityonahillnz"
    @AppStorage("dechaff.youtube.videoLimit") private var videoLimit = 10
    @AppStorage("dechaff.titleFormat")        private var titleFormat = defaultTitleFormat

    @State private var aiAvailability: SystemLanguageModel.Availability?
    @State private var hasClaudeKey = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Channel section
                settingsGroup("Channel") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Channel URL or Handle").font(.subheadline)
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

                // Metadata extraction section
                settingsGroup("Metadata Extraction") {
                    VStack(spacing: 0) {
                        Text("DeChaff reads the YouTube title and fills in the sermon metadata automatically. It tries each method in order, using the first that works.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 6)

                        Divider().padding(.leading, 16)
                        metadataTierRow(
                            number: "1",
                            name: "Apple Intelligence",
                            isActive: aiAvailabilityIsActive,
                            statusIcon: AnyView(appleIntelligenceIcon),
                            statusText: appleIntelligenceStatus,
                            actionButton: appleIntelligenceButton
                        )

                        Divider().padding(.leading, 16)
                        metadataTierRow(
                            number: "2",
                            name: "Claude API",
                            isActive: !aiAvailabilityIsActive && hasClaudeKey,
                            statusIcon: hasClaudeKey
                                ? AnyView(Image(systemName: "checkmark.circle.fill").foregroundStyle(.green))
                                : AnyView(Image(systemName: "minus.circle").foregroundStyle(.secondary)),
                            statusText: hasClaudeKey ? "API key saved" : "No API key — configure in AI Assistant tab",
                            actionButton: nil
                        )

                        Divider().padding(.leading, 16)
                        metadataTierRow(
                            number: "3",
                            name: "Regex",
                            isActive: !aiAvailabilityIsActive && !hasClaudeKey,
                            statusIcon: AnyView(Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)),
                            statusText: "Always available — uses the title format below",
                            actionButton: nil
                        )
                    }
                }

                // YouTube Title Format section
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

                // yt-dlp section
                settingsGroup("yt-dlp & ffmpeg") {
                    Text("DeChaff uses yt-dlp, a free open-source tool, to download audio from your YouTube channel. ffmpeg is also required for some video formats. Both are checked for updates automatically each time the app opens and kept in DeChaff's private storage — nothing is installed system-wide.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    Divider().padding(.leading, 16)

                    HStack(spacing: 12) {
                        ytdlpStatusIcon
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ytdlpStatusTitle).font(.subheadline)
                            Text(ytdlpStatusSubtitle).font(.caption).foregroundStyle(.secondary)
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

                    HStack(spacing: 12) {
                        ffmpegStatusIcon
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ffmpeg").font(.subheadline)
                            Text(ffmpegStatusSubtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
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
        .onAppear {
            aiAvailability = SystemLanguageModel.default.availability
            hasClaudeKey = KeychainHelper.load(account: "claude-api-key") != nil
        }
    }

    // MARK: - Metadata tier row

    @ViewBuilder
    private func metadataTierRow(
        number: String,
        name: String,
        isActive: Bool,
        statusIcon: AnyView,
        statusText: String,
        actionButton: AnyView?
    ) -> some View {
        HStack(spacing: 12) {
            // Tier number badge
            Text(number)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isActive ? Color.white : Color.secondary)
                .frame(width: 20, height: 20)
                .background(isActive ? Color.accentColor : Color.secondary.opacity(0.2),
                            in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name).font(.subheadline)
                    if isActive {
                        Text("IN USE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                HStack(spacing: 4) {
                    statusIcon
                        .font(.system(size: 11))
                    Text(statusText)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            actionButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Apple Intelligence helpers

    private var aiAvailabilityIsActive: Bool {
        if case .available = aiAvailability { return true }
        return false
    }

    @ViewBuilder
    private var appleIntelligenceIcon: some View {
        switch aiAvailability {
        case .available:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .unavailable(.deviceNotEligible):
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case .unavailable(.appleIntelligenceNotEnabled):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .unavailable(.modelNotReady):
            Image(systemName: "arrow.down.circle").foregroundStyle(.orange)
        default:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    private var appleIntelligenceStatus: String {
        switch aiAvailability {
        case .available:                                 return "Available"
        case .unavailable(.deviceNotEligible):           return "Not supported on this Mac"
        case .unavailable(.appleIntelligenceNotEnabled): return "Not enabled — tap Set Up to enable"
        case .unavailable(.modelNotReady):               return "Model still downloading"
        default:                                         return "Unknown"
        }
    }

    private var appleIntelligenceButton: AnyView? {
        guard case .unavailable(let reason) = aiAvailability, reason != .deviceNotEligible else { return nil }
        return AnyView(
            Button("Set Up…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.AppleIntelligence")!)
            }
            .buttonStyle(.bordered).controlSize(.small)
        )
    }

    // MARK: - ffmpeg helpers

    @ViewBuilder
    private var ffmpegStatusIcon: some View {
        switch manager.ffmpegSource {
        case .bundled:        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .system:         Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case nil:
            if case .downloading = manager.installStatus {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    private var ffmpegStatusSubtitle: String {
        switch manager.ffmpegSource {
        case .bundled:            return "Bundled — downloaded with yt-dlp"
        case .system(let path):   return "System install found at \(path)"
        case nil:
            if case .downloading = manager.installStatus { return "Downloading…" }
            return "Not found — will be downloaded when you tap Check for Updates"
        }
    }

    // MARK: - yt-dlp helpers

    @ViewBuilder
    private var ytdlpStatusIcon: some View {
        switch manager.installStatus {
        case .notInstalled:  Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        case .checking:      ProgressView().scaleEffect(0.7)
        case .downloading:   Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        case .installed:     Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:         Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var ytdlpStatusTitle: String {
        switch manager.installStatus {
        case .notInstalled:      return "Not installed"
        case .checking:          return "Checking for updates…"
        case .downloading:       return "Downloading…"
        case .installed(let v):  return "Installed — \(v)"
        case .error:             return "Update failed"
        }
    }

    private var ytdlpStatusSubtitle: String {
        switch manager.installStatus {
        case .notInstalled:          return "Tap \"Check for Updates\" to install"
        case .checking:              return "Contacting GitHub…"
        case .downloading(let p):    return String(format: "%.0f%%", p * 100)
        case .installed:             return "Kept up to date automatically on launch"
        case .error(let msg):        return msg
        }
    }
}

// MARK: - Audio tab

struct AudioSettingsView: View {
    @AppStorage("dechaff.compressor.threshold")  private var threshold:  Double = -28.0
    @AppStorage("dechaff.compressor.headRoom")   private var headRoom:   Double =   6.0
    @AppStorage("dechaff.compressor.attack")     private var attack:     Double =   0.003
    @AppStorage("dechaff.compressor.release")    private var release:    Double =   0.150
    @AppStorage("dechaff.compressor.makeupGain") private var makeupGain: Double =   8.0

    private let defaults = (threshold: -28.0, headRoom: 6.0, attack: 0.003, release: 0.150, makeupGain: 8.0)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsGroup("Compressor") {
                    VStack(spacing: 0) {

                        paramRow(
                            label: "Threshold",
                            value: String(format: "%.0f dB", threshold),
                            caption: "Level where compression engages. Lower = more compression."
                        ) {
                            Slider(value: $threshold, in: -40 ... -10, step: 1)
                        }

                        Divider().padding(.leading, 16)

                        paramRow(
                            label: "Headroom",
                            value: String(format: "%.0f dB", headRoom),
                            caption: "Output ceiling above threshold before makeup gain."
                        ) {
                            Slider(value: $headRoom, in: 2 ... 12, step: 1)
                        }

                        Divider().padding(.leading, 16)

                        paramRow(
                            label: "Attack",
                            value: String(format: "%.0f ms", attack * 1000),
                            caption: "How quickly the compressor engages on rising peaks."
                        ) {
                            Slider(value: $attack, in: 0.001 ... 0.020, step: 0.001)
                        }

                        Divider().padding(.leading, 16)

                        paramRow(
                            label: "Release",
                            value: String(format: "%.0f ms", release * 1000),
                            caption: "How quickly the gain recovers after a peak."
                        ) {
                            Slider(value: $release, in: 0.050 ... 0.500, step: 0.010)
                        }

                        Divider().padding(.leading, 16)

                        paramRow(
                            label: "Makeup gain",
                            value: String(format: "%.0f dB", makeupGain),
                            caption: "Post-compression boost applied before loudness normalisation."
                        ) {
                            Slider(value: $makeupGain, in: 0 ... 20, step: 1)
                        }

                        Divider().padding(.leading, 16)

                        HStack {
                            Spacer()
                            Button("Reset to Defaults") {
                                threshold  = defaults.threshold
                                headRoom   = defaults.headRoom
                                attack     = defaults.attack
                                release    = defaults.release
                                makeupGain = defaults.makeupGain
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(threshold == defaults.threshold
                                   && headRoom  == defaults.headRoom
                                   && attack    == defaults.attack
                                   && release   == defaults.release
                                   && makeupGain == defaults.makeupGain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func paramRow(label: String, value: String, caption: String,
                          @ViewBuilder slider: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(value)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            slider()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
