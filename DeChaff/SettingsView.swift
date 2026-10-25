import SwiftUI
import FoundationModels
import DeChaffCore

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
            MCPSettingsView()
                .tabItem { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(4)
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
                            .accessibilityLabel("Channel URL or handle")
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
                        Picker("Videos to show", selection: $videoLimit) {
                            Text("5").tag(5)
                            Text("10").tag(10)
                            Text("20").tag(20)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
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
                            .accessibilityLabel("YouTube title format")

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
                            .font(.caption2.weight(.bold))
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
                .accessibilityLabel(label)
                .accessibilityValue(value)
                .accessibilityHint(caption)
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
                        Toggle("Enable AI Assistant", isOn: $aiEnabled).labelsHidden()
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
                                    .accessibilityLabel("Claude API key")
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
                                Picker("Model", selection: $pickerValue) {
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
                                        TextField("e.g. claude-sonnet-5-5", text: $customModelInput)
                                            .textFieldStyle(.roundedBorder)
                                            .accessibilityLabel("Model ID")
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
                                Text("Placeholders: {title} {preacher} {series} {reading} {date} {year} {duration}")
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
        (FilenameTemplate.resolve(template, values: exampleValues) ?? "sermon_dechaff") + ".mp3"
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

// MARK: - MCP tab

/// Explains and automates connecting the dechaff-mcp server to Claude Desktop / Claude Code.
struct MCPSettingsView: View {
    @AppStorage("dechaff.mcp.serverPath") private var serverPath = ""
    @AppStorage("dechaff.mcp.instructions") private var assistantInstructions = ""
    @State private var serverVersion: String? = nil
    @State private var serverError: String? = nil
    @State private var desktopMessage: String? = nil
    @State private var copiedID: String? = nil
    @State private var showAdvanced = false

    private let buildCommand = "cd DeChaff/DeChaffKit\nswift build -c release"

    private static let claudeDesktopConfig = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Claude/claude_desktop_config.json")

    /// The server embedded in DeChaff.app/Contents/MacOS by the dechaff-mcp target.
    private var bundledServerPath: String? {
        Bundle.main.url(forAuxiliaryExecutable: "dechaff-mcp")?.path
    }

    /// A server built from source if one was chosen, otherwise the built-in one.
    private var resolvedServerPath: String? {
        if !serverPath.isEmpty {
            return FileManager.default.isExecutableFile(atPath: serverPath) ? serverPath : nil
        }
        return bundledServerPath
    }

    /// Pointing the server at this app's bundled LAME means it can encode MP3s
    /// wherever DeChaff is installed.
    private var lamePath: String? { Bundle.main.path(forResource: "lame", ofType: nil) }

    private var displayedServerPath: String { resolvedServerPath ?? "/path/to/dechaff-mcp" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsGroup("Use DeChaff from an AI assistant") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("DeChaff includes an MCP server that lets Claude Desktop, Claude Code and other MCP apps run DeChaff for you. It can find this week's video, transcribe it, work out where the sermon starts and ends and where chapters go, then produce the tagged MP3 once you confirm.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("It uses the YouTube, Audio and Templates settings from this window. Once connected, try asking: “Prepare this week's sermon.”")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        serverStatus
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }

                settingsGroup("Your church's instructions") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How your church likes its episodes, in plain English. The assistant follows these over its usual approach. They take effect next time it connects — restart Claude after changing them.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextEditor(text: $assistantInstructions)
                            .font(.subheadline)
                            .frame(minHeight: 90, maxHeight: 160)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .topLeading) {
                                if assistantInstructions.isEmpty {
                                    Text("e.g. Start the episode at the Bible reader's greeting, including the reading, with a first chapter called “Reading: <passage>”.")
                                        .font(.subheadline).foregroundStyle(.tertiary)
                                        .padding(.horizontal, 13).padding(.vertical, 8)
                                        .allowsHitTesting(false)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }

                settingsGroup("Connect Claude Desktop") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Adds DeChaff to Claude Desktop's configuration file (your other servers are kept, and a .bak copy is saved). Quit and reopen Claude Desktop afterwards. If you move DeChaff to another folder, click Add again.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Add to Claude Desktop") { addToClaudeDesktop() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .disabled(resolvedServerPath == nil)
                            Button("Show Config File") { showClaudeDesktopConfig() }
                                .buttonStyle(.bordered).controlSize(.small)
                            Spacer()
                        }
                        if let desktopMessage {
                            Text(desktopMessage).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Or add it by hand:").font(.caption).foregroundStyle(.secondary)
                        codeBlock(claudeDesktopSnippet, id: "desktop")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }

                settingsGroup("Or connect Claude Code") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Run this in Terminal to make DeChaff available in every Claude Code session:")
                            .font(.caption).foregroundStyle(.secondary)
                        codeBlock(claudeCodeCommand, id: "code")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }

                settingsGroup("Requirements") {
                    VStack(alignment: .leading, spacing: 6) {
                        requirementRow(YtDlpPaths.installedBinary != nil,
                                       "yt-dlp installed",
                                       "Check for updates on the YouTube tab to install it.")
                        requirementRow(isAppleSilicon,
                                       "Apple Silicon Mac",
                                       "Needed for on-device transcription.")
                        requirementRow(lamePath != nil,
                                       "MP3 encoder (bundled with DeChaff)",
                                       "Reinstall DeChaff — its bundled LAME encoder is missing.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }

                settingsGroup("Advanced") {
                    DisclosureGroup("Use a server built from source", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("For development: build the server from the DeChaff repository in Terminal, then choose DeChaffKit/.build/release/dechaff-mcp. Click Add to Claude Desktop again afterwards.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            codeBlock(buildCommand, id: "build")
                            HStack(spacing: 8) {
                                Text(serverPath.isEmpty ? "Using the server built into DeChaff" : serverPath)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if !serverPath.isEmpty {
                                    Button("Use Built-in") { serverPath = "" }
                                        .buttonStyle(.bordered).controlSize(.small)
                                        .disabled(bundledServerPath == nil)
                                }
                                Button("Choose…") { chooseServer() }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.caption)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
            .padding(24)
        }
        .onAppear {
            // Show the advanced section when it's in use or the app has no built-in server.
            showAdvanced = !serverPath.isEmpty || bundledServerPath == nil
            testServer()
        }
        .onChange(of: serverPath) { _, _ in testServer() }
    }

    // MARK: Pieces

    @ViewBuilder
    private var serverStatus: some View {
        if let serverVersion {
            Label(serverPath.isEmpty ? "Server ready (\(serverVersion))" : "Using your build (\(serverVersion))",
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        } else if let serverError {
            Label(serverError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codeBlock(_ text: String, id: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copiedID == id ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copiedID = id
            }
            .buttonStyle(.bordered).controlSize(.mini)
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func requirementRow(_ ok: Bool, _ title: String, _ fix: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption)
                if !ok { Text(fix).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        // Met or missing is otherwise shown only by the icon.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(ok ? "OK" : "Missing. \(fix)")
    }

    private var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    // MARK: Configuration text

    /// The server entry for an MCP client's mcpServers map. The built-in server finds
    /// the app's LAME itself; a server built elsewhere is pointed at it.
    private func serverEntry(_ server: String) -> [String: Any] {
        var entry: [String: Any] = ["command": server]
        if server != bundledServerPath, let lamePath { entry["env"] = ["DECHAFF_LAME": lamePath] }
        return entry
    }

    private var claudeDesktopSnippet: String {
        let root: [String: Any] = ["mcpServers": ["dechaff": serverEntry(displayedServerPath)]]
        guard let data = try? JSONSerialization.data(withJSONObject: root,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private var claudeCodeCommand: String {
        // The server name goes before -e: -e takes several values and would swallow it.
        var command = "claude mcp add dechaff --scope user"
        if resolvedServerPath != bundledServerPath, let lamePath {
            command += " -e DECHAFF_LAME=\(shellQuoted(lamePath))"
        }
        return command + " -- \(shellQuoted(displayedServerPath))"
    }

    private func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Actions

    private func chooseServer() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true   // the build lands in the hidden .build folder
        panel.message = "Choose dechaff-mcp — it's in DeChaffKit/.build/release/ after building."
        if panel.runModal() == .OK, let url = panel.url {
            serverPath = url.path
        }
    }

    /// Runs `dechaff-mcp --version` to confirm the chosen file is the server and that it launches.
    private func testServer() {
        serverVersion = nil
        serverError = nil
        guard let server = resolvedServerPath else {
            serverError = serverPath.isEmpty
                ? "This copy of DeChaff doesn't include the MCP server. Choose a build under Advanced."
                : "No executable file at that path — build the server first."
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: server)
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var output = ""
            var ok = false
            do {
                try process.run()
                output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                process.waitUntilExit()
                ok = process.terminationStatus == 0 && output.hasPrefix("dechaff-mcp")
            } catch {
                output = error.localizedDescription
            }
            DispatchQueue.main.async {
                if ok { serverVersion = output }
                else {
                    serverError = serverPath.isEmpty
                        ? "The built-in server didn't start: \(output)"
                        : "That file didn't respond like dechaff-mcp. Choose DeChaffKit/.build/release/dechaff-mcp."
                }
            }
        }
    }

    private func addToClaudeDesktop() {
        guard let server = resolvedServerPath else { return }
        let url = Self.claudeDesktopConfig
        do {
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                // Refuse to touch a config we can't parse rather than overwrite it.
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    desktopMessage = "Claude Desktop's config isn't a JSON object — add DeChaff by hand below."
                    return
                }
                root = parsed
                try data.write(to: url.appendingPathExtension("bak"), options: .atomic)
            }
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers["dechaff"] = serverEntry(server)
            root["mcpServers"] = servers
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            desktopMessage = "Added. Quit and reopen Claude Desktop to start using DeChaff."
        } catch {
            desktopMessage = "Couldn't update Claude Desktop's config: \(error.localizedDescription)"
        }
    }

    private func showClaudeDesktopConfig() {
        let url = Self.claudeDesktopConfig
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            desktopMessage = "Claude Desktop has no config file yet — use Add to Claude Desktop to create it."
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
                    .accessibilityLabel("Insert \(chip.trimmingCharacters(in: CharacterSet(charactersIn: "{}")))")
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
