import SwiftUI
import AppKit
import AVFoundation
import Speech
import CoreMedia
import UserNotifications
import DeChaffCore

// MARK: - ProcessingModel

@MainActor
class ProcessingModel: ObservableObject {
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var logs: [String] = []
    @Published var outputURL: URL?
    @Published var isDone = false
    /// Duration of the finished MP3, measured once processing succeeds. Zero until
    /// then — the AI assistant falls back to the pre-silence-shortening estimate.
    @Published var outputDurationSeconds: Double = 0

    /// The processor for the run in flight — kept so Cancel can reach it.
    private var activeProcessor: EpisodeProcessor?
    /// Read by the app delegate to guard against quitting mid-run.
    private(set) static var isAnyProcessing = false

    func cancelProcessing() {
        activeProcessor?.cancel()
    }

    // Processing options — all on by default
    @Published var doIsolation   = true
    @Published var doCompression = true
    @Published var doNormalization = true
    @Published var monoOutput    = true
    @Published var targetLUFS: Double = -16.0
    @Published var outputFormat: OutputFormat = .mp3
    @Published var mp3Bitrate: Int = 64
    @Published var chapters: [Chapter] = []
    @Published var shortenSilences: Bool = true
    @Published var maxSilenceDuration: Double = 1.0
    @Published var doSlowLeveler: Bool = true
    @Published var skipIsolationOnMusic: Bool = false


    // Transcription state (output step — plain text, no timings needed)
    @Published var transcriptText = ""
    @Published var isTranscribing = false
    @Published var transcriptError: String? = nil
    private var transcriptionTask: Task<Void, Never>?

    // Trim-transcription state (word-level timings for transcript trim UI)
    @Published var trimWords: [TranscriptWord] = []
    @Published var isTrimTranscribing = false
    @Published var trimTranscriptError: String? = nil
    @Published var trimTranscriptProgress: Double = 0   // 0.0–1.0 across all chunks
    private var trimTranscriptionTask: Task<Void, Never>? = nil

    // AI Assistant state
    // Compressor settings — persisted so the user's preferred values survive app restarts
    @AppStorage("dechaff.compressor.threshold")  var compressorThreshold:  Double = -28.0
    @AppStorage("dechaff.compressor.headRoom")   var compressorHeadRoom:   Double =   6.0
    @AppStorage("dechaff.compressor.attack")     var compressorAttack:     Double =   0.003
    @AppStorage("dechaff.compressor.release")    var compressorRelease:    Double =   0.150
    @AppStorage("dechaff.compressor.makeupGain") var compressorMakeupGain: Double =   8.0

    @AppStorage("dechaff.ai.enabled") var aiAssistantEnabled = false
    @AppStorage("dechaff.ai.prompt") var aiAssistantPrompt = AIAssistantSettingsView.defaultPrompt
    @AppStorage("dechaff.ai.model") var aiModel = ClaudeModel.defaultID
    @AppStorage("dechaff.titleFormat") var titleFormat = defaultTitleFormat
    @AppStorage("dechaff.filenameTemplate") var filenameTemplate = defaultFilenameTemplate
    @Published var aiAssistantResponse = ""
    @Published var isAIAssistantLoading = false
    @Published var aiAssistantError: String? = nil
    private var aiAssistantTask: Task<Void, Never>?

    @Published var tagSermonTitle  = ""
    @Published var tagBibleReading = ""
    @Published var tagPreacher = "" {
        didSet { UserDefaults.standard.set(tagPreacher, forKey: "dechaff.preacher") }
    }
    @Published var tagSeries = "" {
        didSet { UserDefaults.standard.set(tagSeries, forKey: "dechaff.series") }
    }
    @Published var tagDate: Date = Date() {
        didSet { UserDefaults.standard.set(tagDate.timeIntervalSinceReferenceDate, forKey: "dechaff.date") }
    }

    /// The Info-step fields as one value for the processing core.
    var tags: SermonTags {
        SermonTags(title: tagSermonTitle, reading: tagBibleReading, preacher: tagPreacher,
                   series: tagSeries, date: tagDate, artwork: tagArtwork)
    }

