import SwiftUI
import UniformTypeIdentifiers
import AppKit
import AVFoundation
import Accelerate
import Speech
import CoreMedia
import UserNotifications

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
    @Published var doSlowLeveler: Bool = false
    @Published var doTranscription = true

    // Transcription state
    @Published var transcriptText = ""
    @Published var isTranscribing = false
    @Published var transcriptError: String? = nil
    private var transcriptionTask: Task<Void, Never>?

    // AI Assistant state
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
            voiceIsolation:     doIsolation,
            compression:        doCompression,
            normalization:      doNormalization,
            monoOutput:         monoOutput,
            targetLUFS:         targetLUFS,
            outputFormat:       outputFormat,
            mp3Bitrate:         mp3Bitrate,
            shortenSilences:    shortenSilences,
            maxSilenceDuration: maxSilenceDuration,
            slowLeveler:        doSlowLeveler,
            trimInSeconds:      trimIn,
            trimOutSeconds:     trimOut
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
        waveformZoom = max(1.0, min(40.0, waveformZoom * (1.0 + dy * factor)))
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
        guard let url = inputURL else { return }
        transcriptionTask?.cancel()
        transcriptText = ""; transcriptError = nil; isTranscribing = true
        let capturedURL = url
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
                // Results loop finished — clear spinner before awaiting analysis cleanup
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
            await MainActor.run { [weak self] in self?.isTranscribing = false }  // safety net
        }
    }
}

// MARK: - Transcription helpers

func extractTrimmedAudio(from sourceURL: URL, trimIn: Double, trimOut: Double) throws -> URL {
    let source = try AVAudioFile(forReading: sourceURL)
    let format = source.processingFormat
    let sr = format.sampleRate
    let startFrame = AVAudioFramePosition(trimIn * sr)
    let endFrame: AVAudioFramePosition = trimOut > trimIn + 0.5
        ? min(AVAudioFramePosition(trimOut * sr), source.length) : source.length
    let totalFrames = AVAudioFrameCount(max(0, endFrame - startFrame))
    guard totalFrames > 0 else { throw CocoaError(.fileReadInvalidFileName) }
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dechaff_transcript_\(UUID().uuidString).caf")
    let dest = try AVAudioFile(forWriting: tempURL, settings: format.settings)
    source.framePosition = startFrame
    let chunkSize: AVAudioFrameCount = 65536
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
        throw CocoaError(.fileReadUnknown)
    }
    var remaining = totalFrames
    while remaining > 0 {
        let toRead = min(chunkSize, remaining)
        buffer.frameLength = toRead
        try source.read(into: buffer, frameCount: toRead)
        try dest.write(from: buffer)
        remaining -= toRead
    }
    return tempURL
}

// MARK: - Waveform generation (moved to WaveformTileCache.swift)

// MARK: - WaveformView (viewport-rendered waveform with pan + zoom)

struct WaveformView: View {
    let waveformData: WaveformData
    let duration: Double
    @Binding var trimIn: Double
    @Binding var trimOut: Double
    let playhead: Double
    let chapters: [Chapter]
    let trimInOffset: Double
    var onSeek: (Double) -> Void
    var onChapterMove: ((UUID, Double) -> Void)?
    var onTrimDragEnd: ((_ oldIn: Double, _ oldOut: Double) -> Void)?
    var onChapterDragEnd: ((_ id: UUID, _ oldTime: Double) -> Void)?
    @Binding var zoom: Double
    @Binding var visibleStart: Double
    var onViewWidth: ((CGFloat) -> Void)?
    var onCursorFraction: ((Double) -> Void)?
    let tileCache: WaveformTileCache

    @State private var dragHandle: Int? = nil   // 0=trimIn 1=trimOut -1=tap -2=chapter -3=pan
    @State private var dragChapterID: UUID? = nil
    @State private var dragStartTrimIn: Double = 0
    @State private var dragStartTrimOut: Double = 0
    @State private var dragStartChapterTime: Double = 0
    @State private var dragStartVisibleStart: Double = 0
    @State private var lastMagnification: Double = 1.0
    @State private var viewportWidth: CGFloat = 700

    private var visibleDuration: Double { duration / zoom }
    private var fullWidth: CGFloat { viewportWidth * CGFloat(zoom) }

    private func clampStart(_ s: Double) -> Double { max(0, min(s, duration - visibleDuration)) }

