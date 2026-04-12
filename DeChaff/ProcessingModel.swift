import SwiftUI
import AppKit
import AVFoundation
import Speech
import CoreMedia
import UserNotifications

// MARK: - ProcessingModel

@MainActor
class ProcessingModel: ObservableObject {
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var logs: [String] = []
    @Published var outputURL: URL?
    @Published var isDone = false

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

    var tagYear: String { String(Calendar.current.component(.year, from: tagDate)) }

    var tagDatePrefix: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: tagDate)
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
        isProcessing = false
        isDone = false
        logs = []
        outputURL = nil
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
        let isYouTubeDownload = url.lastPathComponent.hasPrefix("dechaff-yt-")
        let dir = isYouTubeDownload
            ? (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? url.deletingLastPathComponent().path)
            : url.deletingLastPathComponent().path
        let namePart = resolveFilename(template: filenameTemplate, fallback: baseName)
        let outputPath = "\(dir)/\(namePart).\(outputFormat.fileExtension)"

        let trimIn  = trimInSeconds
        let trimOut = trimOutSeconds > trimIn ? trimOutSeconds : inputDuration

        isProcessing = true
        isDone = false
        progress = 0
        logs = ["Input: \(url.lastPathComponent)"]
        if trimIn > 0 || trimOut < inputDuration - 0.1 {
            logs.append(String(format: "Trim: %@ – %@", formatPlaybackTime(trimIn), formatPlaybackTime(trimOut)))
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
            compressorThreshold: Float(compressorThreshold),
            compressorHeadRoom:  Float(compressorHeadRoom),
            compressorAttack:    Float(compressorAttack),
            compressorRelease:   Float(compressorRelease),
            compressorMakeupGain: Float(compressorMakeupGain)
        )

        let metadata = ID3Metadata(
            title: [tagSermonTitle, tagBibleReading].filter { !$0.isEmpty }.joined(separator: ", "),
            artist: tagPreacher, album: tagSeries, year: tagYear, artwork: tagArtwork
        )
        let capturedChapters = chapters

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let processor = VoiceIsolationProcessor()
            let success = processor.process(
                inputPath: inputPath,
                outputPath: outputPath,
                options: options,
                progressHandler: { p in DispatchQueue.main.async {
                    self?.progress = p
                    Self.updateDockProgress(p)
                } },
                logHandler:      { m in DispatchQueue.main.async { self?.logs.append(m) } }
            )
            let segments = processor.detectedSilenceSegments

            var outputChapters: [Chapter] = capturedChapters
            if success && !segments.isEmpty {
                outputChapters = capturedChapters.map { c in
                    var c2 = c; c2.timeSeconds = remapChapterTime(c.timeSeconds, using: segments); return c2
                }
            }

            if success && options.outputFormat == .mp3 {
                processor.writeTags(chapters: outputChapters, metadata: metadata, to: outputPath) { msg in
                    DispatchQueue.main.async { self?.logs.append(msg) }
                }
            }

            DispatchQueue.main.async {
                self?.isProcessing = false
                self?.isDone = success
                if !success { self?.outputURL = nil }
                if success { self?.chapters = outputChapters }
                Self.clearDockProgress()
                if success { self?.postFinishNotification() }
            }
        }
    }

    // MARK: - Playback (forwarded to PlaybackState)

    func togglePlayback() { playback.toggle(url: inputURL) }
    func pausePlayback()  { playback.pause() }
    func stopPlayback()   { playback.stop() }
    func seekPlayback(to time: Double) { playback.seek(to: time) }

    /// Resolves the filename template into a sanitised file name (without extension).
    /// Empty placeholder segments are collapsed so the result is clean.
    func resolveFilename(template: String, fallback: String) -> String {
        let values: [String: String] = [
            "date":     tagDatePrefix,
            "title":    tagSermonTitle,
            "reading":  tagBibleReading,
            "preacher": tagPreacher,
            "series":   tagSeries,
        ]

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

        var result = resolved.joined(separator: " | ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)

        return result.isEmpty ? "\(fallback)_dechaff" : result
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
        dockProgressView?.progress = value
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

        let systemPrompt = aiAssistantPrompt
            .replacingOccurrences(of: "{title}", with: tagSermonTitle)
            .replacingOccurrences(of: "{preacher}", with: tagPreacher)
            .replacingOccurrences(of: "{series}", with: tagSeries)
            .replacingOccurrences(of: "{reading}", with: tagBibleReading)
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

        // If the trim-transcript words are already available, derive the text from them
        // directly — no need to run the speech recogniser again.
        let existingWords = trimWords.filter { $0.startTime >= trimIn && $0.endTime <= trimOut + 0.5 }
        if !existingWords.isEmpty {
            transcriptText = existingWords.map { $0.text }.joined(separator: " ")
            isTranscribing = false
            if aiAssistantEnabled { startAIAssistant() }
            return
        }

        // Fall back to a full transcription pass if trim words aren't ready yet.
        let capturedURL = inputURL!
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

                let extracted = try extractTrimmedAudio(from: capturedURL, trimIn: trimIn, trimOut: trimOut)
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
                // Check / install on-device speech models
                let probe = SpeechTranscriber(locale: .current, preset: .timeIndexedProgressiveTranscription)
                let status = await AssetInventory.status(forModules: [probe])
                if status == .unsupported {
                    await MainActor.run { [weak self] in
                        self?.trimTranscriptError = "On-device speech recognition requires Apple Silicon and macOS 26+."
                        self?.isTrimTranscribing = false
                    }
                    return
                }
                if status < .installed {
                    if let dl = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                        try await dl.downloadAndInstall()
                    }
                }

                // Get file duration and plan 4 equal chunks with 5 s overlap
                let asset = AVURLAsset(url: capturedURL)
                let duration = try await asset.load(.duration).seconds
                guard duration > 0 else { throw CocoaError(.fileReadInvalidFileName) }

                let nChunks = 4
                let chunkSecs = duration / Double(nChunks)
                let overlapSecs = 5.0
                let chunkStarts = (0..<nChunks).map { Double($0) * chunkSecs }
                let chunkEnds   = chunkStarts.map { min($0 + chunkSecs + overlapSecs, duration) }

                // Shared state accessed by concurrent chunk tasks via actors.
                actor ChunkProgress {
                    private var values: [Double]
                    init(count: Int) { values = Array(repeating: 0.0, count: count) }
                    func update(index: Int, value: Double) { values[index] = value }
                    var overall: Double { values.reduce(0, +) / Double(values.count) }
                }
                actor ChunkAccumulator {
                    private var words: [[TranscriptWord]]
                    init(count: Int) { words = Array(repeating: [], count: count) }
                    func append(_ batch: [TranscriptWord], to index: Int) { words[index] += batch }
                    func set(_ final: [TranscriptWord], at index: Int) { words[index] = final }
                    var all: [[TranscriptWord]] { words }
                }
                let chunkProgress   = ChunkProgress(count: nChunks)
                let chunkAccumulator = ChunkAccumulator(count: nChunks)

                // Transcribe all 4 chunks in parallel.
                // Words stream into the UI via onWords as each result is finalised.
                try await withThrowingTaskGroup(of: (Int, [TranscriptWord]).self) { group in
                    for i in 0..<nChunks {
                        let s = chunkStarts[i], e = chunkEnds[i], idx = i
                        group.addTask {
                            let tempURL = try extractTrimmedAudio(from: capturedURL, trimIn: s, trimOut: e)
                            defer { try? FileManager.default.removeItem(at: tempURL) }
                            let words = try await transcribeChunkWords(
                                url: tempURL, timeOffset: s, chunkDuration: chunkSecs,
                                onProgress: { p in
                                    await chunkProgress.update(index: idx, value: p)
                                    let overall = await chunkProgress.overall
                                    await MainActor.run { self.trimTranscriptProgress = overall }
                                },
                                onWords: { batch in
                                    await chunkAccumulator.append(batch, to: idx)
                                    let partial = mergeTranscriptChunks(
                                        chunkWords: await chunkAccumulator.all,
                                        chunkStarts: chunkStarts, overlapSecs: overlapSecs)
                                    await MainActor.run { self.trimWords = partial }
                                }
                            )
                            // Chunk fully done — snap its progress to 1.0 so the bar
                            // doesn't stall waiting for recogniser lookahead to drain.
                            await chunkProgress.update(index: idx, value: 1.0)
                            let overall = await chunkProgress.overall
                            await MainActor.run { self.trimTranscriptProgress = overall }
                            return (idx, words)
                        }
                    }
                    // As each chunk completes, replace its accumulated words with the
                    // authoritative final list (handles any overlap-dedup edge cases).
                    for try await (idx, words) in group {
                        try Task.checkCancellation()
                        await chunkAccumulator.set(words, at: idx)
                        let partial = mergeTranscriptChunks(
                            chunkWords: await chunkAccumulator.all,
                            chunkStarts: chunkStarts, overlapSecs: overlapSecs)
                        await MainActor.run { [weak self] in self?.trimWords = partial }
                    }
                }

                let merged = mergeTranscriptChunks(
                    chunkWords: await chunkAccumulator.all,
                    chunkStarts: chunkStarts, overlapSecs: overlapSecs)
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
            await MainActor.run { [weak self] in
                self?.trimTranscriptProgress = 1.0
                self?.isTrimTranscribing = false
            }
        }
    }
}