    @Published var tagArtwork: Data? = nil {
        didSet {
            UserDefaults.standard.set(tagArtwork, forKey: "dechaff.artwork")
            cachedArtworkImage = tagArtwork.flatMap { NSImage(data: $0) }
        }
    }
    /// Cached NSImage derived from tagArtwork — avoids re-decoding on every SwiftUI redraw.
    var cachedArtworkImage: NSImage? = nil

    // File load state
    @Published var inputURL: URL? = nil
    @Published var inputDuration: Double = 0
    @Published var waveformSamples: [Float] = []  // kept for isEmpty checks
    @Published var isLoadingWaveform = false

    // Multi-resolution waveform data
    @Published var waveformData: WaveformData? = nil
    let tileCache = WaveformTileCache()

    // Trim
    @Published var trimInSeconds: Double = 0
    @Published var trimOutSeconds: Double = 0
    /// Notes from snapping transcript-chosen trim points to silence; empty when both cuts were clean.
    @Published var trimRefinementNotes: [String] = []
    private var trimRefinementTask: Task<Void, Never>? = nil

    // Excluded ranges — spans cut out of the middle of the recording (source seconds).
    @Published var excludedRanges: [ExcludedRange] = []
    // Pending selection on the trim step, in source seconds. A selection is only
    // meaningful once it spans more than a moment; `hasSelection` is the gate.
    @Published var selectionStart: Double = 0
    @Published var selectionEnd: Double = 0

    var hasSelection: Bool { selectionEnd > selectionStart + 0.05 }

    /// The spans of source audio that survive trim + exclusions — the K timeline.
    /// Everything that needs to convert between timelines derives from this.
    var keptSpans: [KeptSpan] {
        keptRanges(trimIn: trimInSeconds,
                   trimOut: trimOutSeconds > trimInSeconds ? trimOutSeconds : inputDuration,
                   excluding: excludedRanges)
    }

    /// Duration of the audio that will be processed, before silence shortening.
    var keptDurationSeconds: Double { keptDuration(keptSpans) }

    /// Adds the pending selection as an excluded range and clears the selection.
    /// Returns the range so the caller can register undo.
    @discardableResult
    func excludeSelection() -> ExcludedRange? {
        guard hasSelection else { return nil }
        let range = ExcludedRange(startSeconds: selectionStart, endSeconds: selectionEnd)
        excludedRanges.append(range)
        excludedRanges.sort { $0.startSeconds < $1.startSeconds }
        clearSelection()
        return range
    }

    func clearSelection() {
        selectionStart = 0
        selectionEnd = 0
    }

    // Playback — isolated into @Observable so the 20 Hz timer updates only
    // redraw views that actually read playback.isPlaying / playback.playheadSeconds,
    // not the entire view hierarchy.
    let playback = PlaybackState()

    // Waveform viewport
    @Published var waveformZoom: Double = 1.0
    @Published var waveformVisibleStart: Double = 0.0
    var waveformViewWidth: CGFloat = 700
    /// Cursor position as fraction [0,1] across the visible viewport — used as zoom anchor.
    var waveformCursorFraction: Double = 0.5

    init() {
        tagSeries   = UserDefaults.standard.string(forKey: "dechaff.series") ?? ""
        tagPreacher = UserDefaults.standard.string(forKey: "dechaff.preacher") ?? ""
        tagArtwork  = UserDefaults.standard.data(forKey: "dechaff.artwork")
        cachedArtworkImage = tagArtwork.flatMap { NSImage(data: $0) }
        let stored  = UserDefaults.standard.double(forKey: "dechaff.date")
        if stored != 0 { tagDate = Date(timeIntervalSinceReferenceDate: stored) }
    }

    var processingStageLabel: String {
        if progress < 0.65 { return "Cleaning audio…" }
        if progress < 0.85 { return "Adjusting levels…" }
        if progress < 0.99 { return "Encoding MP3…" }
        return "Finishing up…"
    }