    /// Map a time value to an x-coordinate in viewport space.
    private func viewportX(_ t: Double) -> CGFloat {
        CGFloat((t - visibleStart) / visibleDuration) * viewportWidth
    }

    /// Map an x-coordinate in viewport space to a time value.
    private func timeAt(_ x: CGFloat) -> Double {
        max(0, min(duration, visibleStart + Double(x / viewportWidth) * visibleDuration))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let _ = DispatchQueue.main.async { viewportWidth = w; onViewWidth?(w) }

            ZStack(alignment: .topLeading) {
                // Layer 1: Tiled waveform — only renders the visible slice
                WaveformTiledContent(
                    waveformData: waveformData,
                    duration: duration,
                    trimIn: trimIn,
                    trimOut: trimOut,
                    tileCache: tileCache,
                    viewportWidth: w,
                    visibleStart: visibleStart,
                    visibleDuration: visibleDuration,
                    height: h,
                    zoom: zoom
                )

                // Layer 2: Overlay — dim regions, handles, chapters, playhead in viewport coords
                Canvas { ctx, size in
                    let vw = size.width
                    let fh = size.height
                    guard duration > 0 else { return }

                    // Dim outside trim
                    let trimInX  = viewportX(trimIn)
                    let trimOutX = viewportX(trimOut)
                    let dimColor = Color.black.opacity(0.35)
                    if trimInX > 0 {
                        ctx.fill(Path(CGRect(x: 0, y: 0, width: min(trimInX, vw), height: fh)), with: .color(dimColor))
                    }
                    if trimOutX < vw {
                        ctx.fill(Path(CGRect(x: max(0, trimOutX), y: 0, width: vw - max(0, trimOutX), height: fh)), with: .color(dimColor))
                    }

                    // Chapter markers
                    var lastLabelX: CGFloat = -100
                    for chapter in chapters.sorted(by: { $0.timeSeconds < $1.timeSeconds }) {
                        let inputTime = chapter.timeSeconds + trimInOffset
                        let x = viewportX(inputTime)
                        guard x >= 0 && x <= vw else { continue }
                        let isDragging = chapter.id == dragChapterID
                        let chapterColor = Color.accentColor
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: fh)) },
                                   with: .color(isDragging ? Color.yellow : chapterColor.opacity(0.8)),
                                   lineWidth: isDragging ? 2 : 1.5)
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: fh * 0.5 - 4, width: 8, height: 8)),
                                 with: .color(isDragging ? Color.yellow : chapterColor.opacity(0.7)))
                        if x - lastLabelX >= 30 {
                            let label = chapter.title.isEmpty ? "●" : String(chapter.title.prefix(12))
                            ctx.draw(Text(label).font(.system(size: 9, weight: isDragging ? .bold : .regular))
                                        .foregroundStyle(isDragging ? Color.yellow : chapterColor),
                                     at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                            lastLabelX = x
                        }
                    }

                    // Trim handles
                    func drawHandle(x: CGFloat) {
                        guard x >= -9 && x <= vw + 9 else { return }
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: fh)) },
                                   with: .color(.white.opacity(0.35)), lineWidth: 6)
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: fh)) },
                                   with: .color(.orange), lineWidth: 2)
                        ctx.fill(Path { p in
                            p.move(to: CGPoint(x: x - 9, y: 0)); p.addLine(to: CGPoint(x: x + 9, y: 0))
                            p.addLine(to: CGPoint(x: x, y: 14)); p.closeSubpath()
                        }, with: .color(.orange))
                        ctx.fill(Path { p in
                            p.move(to: CGPoint(x: x - 9, y: fh)); p.addLine(to: CGPoint(x: x + 9, y: fh))
                            p.addLine(to: CGPoint(x: x, y: fh - 14)); p.closeSubpath()
                        }, with: .color(.orange))
                    }
                    drawHandle(x: trimInX)
                    drawHandle(x: trimOutX)

                    // Playhead
                    let phX = viewportX(playhead)
                    if phX >= 0 && phX <= vw {
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: phX, y: 0)); p.addLine(to: CGPoint(x: phX, y: fh)) },
                                   with: .color(Color(red: 1.0, green: 0.78, blue: 0.0)), lineWidth: 1.5)
                    }
                }
                .allowsHitTesting(false)

                // Layer 3: Gesture capture
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard duration > 0 else { return }
                                let startX = value.startLocation.x
                                let curX   = value.location.x
                                let dx = value.translation.width
                                let dy = value.translation.height

                                if dragHandle == nil {
                                    // Decide what was grabbed at the initial touch point
                                    let inX  = viewportX(trimIn)
                                    let outX = viewportX(trimOut)
                                    let dIn  = abs(startX - inX)
                                    let dOut = abs(startX - outX)
                                    if dIn <= 12 || dOut <= 12 {
                                        dragHandle = dIn < dOut ? 0 : 1
                                        dragStartTrimIn = trimIn
                                        dragStartTrimOut = trimOut
                                    } else {
                                        var best: (dist: CGFloat, id: UUID)? = nil
                                        for ch in chapters {
                                            let cx = viewportX(ch.timeSeconds + trimInOffset)
                                            let d  = abs(startX - cx)
                                            if d <= 10, best == nil || d < best!.dist { best = (d, ch.id) }
                                        }
                                        if let hit = best {
                                            dragHandle = -2; dragChapterID = hit.id
                                            dragStartChapterTime = chapters.first(where: { $0.id == hit.id })?.timeSeconds ?? 0
                                        } else if abs(dx) > 4 && abs(dx) >= abs(dy) && zoom > 1.0 {
                                            // Horizontal pan — only when zoomed in and clearly horizontal
                                            dragHandle = -3
                                            dragStartVisibleStart = visibleStart
                                        } else if abs(dx) > 4 || abs(dy) > 4 {
                                            dragHandle = -1  // unrecognised drag — ignore
                                        }
                                        // if movement < 4pt in any direction, leave dragHandle nil (possible tap)
                                    }
                                }

                                switch dragHandle {
                                case 0:
                                    trimIn = min(timeAt(curX), trimOut - 0.5); onSeek(trimIn)
                                case 1:
                                    trimOut = max(timeAt(curX), trimIn + 0.5); onSeek(trimOut)
                                case -2:
                                    if let id = dragChapterID {
                                        let time = timeAt(curX)
                                        onChapterMove?(id, max(0, time - trimInOffset))
                                        onSeek(time)
                                    }
                                case -3:
                                    // Pan: shift visibleStart opposite to drag direction
                                    let timeDelta = Double(-dx / viewportWidth) * visibleDuration
                                    visibleStart = clampStart(dragStartVisibleStart + timeDelta)
                                default: break
                                }
                            }
                            .onEnded { value in
                                let totalMove = abs(value.translation.width) + abs(value.translation.height)
                                if dragHandle == nil || (dragHandle == -1 && totalMove < 5) {
                                    // Tap — seek to tapped position
                                    onSeek(timeAt(value.startLocation.x))
                                }
                                if dragHandle == 0 || dragHandle == 1 {
                                    if trimIn != dragStartTrimIn || trimOut != dragStartTrimOut {
                                        onTrimDragEnd?(dragStartTrimIn, dragStartTrimOut)
                                    }
                                }
                                if dragHandle == -2, let id = dragChapterID {
                                    let currentTime = chapters.first(where: { $0.id == id })?.timeSeconds ?? 0
                                    if currentTime != dragStartChapterTime {
                                        onChapterDragEnd?(id, dragStartChapterTime)
                                    }
                                }
                                dragHandle = nil; dragChapterID = nil
                            }
                    )

                // Zoom level indicator
                if zoom > 1.01 {
                    VStack {
                        HStack {
                            Spacer()
                            Text(zoom >= 10 ? String(format: "%.0f×", zoom) : String(format: "%.1f×", zoom))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                        }
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let delta = Double(value) / lastMagnification
                        lastMagnification = Double(value)
                        let centre = visibleStart + visibleDuration / 2
                        zoom = max(1.0, min(40.0, zoom * delta))
                        visibleStart = clampStart(centre - visibleDuration / 2)
                        tileCache.invalidateAll()
                    }
                    .onEnded { _ in lastMagnification = 1.0 }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) { zoom = 1.0; visibleStart = 0 }
                tileCache.invalidateAll()
            }
            .onContinuousHover { phase in
                if case .active(let loc) = phase, viewportWidth > 0 {
                    onCursorFraction?(Double(loc.x / viewportWidth))
                }
            }
            .onChange(of: playhead) { ph in
                guard zoom > 1.0 else { return }
                let vEnd = visibleStart + visibleDuration
                if ph < visibleStart || ph > vEnd {
                    visibleStart = clampStart(ph - visibleDuration * 0.1)
                }
            }
            .onChange(of: duration) { _ in zoom = 1.0; visibleStart = 0 }
        }
    }
}

