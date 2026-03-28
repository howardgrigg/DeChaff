import SwiftUI
import UniformTypeIdentifiers
import AppKit
import AVFoundation
import Accelerate
import Speech
import CoreMedia

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
        transcriptionTask?.cancel()
        transcriptText = ""; transcriptError = nil; isTranscribing = false

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
        let titleParts = [tagSermonTitle, tagBibleReading].filter { !$0.isEmpty }.joined(separator: ", ")
        let pipeParts  = [titleParts, tagPreacher, tagSeries].filter { !$0.isEmpty }.joined(separator: " | ")
        let namePart   = pipeParts.isEmpty
            ? "\(baseName)_dechaff"
            : pipeParts.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let outputPath = "\(dir)/\(tagDatePrefix) \(namePart).\(outputFormat.fileExtension)"

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
                progressHandler: { p in DispatchQueue.main.async { self?.progress = p } },
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
            }
        }
    }

    // MARK: - Playback (forwarded to PlaybackState)

    func togglePlayback() { playback.toggle(url: inputURL) }
    func pausePlayback()  { playback.pause() }
    func stopPlayback()   { playback.stop() }
    func seekPlayback(to time: Double) { playback.seek(to: time) }

    /// Zoom centred on the playhead position.
    func waveformZoomScroll(dy: Double) {
        guard inputDuration > 0 else { return }
        let anchor = playback.playheadSeconds
        let oldZoom = waveformZoom
        waveformZoom = max(1.0, min(40.0, waveformZoom * (1.0 + dy * 0.025)))
        if waveformZoom != oldZoom { tileCache.invalidateAll() }
        let newVD = inputDuration / waveformZoom
        waveformVisibleStart = max(0, min(anchor - newVD / 2, inputDuration - newVD))
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
                await MainActor.run { [weak self] in self?.isTranscribing = false }
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

// MARK: - WaveformView (ScrollView + tiled CGImage + overlay)

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
    @Binding var zoom: Double
    @Binding var visibleStart: Double
    var onViewWidth: ((CGFloat) -> Void)?
    let tileCache: WaveformTileCache

    @State private var dragHandle: Int? = nil
    @State private var dragChapterID: UUID? = nil
    @State private var lastMagnification: Double = 1.0
    @State private var viewportWidth: CGFloat = 700

    private var visibleDuration: Double { duration / zoom }
    private var fullWidth: CGFloat { viewportWidth * CGFloat(zoom) }

    private func clampStart(_ s: Double) -> Double { max(0, min(s, duration - visibleDuration)) }
    /// Map time to x-coordinate within the full scrollable width.
    private func fullXFor(_ t: Double) -> CGFloat {
        CGFloat(t / duration) * fullWidth
    }
    /// Map x in viewport to time (for gesture handling via visibleStart).
    private func xForViewport(_ t: Double, width: CGFloat) -> CGFloat {
        CGFloat((t - visibleStart) / visibleDuration) * width
    }
    private func timeForViewport(_ x: CGFloat, width: CGFloat) -> Double {
        max(0, min(duration, visibleStart + Double(x / width) * visibleDuration))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let _ = DispatchQueue.main.async { viewportWidth = w; onViewWidth?(w) }

            ZStack {
                // Layer 1: Scrollable tiled waveform with overlays drawn in content
                ScrollView(.horizontal, showsIndicators: zoom > 1.01) {
                    ZStack(alignment: .topLeading) {
                        // Waveform tiles
                        WaveformTiledContent(
                            waveformData: waveformData,
                            duration: duration,
                            trimIn: trimIn,
                            trimOut: trimOut,
                            tileCache: tileCache,
                            viewportWidth: w,
                            height: h,
                            zoom: zoom
                        )

                        // Overlay: dim regions, handles, chapters, playhead — all at time positions
                        Canvas { ctx, size in
                            let fw = size.width
                            let fh = size.height
                            guard duration > 0 else { return }

                            // Dim outside trim
                            let trimInX  = fullXFor(trimIn)
                            let trimOutX = fullXFor(trimOut)
                            let dimColor = Color.black.opacity(0.35)
                            if trimInX > 0 {
                                ctx.fill(Path(CGRect(x: 0, y: 0, width: trimInX, height: fh)), with: .color(dimColor))
                            }
                            if trimOutX < fw {
                                ctx.fill(Path(CGRect(x: trimOutX, y: 0, width: fw - trimOutX, height: fh)), with: .color(dimColor))
                            }

                            // Chapter markers
                            var lastLabelX: CGFloat = -100
                            for chapter in chapters.sorted(by: { $0.timeSeconds < $1.timeSeconds }) {
                                let inputTime = chapter.timeSeconds + trimInOffset
                                let x = fullXFor(inputTime)
                                guard x >= 0 && x <= fw else { continue }
                                let isDragging = chapter.id == dragChapterID
                                ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: fh)) },
                                           with: .color(isDragging ? Color.yellow : Color.purple.opacity(0.8)),
                                           lineWidth: isDragging ? 2 : 1.5)
                                ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: fh * 0.5 - 4, width: 8, height: 8)),
                                         with: .color(isDragging ? Color.yellow : Color.purple.opacity(0.7)))
                                if x - lastLabelX >= 30 {
                                    let label = chapter.title.isEmpty ? "●" : String(chapter.title.prefix(12))
                                    ctx.draw(Text(label).font(.system(size: 9, weight: isDragging ? .bold : .regular))
                                                .foregroundStyle(isDragging ? Color.yellow : Color.purple),
                                             at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                                    lastLabelX = x
                                }
                            }

                            // Trim handles
                            func drawHandle(x: CGFloat) {
                                guard x >= -9 && x <= fw + 9 else { return }
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
                            let phX = fullXFor(playhead)
                            if phX >= 0 && phX <= fw {
                                ctx.stroke(Path { p in p.move(to: CGPoint(x: phX, y: 0)); p.addLine(to: CGPoint(x: phX, y: fh)) },
                                           with: .color(Color(red: 1.0, green: 0.78, blue: 0.0)), lineWidth: 1.5)
                            }
                        }
                        .allowsHitTesting(false)

                        // Gesture layer — inside scroll content so positions map to time
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard duration > 0 else { return }
                                        // Positions are in scroll content coordinates (0...fullWidth)
                                        let startX = value.startLocation.x
                                        let curX   = value.location.x
                                        if dragHandle == nil {
                                            let inX  = fullXFor(trimIn)
                                            let outX = fullXFor(trimOut)
                                            let dIn  = abs(startX - inX)
                                            let dOut = abs(startX - outX)
                                            if dIn <= 12 || dOut <= 12 {
                                                dragHandle = dIn < dOut ? 0 : 1
                                            } else {
                                                var best: (dist: CGFloat, id: UUID)? = nil
                                                for ch in chapters {
                                                    let cx = fullXFor(ch.timeSeconds + trimInOffset)
                                                    let d  = abs(startX - cx)
                                                    if d <= 10, best == nil || d < best!.dist { best = (d, ch.id) }
                                                }
                                                if let hit = best {
                                                    dragHandle = -2; dragChapterID = hit.id
                                                } else {
                                                    dragHandle = -1
                                                }
                                            }
                                        }
                                        let time = max(0, min(duration, Double(curX / fullWidth) * duration))
                                        switch dragHandle {
                                        case 0: trimIn = min(time, trimOut - 0.5); onSeek(trimIn)
                                        case 1: trimOut = max(time, trimIn + 0.5); onSeek(trimOut)
                                        case -2:
                                            if let id = dragChapterID {
                                                onChapterMove?(id, max(0, time - trimInOffset))
                                                onSeek(time)
                                            }
                                        default: break
                                        }
                                    }
                                    .onEnded { value in
                                        if dragHandle == -1 && abs(value.translation.width) < 5 {
                                            let time = max(0, min(duration, Double(value.location.x / fullWidth) * duration))
                                            onSeek(time)
                                        }
                                        dragHandle = nil; dragChapterID = nil
                                    }
                            )
                    }
                    .frame(width: fullWidth, height: h)
                    .background(GeometryReader { inner in
                        Color.clear.preference(
                            key: ScrollOffsetKey.self,
                            value: inner.frame(in: .named("waveformScroll")).minX
                        )
                    })
                }
                .coordinateSpace(name: "waveformScroll")
                .onPreferenceChange(ScrollOffsetKey.self) { offset in
                    let newStart = Double(-offset / fullWidth) * duration
                    let clamped = clampStart(newStart)
                    if abs(clamped - visibleStart) > 0.001 {
                        visibleStart = clamped
                    }
                }

                // Fixed viewport overlay: zoom indicator only
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