    func loadFile(url: URL) {
        // Clean up any previous yt-dlp temp download
        if let old = inputURL, old.lastPathComponent.hasPrefix("dechaff-yt-") {
            try? FileManager.default.removeItem(at: old)
        }
        inputURL = url
        if !url.lastPathComponent.hasPrefix("dechaff-yt-") {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        inputDuration = 0
        waveformSamples = []
        waveformData = nil
        tileCache.invalidateAll()
        isLoadingWaveform = true
        trimInSeconds = 0
        trimOutSeconds = 0
        trimRefinementTask?.cancel(); trimRefinementNotes = []
        excludedRanges = []
        clearSelection()
        isProcessing = false
        isDone = false
        logs = []
        outputURL = nil
        outputDurationSeconds = 0
        chapters = []
        stopPlayback()
        waveformZoom = 1.0; waveformVisibleStart = 0.0
        tagSermonTitle = ""; tagBibleReading = ""
        tagDate = Date()
        transcriptionTask?.cancel()
        transcriptText = ""; transcriptError = nil; isTranscribing = false
        trimTranscriptionTask?.cancel()
        trimWords = []; trimTranscriptError = nil; isTrimTranscribing = false; trimTranscriptProgress = 0
        aiAssistantTask?.cancel()
        aiAssistantResponse = ""; aiAssistantError = nil; isAIAssistantLoading = false

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let (data, duration) = await generateMultiResWaveform(url: url)
            await MainActor.run {
                self.inputDuration = duration
                self.trimOutSeconds = duration
                self.waveformData = data
                // Keep waveformSamples populated for isEmpty checks elsewhere
                self.waveformSamples = data?.level2 ?? []
                self.isLoadingWaveform = false
            }
        }
    }