// MARK: - Tiled waveform content (viewport-only rendering)

private struct WaveformTiledContent: View {
    let waveformData: WaveformData
    let duration: Double
    let trimIn: Double
    let trimOut: Double
    let tileCache: WaveformTileCache
    let viewportWidth: CGFloat
    let visibleStart: Double
    let visibleDuration: Double
    let height: CGFloat
    let zoom: Double

    var body: some View {
        Canvas { ctx, size in
            let vw = size.width
            let h = size.height
            guard duration > 0, vw > 0, visibleDuration > 0 else { return }

            let (peaks, fpp) = waveformData.peaks(forZoom: zoom, viewportWidth: viewportWidth)
            guard !peaks.isEmpty else { return }

            // Full virtual content width at this zoom level
            let fullW = viewportWidth * CGFloat(zoom)
            let tileW = tileCache.tileWidth
            let totalTiles = Int(ceil(fullW / tileW))
            let quantZoom = WaveformTileCache.quantiseZoom(zoom)
            let trimInHash = Int(trimIn * 100)
            let trimOutHash = Int(trimOut * 100)

            let accentCG = NSColor.controlAccentColor.cgColor
            let dimCG = NSColor.secondaryLabelColor.withAlphaComponent(0.4).cgColor

            // Pixel offset of the visible window within the full virtual content
            let visibleStartPx = CGFloat(visibleStart / duration) * fullW

            // Only render tiles that overlap the visible viewport
            let firstTile = max(0, Int(visibleStartPx / tileW))
            let lastTile  = min(totalTiles - 1, Int((visibleStartPx + vw) / tileW))
            guard firstTile <= lastTile else { return }

            for ti in firstTile...lastTile {
                let tileOriginPx  = CGFloat(ti) * tileW
                let tileOriginSec = Double(tileOriginPx / fullW) * duration
                let tileDurSec    = Double(tileW / fullW) * duration
                let drawX         = tileOriginPx - visibleStartPx  // x in viewport space

                let key = WaveformTileCache.TileKey(
                    zoomLevel: quantZoom, tileIndex: ti,
                    trimInHash: trimInHash, trimOutHash: trimOutHash
                )

                let image: CGImage?
                if let cached = tileCache.tile(for: key) {
                    image = cached
                } else {
                    image = tileCache.renderTile(
                        key: key, peaks: peaks, framesPerPeak: fpp,
                        sampleRate: waveformData.sampleRate, duration: duration,
                        tileOriginSeconds: tileOriginSec, tileDurationSeconds: tileDurSec,
                        trimIn: trimIn, trimOut: trimOut, height: h,
                        accentColor: accentCG, dimColor: dimCG
                    )
                }

                if let image {
                    let rect = CGRect(x: drawX, y: 0, width: tileW, height: h)
                    ctx.draw(Image(decorative: image, scale: 1), in: rect)
                }
            }
        }
    }
}