// Preference key to read scroll offset
private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Tiled waveform content (inside ScrollView)

private struct WaveformTiledContent: View {
    let waveformData: WaveformData
    let duration: Double
    let trimIn: Double
    let trimOut: Double
    let tileCache: WaveformTileCache
    let viewportWidth: CGFloat
    let height: CGFloat
    let zoom: Double

    var body: some View {
        Canvas { ctx, size in
            let fullW = size.width
            let h = size.height
            guard duration > 0, fullW > 0 else { return }

            let (peaks, fpp) = waveformData.peaks(forZoom: zoom, viewportWidth: viewportWidth)
            guard !peaks.isEmpty else { return }

            let tileW = tileCache.tileWidth
            let tileCount = Int(ceil(fullW / tileW))
            let quantZoom = WaveformTileCache.quantiseZoom(zoom)
            let trimInHash = Int(trimIn * 100)
            let trimOutHash = Int(trimOut * 100)

            let accentCG = NSColor.controlAccentColor.cgColor
            let dimCG = NSColor.secondaryLabelColor.withAlphaComponent(0.4).cgColor

            for ti in 0..<tileCount {
                let tileX = CGFloat(ti) * tileW
                let tileOriginSec = Double(tileX / fullW) * duration
                let tileDurSec = Double(tileW / fullW) * duration
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
                    let rect = CGRect(x: tileX, y: 0, width: tileW, height: h)
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
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var clickMonitor: Any?
    @State private var showLog = false
    @AppStorage("dechaff.youtube.channelURL") var ytChannelURL = "https://www.youtube.com/@cityonahillnz"
    @AppStorage("dechaff.youtube.videoLimit") var ytVideoLimit = 10
    @State var ytTab: Int = 2   // 0 = YouTube URL, 1 = Videos, 2 = Live Streams
    @State var ytDirectURL: String = ""

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
        .onAppear {
            setupMonitors()
            Task { await ytManager.checkAndUpdate() }
        }
        .onDisappear { teardownMonitors() }
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
                    }
                }
                .padding(.top, 28)

                HStack(spacing: 12) {
                    if let url = model.outputURL {
                        Button {
                            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                        } label: { Label("Reveal in Finder", systemImage: "folder") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
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
                    .padding(.bottom, 28)
                }
            }
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
                    zoom: $model.waveformZoom,
                    visibleStart: $model.waveformVisibleStart,
                    onViewWidth: { model.waveformViewWidth = $0 },
                    tileCache: model.tileCache
                )
            }
        }
        .frame(height: 120)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1))
    }

    func playbackControls(showSetInOut: Bool) -> some View {
        HStack(spacing: 10) {
            playPauseButton
            playheadTimeLabel
            Spacer()
            if showSetInOut {
                Button("Set In") {
                    model.trimInSeconds = min(model.playback.playheadSeconds, model.trimOutSeconds - 0.5)
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.waveformSamples.isEmpty)

                Text("\(formatPlaybackTime(model.trimInSeconds)) – \(formatPlaybackTime(model.trimOutSeconds))")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)

                Button("Set Out") {
                    model.trimOutSeconds = max(model.playback.playheadSeconds, model.trimInSeconds + 0.5)
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

    // MARK: - Event Monitors

    private func setupMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let responder = NSApp.keyWindow?.firstResponder
            let isTyping = responder is NSTextView || responder is NSTextField
            guard !isTyping else { return event }
            switch event.keyCode {
            case 49: // Spacebar — play/pause on trim or chapters step
                if self.currentStep == 1 || self.currentStep == 3 {
                    self.model.togglePlayback(); return nil
                }
            case 34: // I — set mark-in on trim step
                if self.currentStep == 1 && !self.model.waveformSamples.isEmpty {
                    self.model.trimInSeconds = min(self.model.playback.playheadSeconds, self.model.trimOutSeconds - 0.5)
                    return nil
                }
            case 31: // O — set mark-out on trim step
                if self.currentStep == 1 && !self.model.waveformSamples.isEmpty {
                    self.model.trimOutSeconds = max(self.model.playback.playheadSeconds, self.model.trimInSeconds + 0.5)
                    return nil
                }
            default: break
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
            // Only consume vertical scroll for zoom; let horizontal pass through to the native ScrollView
            let dy = Double(event.scrollingDeltaY)
            guard abs(dy) > abs(Double(event.scrollingDeltaX)) else { return event }
            guard abs(dy) > 0.5 else { return event }
            self.model.waveformZoomScroll(dy: dy)
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