    func startProcessing() {
        guard let url = inputURL, !isProcessing else { return }
        let inputPath = url.path
        let baseName = url.deletingPathExtension().lastPathComponent
        let dir = defaultOutputDirectory(for: url).path
        let namePart = resolveFilename(template: filenameTemplate, fallback: baseName)
        var resolvedPath = "\(dir)/\(namePart).\(outputFormat.fileExtension)"

        if resolvedPath == inputPath {
            // Never write over the file we're reading from
            resolvedPath = uniqueOutputPath(for: resolvedPath)
        } else if FileManager.default.fileExists(atPath: resolvedPath) {
            switch confirmOverwrite(filename: URL(fileURLWithPath: resolvedPath).lastPathComponent) {
            case .replace:  break
            case .keepBoth: resolvedPath = uniqueOutputPath(for: resolvedPath)
            case .cancel:   return
            }
        }
        let outputPath = resolvedPath

        let trimIn  = trimInSeconds
        let trimOut = trimOutSeconds > trimIn ? trimOutSeconds : inputDuration
        let exclusions = excludedRanges
        let spans = keptRanges(trimIn: trimIn, trimOut: trimOut, excluding: exclusions)

        isProcessing = true
        isDone = false
        progress = 0
        logs = ["Input: \(url.lastPathComponent)"]
        if trimIn > 0 || trimOut < inputDuration - 0.1 {
            logs.append(String(format: "Trim: %@ – %@", formatPlaybackTime(trimIn), formatPlaybackTime(trimOut)))
        }
        if spans.count > 1 {
            let cut = (trimOut - trimIn) - keptDuration(spans)
            logs.append(String(format: "Excluded: %d section%@ (%@ removed)",
                               spans.count - 1, spans.count == 2 ? "" : "s", formatPlaybackTime(cut)))
        }
        outputURL = URL(fileURLWithPath: outputPath)

        let options = ProcessingOptions(
            voiceIsolation:      doIsolation,
            compression:         doCompression,
            normalization:       doNormalization,
            monoOutput:          monoOutput,
            targetLUFS:          targetLUFS,
            outputFormat:        outputFormat,
            mp3Bitrate:          mp3Bitrate,
            shortenSilences:     shortenSilences,
            maxSilenceDuration:  maxSilenceDuration,
            slowLeveler:         doSlowLeveler,
            trimInSeconds:       trimIn,
            trimOutSeconds:      trimOut,
            excludedRanges:      exclusions,
            skipIsolationOnMusic: skipIsolationOnMusic,
            compressorThreshold: Float(compressorThreshold),
            compressorHeadRoom:  Float(compressorHeadRoom),
            compressorAttack:    Float(compressorAttack),
            compressorRelease:   Float(compressorRelease),
            compressorMakeupGain: Float(compressorMakeupGain)
        )

        let request = EpisodeRequest(
            inputURL: url, outputURL: URL(fileURLWithPath: outputPath),
            options: options, metadata: tags.id3, chapters: chapters
        )
        let processor = EpisodeProcessor()
        activeProcessor = processor
        Self.isAnyProcessing = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Throttle before the main-thread hop: the passes report per 4096-frame
            // chunk (hundreds of times/sec) and every published update re-renders
            // the whole window. 0.1% steps are finer than the bar can display.
            var lastReported: Double = -1
            let outcome = processor.run(
                request,
                progress: { p in
                    guard p - lastReported >= 0.001 || p >= 1.0 else { return }
                    lastReported = p
                    DispatchQueue.main.async {
                        self?.progress = p
                        Self.updateDockProgress(p)
                    }
                },
                log: { m in DispatchQueue.main.async { self?.logs.append(m) } }
            )

            DispatchQueue.main.async {
                self?.isProcessing = false
                switch outcome {
                case .finished:
                    self?.isDone = true
                case .failed:
                    self?.isDone = false
                    self?.outputURL = nil
                case .cancelled:
                    self?.isDone = false
                    self?.outputURL = nil
                    self?.logs.append("⏹ Processing cancelled")
                }
                self?.activeProcessor = nil
                Self.isAnyProcessing = false
                Self.clearDockProgress()
                if case .finished = outcome {
                    self?.postFinishNotification()
                    // Measure the real output so {duration} is exact rather than the
                    // estimate; silence shortening makes the two differ noticeably.
                    let finished = URL(fileURLWithPath: outputPath)
                    Task { @MainActor [weak self] in
                        let seconds = try? await AVURLAsset(url: finished).load(.duration).seconds
                        if let seconds, seconds > 0 { self?.outputDurationSeconds = seconds }
                    }
                }
            }
        }
    }

    // MARK: - Output overwrite handling

    private enum OverwriteChoice { case replace, keepBoth, cancel }

    private func confirmOverwrite(filename: String) -> OverwriteChoice {
        let alert = NSAlert()
        alert.messageText = "“\(filename)” already exists"
        alert.informativeText = "A file with this name is already in the output folder. Keep both, or replace the existing file?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .keepBoth
        case .alertSecondButtonReturn: return .replace
        default:                       return .cancel
        }
    }

    // MARK: - Playback (forwarded to PlaybackState)

    func togglePlayback() {
        // Auto-pause at trim-out; playing from beyond it auditions the cut region freely.
        playback.stopAt = playback.playheadSeconds < trimOutSeconds - 0.05 ? trimOutSeconds : nil
        playback.skipRanges = excludedPlaybackRanges
        playback.toggle(url: inputURL)
    }
    func pausePlayback()  { playback.pause() }
    func stopPlayback()   { playback.stop() }
    func seekPlayback(to time: Double) {
        playback.stopAt = time < trimOutSeconds - 0.05 ? trimOutSeconds : nil
        playback.skipRanges = excludedPlaybackRanges
        playback.seek(to: time)
    }

    /// Excluded spans as playback skip ranges, so auditioning the trim step plays
    /// what the listener will actually hear. Derived from the gaps between kept
    /// spans, so it reflects the same normalisation the pipeline uses.
    private var excludedPlaybackRanges: [(start: Double, end: Double)] {
        let spans = keptSpans
        guard spans.count > 1 else { return [] }
        return zip(spans, spans.dropFirst()).map { (start: $0.end, end: $1.start) }
    }

    /// Resolves the filename template into a sanitised file name (without extension).
    /// Empty placeholder segments are collapsed so the result is clean.
    func resolveFilename(template: String, fallback: String) -> String {
        FilenameTemplate.resolve(template, values: tags.templateValues) ?? "\(fallback)_dechaff"
    }

    /// Pan by a horizontal scroll delta (points).
    func waveformPanScroll(dx: Double, isPrecise: Bool) {
        guard inputDuration > 0, waveformZoom > 1.0 else { return }
        let visibleDuration = inputDuration / waveformZoom
        // Scale: how much time one viewport-pixel represents
        let secondsPerPixel = visibleDuration / Double(waveformViewWidth)
        // Trackpad sends precise deltas in points; mouse wheel sends line-based deltas (larger steps)
        let pixelDelta = isPrecise ? dx : dx * 8
        waveformVisibleStart = max(0, min(waveformVisibleStart + pixelDelta * secondsPerPixel, inputDuration - visibleDuration))
    }

    /// Zoom anchored on the cursor position within the visible range.
    func waveformZoomScroll(dy: Double, isPrecise: Bool) {
        guard inputDuration > 0 else { return }
        let visibleDuration = inputDuration / waveformZoom
        let anchor = waveformVisibleStart + waveformCursorFraction * visibleDuration
        let factor = isPrecise ? 0.012 : 0.06
        let oldZoom = waveformZoom
        waveformZoom = max(1.0, min(1000.0, waveformZoom * (1.0 + dy * factor)))
        if waveformZoom != oldZoom { tileCache.invalidateAll() }
        let newVD = inputDuration / waveformZoom
        waveformVisibleStart = max(0, min(anchor - waveformCursorFraction * newVD, inputDuration - newVD))
    }

    // MARK: - Dock icon progress

    private static var dockProgressView: DockProgressView?

    static func updateDockProgress(_ value: Double) {
        let dockTile = NSApp.dockTile
        if dockProgressView == nil {
            let size = dockTile.size
            let view = DockProgressView(frame: NSRect(origin: .zero, size: size))
            view.icon = NSApp.applicationIconImage
            dockTile.contentView = view
            dockProgressView = view
        }
        guard let view = dockProgressView else { return }
        // The dock bar is ~100 px wide — redrawing for sub-0.5% steps is pure waste
        guard abs(value - view.progress) >= 0.005 || value >= 1.0 else { return }
        view.progress = value
        dockTile.display()
    }

    static func clearDockProgress() {
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.display()
        dockProgressView = nil
    }

    // MARK: - Finish notification
}