// MARK: - Helpers

func formatPlaybackTime(_ seconds: Double) -> String {
    let t = max(0, seconds)
    let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

// MARK: - PlaybackState

/// Isolated `@Observable` for playback so that the 20 Hz timer only invalidates
/// views that read `isPlaying` or `playheadSeconds`, not the entire hierarchy.
@MainActor @Observable
final class PlaybackState {
    var isPlaying = false
    var playheadSeconds: Double = 0

    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?

    func toggle(url: URL?) {
        isPlaying ? pause() : playFrom(playheadSeconds, url: url)
    }

    func playFrom(_ t: Double, url: URL?) {
        guard let url, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        audioPlayer = player
        player.currentTime = t
        player.play()
        isPlaying = true
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let p = self.audioPlayer else { return }
            self.playheadSeconds = p.currentTime
            if !p.isPlaying { self.isPlaying = false; self.playbackTimer?.invalidate() }
        }
    }

    func pause() {
        audioPlayer?.pause(); isPlaying = false; playbackTimer?.invalidate()
    }

    func stop() {
        audioPlayer?.stop(); audioPlayer = nil
        isPlaying = false; playbackTimer?.invalidate(); playheadSeconds = 0
    }

    func seek(to time: Double) {
        playheadSeconds = time
        audioPlayer?.currentTime = time
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject var model = ProcessingModel()
    @EnvironmentObject var ytManager: YtDlpManager
    @StateObject var youtube = YouTubeViewModel()
    @State var currentStep = 0
    @State var isTargeted = false
    @State var isArtworkTargeted = false
    @State private var scrollMonitor: Any?
    @State private var clickMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var showLog = false
    @AppStorage("dechaff.youtube.channelURL") var ytChannelURL = "https://www.youtube.com/@cityonahillnz"
    @AppStorage("dechaff.youtube.videoLimit") var ytVideoLimit = 10
    @State var ytTab: Int = 2   // 0 = YouTube URL, 1 = Videos, 2 = Live Streams
    @State var ytDirectURL: String = ""
    @Environment(\.undoManager) var undoManager

    let stepTitles = ["Load", "Trim", "Info", "Chapters", "Output"]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                appHeader
                if !model.isProcessing && !model.isDone {
                    stepIndicator
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider()

            ZStack {
                if model.isProcessing {
                    processingView.transition(.opacity)
                } else if model.isDone {
                    doneView.transition(.opacity)
                } else {
                    stepContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: model.isProcessing)
            .animation(.easeInOut(duration: 0.2), value: model.isDone)

            if !model.isProcessing && !model.isDone {
                Divider()
                navigationFooter
                    .padding(.horizontal, 36)
                    .padding(.vertical, 16)
            }
        }
        .frame(width: 760)
        .frame(minHeight: 520)
        .focusedSceneValue(\.processingModel, model)
        .focusedSceneValue(\.currentStep, $currentStep)
        .focusedSceneValue(\.appActions, AppActions(
            openFile: { openFilePicker() },
            addChapter: { addChapterAtPlayhead() },
            startProcessing: { startProcessing() }
        ))
        .focusedSceneValue(\.windowUndoManager, undoManager)
        .onAppear {
            setupMonitors()
            Task { await ytManager.checkAndUpdate() }
        }
        .onDisappear { teardownMonitors() }
        .onReceive(NotificationCenter.default.publisher(for: .openAudioFile)) { notif in
            guard let url = notif.object as? URL else { return }
            model.loadFile(url: url)
            withAnimation { currentStep = 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadFromURL)) { notif in
            guard let rawURL = notif.object as? String else { return }
            youtube.selectURL(rawURL, manager: ytManager) { fileURL in
                model.loadFile(url: fileURL)
                withAnimation { currentStep = 1 }
            }
        }
    }

    // MARK: - App Header

    private var appHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            if let img = NSImage(named: "Wheat") {
                Image(nsImage: img).resizable().scaledToFit().frame(width: 22, height: 22)
            }
            Text("DeChaff").font(.system(size: 17, weight: .semibold))
            Spacer()
            if let url = model.inputURL {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").foregroundStyle(.secondary).font(.caption)
                    Text(url.lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(0..<stepTitles.count, id: \.self) { step in
                HStack(spacing: 0) {
                    stepDot(step: step)
                    if step < stepTitles.count - 1 {
                        Rectangle()
                            .fill(step < currentStep ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2))
                            .frame(height: 1.5)
                            .frame(maxWidth: .infinity)
                            .animation(.easeInOut(duration: 0.25), value: currentStep)
                    }
                }
            }
        }
    }

    private func stepDot(step: Int) -> some View {
        let isCompleted = step < currentStep
        let isCurrent   = step == currentStep
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(isCompleted ? Color.accentColor
                          : isCurrent  ? Color.accentColor.opacity(0.12)
                          : Color.secondary.opacity(0.1))
                    .frame(width: 30, height: 30)
                    .animation(.easeInOut(duration: 0.25), value: currentStep)
                if isCompleted {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(step + 1)")
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                }
            }
            Text(stepTitles[step])
                .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .animation(.easeInOut(duration: 0.25), value: currentStep)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step + 1): \(stepTitles[step])")
        .accessibilityValue(isCompleted ? "completed" : isCurrent ? "current" : "upcoming")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    // MARK: - Navigation Footer

    private var navigationFooter: some View {
        HStack {
            if currentStep > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { currentStep -= 1 }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("Back")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Spacer()
            if currentStep < stepTitles.count - 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { currentStep += 1 }
                } label: {
                    HStack(spacing: 4) {
                        Text("Next")
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canAdvance)
            } else {
                Button { startProcessing() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.badge.sparkles")
                        Text("Process").fontWeight(.semibold)
                    }
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isProcessing || model.isLoadingWaveform)
            }
        }
    }

    private var canAdvance: Bool {
        switch currentStep {
        case 0: return model.inputURL != nil && !model.isLoadingWaveform
        default: return true
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        ZStack {
            if currentStep == 0 { step1View.transition(.opacity) }
            if currentStep == 1 { step2View.transition(.opacity) }
            if currentStep == 2 { step3View.transition(.opacity) }
            if currentStep == 3 { step4View.transition(.opacity) }
            if currentStep == 4 { step5View.transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.18), value: currentStep)
        .onChange(of: currentStep) { newStep in
            if newStep != 1 && newStep != 3 { model.pausePlayback() }
            if newStep == 3, model.inputDuration > 0 {
                // Scroll waveform to the trim-in point when entering chapters step
                let visibleDuration = model.inputDuration / model.waveformZoom
                model.waveformVisibleStart = max(0, min(model.trimInSeconds, model.inputDuration - visibleDuration))
            }
        }
    }

    // MARK: - Processing View

    private var processingView: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 6) {
                Text(model.processingStageLabel)
                    .font(.title3.weight(.medium))
                    .animation(.default, value: model.processingStageLabel)
                Text("This may take a few minutes for long recordings")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(width: 380)
                Text("\(Int(model.progress * 100))%")
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !model.logs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Button { withAnimation { showLog.toggle() } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showLog ? "chevron.down" : "chevron.right").font(.caption2)
                            Text("Show details").font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    if showLog {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(Array(model.logs.enumerated()), id: \.offset) { idx, msg in
                                        Text(msg)
                                            .font(.system(.caption2, design: .monospaced))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .id(idx)
                                    }
                                }
                                .padding(10)
                            }
                            .frame(width: 380, height: 80)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .onChange(of: model.logs.count) { count in
                                if count > 0 { withAnimation { proxy.scrollTo(count - 1) } }
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Processing audio")
        .accessibilityValue("\(Int(model.progress * 100)) percent, \(model.processingStageLabel)")
    }

    // MARK: - Done View

    private var doneView: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 52)).foregroundStyle(.green)
                    Text("Done!").font(.title2.weight(.semibold))
                    if let url = model.outputURL {
                        Text(url.lastPathComponent)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 48)
                            .draggable(url)
                            .help("Drag to export the file")
                    }
                }
                .padding(.top, 28)

                HStack(spacing: 12) {
                    if let url = model.outputURL {
                        Button {
                            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                        } label: { Label("Reveal in Finder", systemImage: "folder") }
                        .buttonStyle(.borderedProminent).controlSize(.large)

                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                    }
                    Button("Process Another") {
                        model.isDone = false; model.outputURL = nil
                        withAnimation { currentStep = 0 }
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }

                if model.doTranscription {
                    Divider().padding(.horizontal, 36)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center) {
                            Text("Transcript").font(.headline)
                            Spacer()
                            if !model.transcriptText.isEmpty && model.transcriptError == nil {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green).font(.caption)
                                    Text("Done").font(.caption).foregroundStyle(.secondary)
                                }
                            } else if model.isTranscribing {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.65)
                                    Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if !model.transcriptText.isEmpty {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(model.transcriptText, forType: .string)
                                } label: { Label("Copy", systemImage: "doc.on.doc") }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        if let error = model.transcriptError {
                            Text(error).font(.subheadline).foregroundStyle(.red)
                        } else if model.transcriptText.isEmpty {
                            Text(model.isTranscribing ? "Generating transcript…" : "No transcript available.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                Text(model.transcriptText)
                                    .textSelection(.enabled).font(.subheadline)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            }
                            .frame(maxHeight: 180)
                            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 36)
                }

                if model.aiAssistantEnabled {
                    Divider().padding(.horizontal, 36)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center) {
                            Text("AI Assistant").font(.headline)
                            Spacer()
                            if !model.aiAssistantResponse.isEmpty && model.aiAssistantError == nil {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green).font(.caption)
                                    Text("Done").font(.caption).foregroundStyle(.secondary)
                                }
                            } else if model.isAIAssistantLoading {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.65)
                                    Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if !model.aiAssistantResponse.isEmpty {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(model.aiAssistantResponse, forType: .string)
                                } label: { Label("Copy", systemImage: "doc.on.doc") }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                            if !model.isAIAssistantLoading {
                                Button {
                                    model.startAIAssistant()
                                } label: { Label("Retry", systemImage: "arrow.clockwise") }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(model.transcriptText.isEmpty)
                            }
                        }
                        if let error = model.aiAssistantError {
                            Text(error).font(.subheadline).foregroundStyle(.red)
                        } else if model.aiAssistantResponse.isEmpty {
                            if model.isAIAssistantLoading {
                                Text("Sending transcript to Claude…")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            } else if model.transcriptText.isEmpty {
                                Text("Waiting for transcript…")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                Text("Click Retry to send transcript to Claude.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        } else {
                            ScrollView {
                                Text(model.aiAssistantResponse)
                                    .textSelection(.enabled).font(.subheadline)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            }
                            .frame(maxHeight: 300)
                            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 36)
                }
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shared view helpers (used by multiple steps)

    func waveformBlock(showChapters: Bool) -> some View {
        Group {
            if model.isLoadingWaveform {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.75)
                    Text("Loading waveform…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.waveformSamples.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform").font(.system(size: 30, weight: .light)).foregroundStyle(.quaternary)
                    Text("Load a file first").font(.caption).foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let data = model.waveformData {
                WaveformView(
                    waveformData: data,
                    duration: model.inputDuration,
                    trimIn: $model.trimInSeconds,
                    trimOut: $model.trimOutSeconds,
                    playhead: model.playback.playheadSeconds,
                    chapters: showChapters ? model.chapters : [],
                    trimInOffset: model.trimInSeconds,
                    onSeek: { model.seekPlayback(to: $0) },
                    onChapterMove: showChapters ? { id, newTime in
                        if let idx = model.chapters.firstIndex(where: { $0.id == id }) {
                            model.chapters[idx].timeSeconds = newTime
                        }
                    } : nil,
                    onTrimDragEnd: { oldIn, oldOut in
                        registerTrimUndo(oldIn: oldIn, oldOut: oldOut)
                    },
                    onChapterDragEnd: showChapters ? { id, oldTime in
                        registerChapterMoveUndo(id: id, oldTime: oldTime)
                    } : nil,
                    zoom: $model.waveformZoom,
                    visibleStart: $model.waveformVisibleStart,
                    onViewWidth: { model.waveformViewWidth = $0 },
                    onCursorFraction: { model.waveformCursorFraction = $0 },
                    tileCache: model.tileCache
                )
            }
        }
        .frame(height: 120)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waveform editor")
        .accessibilityValue(model.inputDuration > 0
            ? "Duration \(formatPlaybackTime(model.inputDuration)), trim \(formatPlaybackTime(model.trimInSeconds)) to \(formatPlaybackTime(model.trimOutSeconds))"
            : "No audio loaded")
    }

    func playbackControls(showSetInOut: Bool) -> some View {
        HStack(spacing: 10) {
            playPauseButton
            playheadTimeLabel
            Spacer()
            if showSetInOut {
                Button("Set In") {
                    let oldIn = model.trimInSeconds
                    let oldOut = model.trimOutSeconds
                    model.trimInSeconds = min(model.playback.playheadSeconds, model.trimOutSeconds - 0.5)
                    registerTrimUndo(oldIn: oldIn, oldOut: oldOut)
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.waveformSamples.isEmpty)

                Text("\(formatPlaybackTime(model.trimInSeconds)) – \(formatPlaybackTime(model.trimOutSeconds))")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)

                Button("Set Out") {
                    let oldIn = model.trimInSeconds
                    let oldOut = model.trimOutSeconds
                    model.trimOutSeconds = max(model.playback.playheadSeconds, model.trimInSeconds + 0.5)
                    registerTrimUndo(oldIn: oldIn, oldOut: oldOut)
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.waveformSamples.isEmpty)
            }
        }
    }

    var playPauseButton: some View {
        Button { model.togglePlayback() } label: {
            Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .disabled(model.waveformSamples.isEmpty)
    }

    var playheadTimeLabel: some View {
        Text(formatPlaybackTime(model.playback.playheadSeconds))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
    }

    func stepHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Undo/Redo

    func registerTrimUndo(oldIn: Double, oldOut: Double) {
        let newIn = model.trimInSeconds
        let newOut = model.trimOutSeconds
        undoManager?.registerUndo(withTarget: model) { m in
            m.trimInSeconds = oldIn
            m.trimOutSeconds = oldOut
            self.undoManager?.registerUndo(withTarget: m) { m in
                m.trimInSeconds = newIn
                m.trimOutSeconds = newOut
            }
            self.undoManager?.setActionName("Trim")
        }
        undoManager?.setActionName("Trim")
    }

    func registerChapterMoveUndo(id: UUID, oldTime: Double) {
        guard let idx = model.chapters.firstIndex(where: { $0.id == id }) else { return }
        let newTime = model.chapters[idx].timeSeconds
        undoManager?.registerUndo(withTarget: model) { m in
            if let i = m.chapters.firstIndex(where: { $0.id == id }) {
                m.chapters[i].timeSeconds = oldTime
            }
            self.undoManager?.registerUndo(withTarget: m) { m in
                if let i = m.chapters.firstIndex(where: { $0.id == id }) {
                    m.chapters[i].timeSeconds = newTime
                }
            }
            self.undoManager?.setActionName("Move Chapter")
        }
        undoManager?.setActionName("Move Chapter")
    }

    func registerChapterAddUndo(chapter: Chapter) {
        undoManager?.registerUndo(withTarget: model) { m in
            m.chapters.removeAll { $0.id == chapter.id }
            self.undoManager?.registerUndo(withTarget: m) { m in
                m.chapters.append(chapter)
                m.chapters.sort { $0.timeSeconds < $1.timeSeconds }
            }
            self.undoManager?.setActionName("Add Chapter")
        }
        undoManager?.setActionName("Add Chapter")
    }

    func registerChapterRemoveUndo(chapter: Chapter) {
        undoManager?.registerUndo(withTarget: model) { m in
            m.chapters.append(chapter)
            m.chapters.sort { $0.timeSeconds < $1.timeSeconds }
            self.undoManager?.registerUndo(withTarget: m) { m in
                m.chapters.removeAll { $0.id == chapter.id }
            }
            self.undoManager?.setActionName("Remove Chapter")
        }
        undoManager?.setActionName("Remove Chapter")
    }

    func registerArtworkUndo(oldArtwork: Data?) {
        let newArtwork = model.tagArtwork
        undoManager?.registerUndo(withTarget: model) { m in
            m.tagArtwork = oldArtwork
            self.undoManager?.registerUndo(withTarget: m) { m in
                m.tagArtwork = newArtwork
            }
            self.undoManager?.setActionName("Artwork")
        }
        undoManager?.setActionName("Artwork")
    }

    // MARK: - Event Monitors

    private func setupMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Let text fields handle their own keys
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            // Spacebar — play/pause on waveform steps
            if event.keyCode == 49,
               self.model.inputURL != nil,
               self.currentStep == 1 || self.currentStep == 3 {
                self.model.togglePlayback()
                return nil
            }
            return event
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if let window = NSApp.keyWindow,
               let hit = window.contentView?.hitTest(event.locationInWindow),
               !(hit is NSTextView || hit is NSTextField) {
                window.makeFirstResponder(nil)
            }
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard self.model.inputURL != nil, self.currentStep == 1 || self.currentStep == 3 else { return event }
            let dy = Double(event.scrollingDeltaY)
            let dx = Double(event.scrollingDeltaX)
            let precise = event.hasPreciseScrollingDeltas
            if abs(dy) > abs(dx) {
                // Vertical — zoom
                guard abs(dy) > 0.5 else { return event }
                self.model.waveformZoomScroll(dy: dy, isPrecise: precise)
            } else {
                // Horizontal — pan (only when zoomed in)
                guard abs(dx) > 0.5, self.model.waveformZoom > 1.0 else { return event }
                self.model.waveformPanScroll(dx: dx, isPrecise: precise)
            }
            return nil
        }
    }

    private func teardownMonitors() {
        if let m = keyMonitor    { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        if let m = clickMonitor  { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    // MARK: - Processing

    private func startProcessing() {
        model.startProcessing()
        if model.doTranscription {
            model.startTranscription(trimIn: model.trimInSeconds, trimOut: model.trimOutSeconds)
        }
    }
}

#Preview { ContentView() }