/// Custom NSView that draws the app icon with a progress bar overlay for the dock tile.
private class DockProgressView: NSView {
    var icon: NSImage?
    var progress: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        icon?.draw(in: bounds)

        let barHeight: CGFloat = 12
        let barInset: CGFloat = 8
        let barY: CGFloat = 4
        let barRect = NSRect(x: barInset, y: barY, width: bounds.width - barInset * 2, height: barHeight)

        // Track background
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

        // Filled portion
        let fillWidth = max(barHeight, barRect.width * CGFloat(progress))
        let fillRect = NSRect(x: barRect.origin.x, y: barRect.origin.y, width: fillWidth, height: barHeight)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    }
}

extension ProcessingModel {

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postFinishNotification() {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Processing Complete"
        let filename = outputURL?.lastPathComponent ?? "sermon"
        content.body = "Your sermon is ready: \(filename)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func startAIAssistant() {
        guard aiAssistantEnabled, !transcriptText.isEmpty else { return }
        guard let keyData = KeychainHelper.load(account: "claude-api-key"),
              let apiKey = String(data: keyData, encoding: .utf8), !apiKey.isEmpty else {
            aiAssistantError = ClaudeAPIError.noAPIKey.localizedDescription
            return
        }
        aiAssistantTask?.cancel()
        aiAssistantResponse = ""; aiAssistantError = nil; isAIAssistantLoading = true

        // Duration prefers the measured output; before processing finishes, the kept
        // audio length is the closest available figure.
        let durationSeconds = outputDurationSeconds > 0 ? outputDurationSeconds : keptDurationSeconds
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd/MM/yyyy"

        let systemPrompt = aiAssistantPrompt
            .replacingOccurrences(of: "{title}", with: tagSermonTitle)
            .replacingOccurrences(of: "{preacher}", with: tagPreacher)
            .replacingOccurrences(of: "{series}", with: tagSeries)
            .replacingOccurrences(of: "{reading}", with: tagBibleReading)
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: tagDate))
            .replacingOccurrences(of: "{year}", with: tags.year)
            .replacingOccurrences(of: "{duration}", with: formatPlaybackTime(durationSeconds))
        let transcript = transcriptText

        aiAssistantTask = Task {
            do {
                let response = try await ClaudeAPIClient.sendMessage(
                    apiKey: apiKey, model: self.aiModel, systemPrompt: systemPrompt, transcript: transcript
                )
                self.aiAssistantResponse = response
            } catch {
                self.aiAssistantError = error.localizedDescription
            }
            self.isAIAssistantLoading = false
        }
    }

    func startTranscription(trimIn: Double, trimOut: Double) {
        guard inputURL != nil else { return }
        transcriptionTask?.cancel()
        transcriptText = ""; transcriptError = nil; isTranscribing = true

        // The transcript must describe the audio that ships, so excluded spans are
        // dropped from it too — otherwise the AI assistant summarises cut content.
        let spans = keptRanges(trimIn: trimIn, trimOut: trimOut, excluding: excludedRanges)

        // If the trim transcription has already finished, derive the text from its
        // word timings directly — no need to run the speech recogniser again.
        if !isTrimTranscribing && deriveTranscriptFromTrimWords(trimIn: trimIn, trimOut: trimOut, spans: spans) {
            return
        }

        // If it's still running, wait for it and reuse its words — using them now
        // would silently truncate the transcript to whatever chunks have arrived.
        if isTrimTranscribing {
            let pending = trimTranscriptionTask
            transcriptionTask = Task { [weak self] in
                await pending?.value
                guard !Task.isCancelled, let self else { return }
                if self.deriveTranscriptFromTrimWords(trimIn: trimIn, trimOut: trimOut, spans: spans) { return }
                self.startFullTranscription(spans: spans)
            }
            return
        }

        startFullTranscription(spans: spans)
    }

    /// Builds the transcript from completed trim-transcription words.
    /// Returns false if no words fall inside the kept audio (caller runs a full pass).
    @discardableResult
    private func deriveTranscriptFromTrimWords(trimIn: Double, trimOut: Double, spans: [KeptSpan]) -> Bool {
        let words = trimWords.filter { word in
            word.startTime >= trimIn && word.endTime <= trimOut + 0.5
                && !isExcluded(word.startTime, keptRanges: spans)
        }
        guard !words.isEmpty else { return false }
        transcriptText = words.map { $0.text }.joined(separator: " ")
        isTranscribing = false
        if aiAssistantEnabled { startAIAssistant() }
        return true
    }

    private func startFullTranscription(spans: [KeptSpan]) {
        guard let capturedURL = inputURL, !spans.isEmpty else { isTranscribing = false; return }
        transcriptionTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var tempURL: URL? = nil
            do {
                let transcriber = SpeechTranscriber(locale: .current, preset: .progressiveTranscription)
                let status = await AssetInventory.status(forModules: [transcriber])

                if status == .unsupported {
                    await MainActor.run { [weak self] in
                        self?.transcriptError = "On-device speech recognition is not supported. Requires Apple Silicon Mac running macOS 26+."
                        self?.isTranscribing = false
                    }
                    return
                }

                if status < .installed {
                    await MainActor.run { [weak self] in
                        self?.transcriptText = "Downloading speech recognition model — this only happens once…"
                    }
                    if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        try await downloader.downloadAndInstall()
                    }
                    await MainActor.run { [weak self] in
                        if self?.transcriptText == "Downloading speech recognition model — this only happens once…" {
                            self?.transcriptText = ""
                        }
                    }
                }

                let extracted = try extractKeptAudio(from: capturedURL, spans: spans)
                tempURL = extracted

                let file = try AVAudioFile(forReading: extracted)
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                async let analysis: CMTime? = analyzer.analyzeSequence(from: file)

                var finalized = ""
                var volatile = ""
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    let chunk = String(result.text.characters)
                    if result.isFinal {
                        finalized += (finalized.isEmpty ? "" : " ") + chunk
                        volatile = ""
                    } else {
                        volatile = chunk
                    }
                    let display = finalized + (volatile.isEmpty || finalized.isEmpty ? volatile : " " + volatile)
                    await MainActor.run { [weak self] in self?.transcriptText = display }
                }
                await MainActor.run { [weak self] in
                    self?.isTranscribing = false
                    if self?.aiAssistantEnabled == true { self?.startAIAssistant() }
                }
                _ = try await analysis
            } catch is CancellationError {
                // cancelled — leave text as-is
            } catch {
                await MainActor.run { [weak self] in self?.transcriptError = error.localizedDescription }
            }
            if let tmp = tempURL { try? FileManager.default.removeItem(at: tmp) }
            // A cancelled task must not touch state — a replacement task may already be running.
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in self?.isTranscribing = false }
        }
    }

    // MARK: - Trim transcription (word-level timings for transcript trim UI)

    func startTrimTranscription() {
        guard let url = inputURL else { return }
        guard !isTrimTranscribing && trimWords.isEmpty else { return }  // already running or done
        trimTranscriptionTask?.cancel()
        trimWords = []; trimTranscriptError = nil; isTrimTranscribing = true; trimTranscriptProgress = 0
        let capturedURL = url

        trimTranscriptionTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                // Words stream into the UI via onPartial as each result is finalised.
                let merged = try await transcribeWords(
                    url: capturedURL,
                    onProgress: { p in await MainActor.run { self.trimTranscriptProgress = p } },
                    onPartial:  { words in await MainActor.run { self.trimWords = words } }
                )
                await MainActor.run { [weak self] in
                    self?.trimWords = merged
                    self?.isTrimTranscribing = false
                }
            } catch is CancellationError {
                // cancelled — leave words as-is
            } catch {
                await MainActor.run { [weak self] in
                    self?.trimTranscriptError = error.localizedDescription
                    self?.isTrimTranscribing = false
                }
            }
            // A cancelled task must not touch state — a replacement task may already be running.
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.trimTranscriptProgress = 1.0
                self?.isTrimTranscribing = false
            }
        }
    }

    // MARK: - Transcript trim refinement

    /// Trims to keep `trimWords[startWord]…trimWords[endWord]`. The transcript's word
    /// timings apply immediately, then each cut is moved into the surrounding silence
    /// so neither edge clips the start or end of a word.
    func applyTranscriptTrim(startWord: Int, endWord: Int) {
        guard let url = inputURL,
              trimWords.indices.contains(startWord), trimWords.indices.contains(endWord) else { return }
        let words = trimWords
        trimInSeconds  = words[startWord].startTime
        trimOutSeconds = words[endWord].endTime
        trimRefinementNotes = []
        trimRefinementTask?.cancel()

        trimRefinementTask = Task.detached(priority: .userInitiated) { [weak self] in
            let refiner = CutPointRefiner()
            let start = try? refiner.refine(edge: .start, wordIndex: startWord, words: words, audioURL: url)
            let end   = try? refiner.refine(edge: .end, wordIndex: endWord, words: words, audioURL: url)
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled, self.inputURL == url else { return }
                if let start { self.trimInSeconds = start.time }
                if let end {
                    self.trimOutSeconds = self.inputDuration > 0 ? min(end.time, self.inputDuration) : end.time
                }
                self.trimRefinementNotes = [start, end].compactMap { $0 }
                    .filter { $0.quality != .clean }
                    .flatMap { $0.notes }
            }
        }
    }
}
