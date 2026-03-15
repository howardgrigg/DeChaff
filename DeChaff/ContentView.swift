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
    @Published var shortenSilences: Bool = false
    @Published var maxSilenceDuration: Double = 1.0
    @Published var doTranscription = false

    // Transcription state
    @Published var transcriptText = ""
    @Published var isTranscribing = false
    @Published var transcriptError: String? = nil
    private var transcriptionTask: Task<Void, Never>?

    @Published var tagSermonTitle  = ""
    @Published var tagBibleReading = ""
    @Published var tagPreacher     = ""

    @Published var tagSeries = "" {
        didSet { UserDefaults.standard.set(tagSeries, forKey: "dechaff.series") }
    }
    @Published var tagDate: Date = Date() {
        didSet { UserDefaults.standard.set(tagDate.timeIntervalSinceReferenceDate, forKey: "dechaff.date") }
    }

    var tagYear: String {
        String(Calendar.current.component(.year, from: tagDate))
    }

    var tagDatePrefix: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: tagDate)
    }
    @Published var tagArtwork: Data? = nil {
        didSet { UserDefaults.standard.set(tagArtwork, forKey: "dechaff.artwork") }
    }

    // File load state
    @Published var inputURL: URL? = nil
    @Published var inputDuration: Double = 0
    @Published var waveformSamples: [Float] = []
    @Published var isLoadingWaveform = false

    // Trim
    @Published var trimInSeconds: Double = 0
    @Published var trimOutSeconds: Double = 0  // 0 means "use full duration"

    // Playback
    @Published var isPlaying = false
    @Published var playheadSeconds: Double = 0
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?

    // Detail waveform (on-demand, for zoomed-in view)
    @Published var detailSamples: [Float] = []
    @Published var detailRangeStart: Double = 0
    @Published var detailRangeEnd: Double = 0
    private var detailLoadTask: Task<Void, Never>?

    // Waveform viewport (owned here so scroll monitor in ContentView can update them)
    @Published var waveformZoom: Double = 1.0
    @Published var waveformVisibleStart: Double = 0.0
    var waveformViewWidth: CGFloat = 700  // updated by WaveformView geometry

    init() {
        tagSeries  = UserDefaults.standard.string(forKey: "dechaff.series") ?? ""
        tagArtwork = UserDefaults.standard.data(forKey: "dechaff.artwork")
        let stored = UserDefaults.standard.double(forKey: "dechaff.date")
        if stored != 0 { tagDate = Date(timeIntervalSinceReferenceDate: stored) }
    }

    func loadFile(url: URL) {
        inputURL = url
        inputDuration = 0
        waveformSamples = []
        isLoadingWaveform = true
        trimInSeconds = 0
        trimOutSeconds = 0
        isProcessing = false
        isDone = false
        logs = []
        outputURL = nil
        stopPlayback()
        detailLoadTask?.cancel()
        detailSamples = []; detailRangeStart = 0; detailRangeEnd = 0
        waveformZoom = 1.0; waveformVisibleStart = 0.0
        transcriptionTask?.cancel()
        transcriptText = ""; transcriptError = nil; isTranscribing = false

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let (duration, samples) = await generateWaveform(url: url)
            await MainActor.run {
                self.inputDuration = duration
                self.trimOutSeconds = duration
                self.waveformSamples = samples
                self.isLoadingWaveform = false
            }
        }
    }

    func startProcessing() {
        guard let url = inputURL, !isProcessing else { return }
        let inputPath = url.path
        let baseName = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent().path
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
            trimInSeconds:      trimIn,
            trimOutSeconds:     trimOut
        )

        let metadata = ID3Metadata(title: [tagSermonTitle, tagBibleReading].filter { !$0.isEmpty }.joined(separator: ", "),
                                   artist: tagPreacher, album: tagSeries,
                                   year: tagYear, artwork: tagArtwork)
        let capturedChapters = chapters  // capture on main thread before going to background

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

            // Chapters are stored in output time (0 = start of trimmed audio).
            // Just remap for silence removal if needed — no trim offset to subtract.
            var outputChapters: [Chapter] = capturedChapters
            if success && !segments.isEmpty {
                outputChapters = capturedChapters.map { c in
                    var c2 = c
                    c2.timeSeconds = remapChapterTime(c.timeSeconds, using: segments)
                    return c2
                }
            }

            // Write ID3 tags immediately after processing (MP3 only)
            if success && options.outputFormat == .mp3 {
                processor.writeTags(chapters: outputChapters, metadata: metadata,
                                    to: outputPath) { msg in
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

    // MARK: - Playback

    func togglePlayback() {
        isPlaying ? pausePlayback() : playFrom(playheadSeconds)
    }

    func playFrom(_ t: Double) {
        guard let url = inputURL, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        audioPlayer = player
        player.currentTime = t
        player.play()
        isPlaying = true
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let p = self.audioPlayer else { return }
            DispatchQueue.main.async {
                self.playheadSeconds = p.currentTime
                if !p.isPlaying { self.isPlaying = false; self.playbackTimer?.invalidate() }
            }
        }
    }

    func pausePlayback() {
        audioPlayer?.pause()
        isPlaying = false
        playbackTimer?.invalidate()
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        playbackTimer?.invalidate()
        playheadSeconds = 0
    }

    func seekPlayback(to time: Double) {
        playheadSeconds = time
        if let player = audioPlayer {
            player.currentTime = time
        }
    }

    func waveformScroll(dx: Double, dy: Double) {
        guard inputDuration > 0 else { return }
        let visibleDuration = inputDuration / waveformZoom
        if abs(dx) >= abs(dy) {
            guard waveformZoom > 1.0 else { return }
            let shift = dx / Double(waveformViewWidth) * visibleDuration
            let maxStart = inputDuration - visibleDuration
            waveformVisibleStart = max(0, min(waveformVisibleStart + shift, maxStart))
        } else {
            let centre = waveformVisibleStart + visibleDuration / 2
            let factor = 1.0 + dy * 0.025
            waveformZoom = max(1.0, min(40.0, waveformZoom * factor))
            let newVisibleDuration = inputDuration / waveformZoom
            waveformVisibleStart = max(0, min(centre - newVisibleDuration / 2, inputDuration - newVisibleDuration))
        }
    }

    func requestDetailWaveform(start: Double, end: Double) {
        detailLoadTask?.cancel()
        let url = inputURL  // capture on main thread
        detailLoadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self, let url else { return }
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }  // 200ms debounce
            let samples = await generateDetailWaveform(url: url, start: start, end: end)
            await MainActor.run {
                self.detailSamples = samples
                self.detailRangeStart = start
                self.detailRangeEnd = end
            }
        }
    }

    func startTranscription(trimIn: Double) {
        guard let url = inputURL else { return }
        transcriptionTask?.cancel()
        transcriptText = ""; transcriptError = nil; isTranscribing = true
        let capturedURL = url
        let capturedTrimIn = trimIn
        transcriptionTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let transcriber = SpeechTranscriber(locale: .current, preset: .progressiveTranscription)
                let status = await AssetInventory.status(forModules: [transcriber])
                guard status >= .installed else {
                    await MainActor.run { [weak self] in
                        self?.transcriptError = status == .unsupported
                            ? "Speech recognition is not supported on this device."
                            : "Speech recognition model is not installed. Go to System Settings → Accessibility → Speech to download it."
                        self?.isTranscribing = false
                    }
                    return
                }
                let file = try AVAudioFile(forReading: capturedURL)
                if capturedTrimIn > 0 {
                    file.framePosition = AVAudioFramePosition(capturedTrimIn * file.processingFormat.sampleRate)
                }
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                async let analysis: CMTime? = analyzer.analyzeSequence(from: file)
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    let chunk = String(result.text.characters)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if !self.transcriptText.isEmpty { self.transcriptText += " " }
                        self.transcriptText += chunk
                    }
                }
                _ = try await analysis
            } catch is CancellationError {
                // cancelled — leave text as-is
            } catch {
                await MainActor.run { [weak self] in
                    self?.transcriptError = error.localizedDescription
                }
            }
            await MainActor.run { [weak self] in
                self?.isTranscribing = false
            }
        }
    }
}

// MARK: - Waveform generation

func generateWaveform(url: URL, buckets: Int = 600) async -> (duration: Double, samples: [Float]) {
    guard let file = try? AVAudioFile(forReading: url) else { return (0, []) }
    let sr = file.processingFormat.sampleRate
    let totalFrames = file.length
    let duration = Double(totalFrames) / sr
    let nch = Int(file.processingFormat.channelCount)
    let framesPerBucket = max(1, Int(totalFrames) / buckets)
    let chunkSize = AVAudioFrameCount(framesPerBucket)
    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkSize) else {
        return (duration, [])
    }
    var peaks = [Float]()
    peaks.reserveCapacity(buckets)
    file.framePosition = 0
    while file.framePosition < totalFrames {
        buf.frameLength = min(chunkSize, AVAudioFrameCount(totalFrames - file.framePosition))
        guard (try? file.read(into: buf, frameCount: buf.frameLength)) != nil, buf.frameLength > 0 else { break }
        var peak: Float = 0
        for ch in 0..<nch {
            guard let data = buf.floatChannelData?[ch] else { continue }
            var chPeak: Float = 0
            vDSP_maxmgv(data, 1, &chPeak, vDSP_Length(buf.frameLength))
            peak = max(peak, chPeak)
        }
        peaks.append(peak)
    }
    var maxPeak: Float = 0
    vDSP_maxv(peaks, 1, &maxPeak, vDSP_Length(peaks.count))
    if maxPeak > 0 {
        var s = 1 / maxPeak
        vDSP_vsmul(peaks, 1, &s, &peaks, 1, vDSP_Length(peaks.count))
    }
    return (duration, peaks)
}

func generateDetailWaveform(url: URL, start: Double, end: Double, buckets: Int = 1200) async -> [Float] {
    guard let file = try? AVAudioFile(forReading: url) else { return [] }
    let sr = file.processingFormat.sampleRate
    let nch = Int(file.processingFormat.channelCount)
    let startFrame = AVAudioFramePosition(start * sr)
    let endFrame   = min(AVAudioFramePosition(end * sr), file.length)
    let rangeFrames = max(0, endFrame - startFrame)
    guard rangeFrames > 0 else { return [] }
    let framesPerBucket = max(1, Int(rangeFrames) / buckets)
    let chunkSize = AVAudioFrameCount(framesPerBucket)
    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkSize) else { return [] }
    var peaks = [Float]()
    peaks.reserveCapacity(buckets)
    file.framePosition = startFrame
    while file.framePosition < endFrame {
        let remaining = AVAudioFrameCount(endFrame - file.framePosition)
        buf.frameLength = min(chunkSize, remaining)
        guard (try? file.read(into: buf, frameCount: buf.frameLength)) != nil, buf.frameLength > 0 else { break }
        var peak: Float = 0
        for ch in 0..<nch {
            guard let data = buf.floatChannelData?[ch] else { continue }
            var chPeak: Float = 0
            vDSP_maxmgv(data, 1, &chPeak, vDSP_Length(buf.frameLength))
            peak = max(peak, chPeak)
        }
        peaks.append(peak)
    }
    var maxPeak: Float = 0
    vDSP_maxv(peaks, 1, &maxPeak, vDSP_Length(peaks.count))
    if maxPeak > 0 { var s = 1 / maxPeak; vDSP_vsmul(peaks, 1, &s, &peaks, 1, vDSP_Length(peaks.count)) }
    return peaks
}

// MARK: - WaveformView

private struct WaveformView: View {
    let samples: [Float]
    let duration: Double
    @Binding var trimIn: Double
    @Binding var trimOut: Double
    let playhead: Double
    let chapters: [Chapter]
    let trimInOffset: Double
    var onSeek: (Double) -> Void

    var onChapterMove: ((UUID, Double) -> Void)?

    // Detail waveform (on-demand, high-resolution for zoomed view)
    let detailSamples: [Float]
    let detailRangeStart: Double
    let detailRangeEnd: Double
    var onNeedDetail: ((Double, Double) -> Void)?

    @Binding var zoom: Double
    @Binding var visibleStart: Double
    var onViewWidth: ((CGFloat) -> Void)?

    // dragHandle: nil=undecided, 0=trimIn, 1=trimOut, -1=pan/seek, -2=chapter
    @State private var dragHandle: Int? = nil
    @State private var dragChapterID: UUID? = nil
    @State private var dragStartVisibleStart: Double = 0
    @State private var dragStartX: CGFloat = 0
    @State private var lastMagnification: Double = 1.0

    // Visible window helpers
    private var visibleDuration: Double { duration / zoom }
    private func clampStart(_ s: Double) -> Double { max(0, min(s, duration - visibleDuration)) }
    private func xFor(_ t: Double, width: CGFloat) -> CGFloat {
        CGFloat((t - visibleStart) / visibleDuration) * width
    }
    private func timeFor(_ x: CGFloat, width: CGFloat) -> Double {
        max(0, min(duration, visibleStart + Double(x / width) * visibleDuration))
    }

    var body: some View {
        VStack(spacing: 0) {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let _ = onViewWidth?(w)

            Canvas { ctx, size in
                guard !samples.isEmpty, duration > 0 else { return }

                let trimInX  = xFor(trimIn,  width: w)
                let trimOutX = xFor(trimOut, width: w)
                let visEnd   = visibleStart + visibleDuration

                // 1. Dim regions outside trim
                let dimColor = Color.black.opacity(0.35)
                if trimInX > 0 {
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: min(trimInX, w), height: h)), with: .color(dimColor))
                }
                if trimOutX < w {
                    ctx.fill(Path(CGRect(x: max(0, trimOutX), y: 0, width: w - max(0, trimOutX), height: h)), with: .color(dimColor))
                }

                // 2. Waveform bars — use detail samples when zoomed in and they cover the visible range
                let useDetail = !detailSamples.isEmpty
                    && detailRangeStart <= visibleStart
                    && detailRangeEnd   >= visEnd
                let drawSamples  = useDetail ? detailSamples  : samples
                let drawOrigin   = useDetail ? detailRangeStart : 0.0
                let drawDuration = useDetail ? (detailRangeEnd - detailRangeStart) : duration

                let midY = h / 2
                // Width of one bar in pixels: seconds-per-sample × pixels-per-second
                let barW = max(1.0, w * CGFloat(zoom * drawDuration / duration) / CGFloat(drawSamples.count))
                let firstIdx = max(0, Int((visibleStart - drawOrigin) / drawDuration * Double(drawSamples.count)) - 1)
                let lastIdx  = min(drawSamples.count - 1, Int(ceil((visEnd - drawOrigin) / drawDuration * Double(drawSamples.count))) + 1)
                if firstIdx <= lastIdx {
                    for i in firstIdx...lastIdx {
                        let sampleTime = drawOrigin + drawDuration * Double(i) / Double(drawSamples.count)
                        let x = xFor(sampleTime, width: w)
                        let sample = drawSamples[i]
                        let barH = max(1, CGFloat(sample) * midY * 0.9)
                        let inTrim = sampleTime >= trimIn && sampleTime <= trimOut
                        let color: Color = inTrim ? .accentColor : Color.secondary.opacity(0.4)
                        ctx.fill(Path(CGRect(x: x, y: midY - barH, width: max(1, barW - 0.5), height: barH * 2)),
                                 with: .color(color))
                    }
                }

                // 3. Chapter markers
                var lastLabelX: CGFloat = -100
                for chapter in chapters.sorted(by: { $0.timeSeconds < $1.timeSeconds }) {
                    let inputTime = chapter.timeSeconds + trimInOffset
                    let x = xFor(inputTime, width: w)
                    guard x >= -1 && x <= w + 1 else { continue }
                    let isDragging = chapter.id == dragChapterID
                    let lineColor = isDragging ? Color.yellow : Color.purple.opacity(0.8)
                    let lineWidth: CGFloat = isDragging ? 2 : 1.5
                    ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h)) },
                               with: .color(lineColor), lineWidth: lineWidth)
                    // Hit-zone indicator: small grab handle at mid-height
                    let grabY = h * 0.5
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: grabY - 4, width: 8, height: 8)),
                             with: .color(isDragging ? Color.yellow : Color.purple.opacity(0.7)))
                    if x - lastLabelX >= 30 {
                        let label = chapter.title.isEmpty ? "●" : String(chapter.title.prefix(12))
                        ctx.draw(Text(label).font(.system(size: 9, weight: isDragging ? .bold : .regular))
                                    .foregroundStyle(isDragging ? Color.yellow : Color.purple),
                                 at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                        lastLabelX = x
                    }
                }

                // 4. Trim handles
                func drawHandle(x: CGFloat) {
                    guard x >= -9 && x <= w + 9 else { return }
                    ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h)) },
                               with: .color(.white.opacity(0.35)), lineWidth: 6)
                    ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h)) },
                               with: .color(.orange), lineWidth: 2)
                    ctx.fill(Path { p in
                        p.move(to: CGPoint(x: x - 9, y: 0)); p.addLine(to: CGPoint(x: x + 9, y: 0))
                        p.addLine(to: CGPoint(x: x, y: 14)); p.closeSubpath()
                    }, with: .color(.orange))
                    ctx.fill(Path { p in
                        p.move(to: CGPoint(x: x - 9, y: h)); p.addLine(to: CGPoint(x: x + 9, y: h))
                        p.addLine(to: CGPoint(x: x, y: h - 14)); p.closeSubpath()
                    }, with: .color(.orange))
                }
                drawHandle(x: trimInX)
                drawHandle(x: trimOutX)

                // 5. Playhead
                if playhead >= visibleStart && playhead <= visEnd {
                    let px = xFor(playhead, width: w)
                    ctx.stroke(Path { p in p.move(to: CGPoint(x: px, y: 0)); p.addLine(to: CGPoint(x: px, y: h)) },
                               with: .color(Color(red: 1.0, green: 0.78, blue: 0.0)), lineWidth: 1.5)
                }

                // 6. Zoom indicator — small pill in top-right when zoomed
                if zoom > 1.01 {
                    let label = zoom >= 10 ? String(format: "%.0f×", zoom) : String(format: "%.1f×", zoom)
                    let pill = Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.white)
                    ctx.draw(pill, at: CGPoint(x: w - 6, y: 6), anchor: .topTrailing)
                }
            }
            .contentShape(Rectangle())
            // Trim / chapter / seek drag
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let startX = value.startLocation.x
                        let curX   = value.location.x

                        // First touch: decide what we're dragging
                        if dragHandle == nil {
                            let inX  = xFor(trimIn,  width: w)
                            let outX = xFor(trimOut, width: w)
                            let dIn  = abs(startX - inX)
                            let dOut = abs(startX - outX)

                            if dIn <= 12 || dOut <= 12 {
                                // Trim handle takes priority
                                dragHandle = dIn < dOut ? 0 : 1
                            } else {
                                // Find nearest chapter marker
                                var best: (dist: CGFloat, id: UUID)? = nil
                                for ch in chapters {
                                    let cx = xFor(ch.timeSeconds + trimInOffset, width: w)
                                    let d  = abs(startX - cx)
                                    if d <= 10, best == nil || d < best!.dist {
                                        best = (d, ch.id)
                                    }
                                }
                                if let hit = best {
                                    dragHandle = -2
                                    dragChapterID = hit.id
                                } else {
                                    dragHandle = -1  // pan / tap-to-seek
                                    dragStartVisibleStart = visibleStart
                                    dragStartX = startX
                                }
                            }
                        }

                        switch dragHandle {
                        case 0:
                            trimIn = min(timeFor(curX, width: w), trimOut - 0.5)
                            onSeek(trimIn)
                        case 1:
                            trimOut = max(timeFor(curX, width: w), trimIn + 0.5)
                            onSeek(trimOut)
                        case -2:
                            // Chapter drag: curX is in original-file time; subtract trimInOffset for output time
                            if let id = dragChapterID {
                                let originalTime = timeFor(curX, width: w)
                                let outputTime   = max(0, originalTime - trimInOffset)
                                onChapterMove?(id, outputTime)
                                onSeek(originalTime)
                            }
                        default:
                            // Pan the view; tap-to-seek is handled in onEnded
                            if zoom > 1.0 {
                                let shift = -Double(curX - dragStartX) / Double(w) * visibleDuration
                                visibleStart = clampStart(dragStartVisibleStart + shift)
                            }
                        }
                    }
                    .onEnded { value in
                        if dragHandle == -1 && abs(value.translation.width) < 5 {
                            onSeek(timeFor(value.location.x, width: w))
                        }
                        dragHandle = nil; dragChapterID = nil
                    }
            )
            // Pinch to zoom, centred on the pinch midpoint
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let delta = Double(value) / lastMagnification
                        lastMagnification = Double(value)
                        let centre = visibleStart + visibleDuration / 2
                        zoom = max(1.0, min(40.0, zoom * delta))
                        visibleStart = clampStart(centre - visibleDuration / 2)
                    }
                    .onEnded { _ in lastMagnification = 1.0 }
            )
            // Double-click to reset zoom
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) { zoom = 1.0; visibleStart = 0 }
            }
            // Auto-scroll to follow playhead during playback
            .onChange(of: playhead) { ph in
                guard zoom > 1.0 else { return }
                let vEnd = visibleStart + visibleDuration
                if ph < visibleStart || ph > vEnd {
                    visibleStart = clampStart(ph - visibleDuration * 0.1)
                }
            }
            // Reset zoom/scroll when a new file is loaded (model already resets, this keeps view in sync)
            .onChange(of: duration) { _ in zoom = 1.0; visibleStart = 0 }
            // Request detail samples when zoom or scroll changes
            .onChange(of: visibleStart) { _ in requestDetail() }
            .onChange(of: zoom)         { _ in requestDetail() }
        }
        // Scrollbar — visible only when zoomed in
        if zoom > 1.01 {
            Slider(value: Binding(
                get: {
                    let scrollable = duration - visibleDuration
                    return scrollable > 0 ? visibleStart / scrollable : 0
                },
                set: { visibleStart = clampStart($0 * (duration - visibleDuration)) }
            ))
            .controlSize(.mini)
            .padding(.horizontal, 4)
        }
        } // end VStack
    }

    private func requestDetail() {
        guard zoom > 2.0, duration > 0 else { return }
        let buffer   = visibleDuration * 0.25
        let reqStart = max(0, visibleStart - buffer)
        let reqEnd   = min(duration, visibleStart + visibleDuration + buffer)
        onNeedDetail?(reqStart, reqEnd)
    }
}

// MARK: - UI helpers

private enum PanelTab { case info, chapters }

private func formatPlaybackTime(_ seconds: Double) -> String {
    let t = max(0, seconds)
    let h = Int(t) / 3600
    let m = (Int(t) % 3600) / 60
    let s = Int(t) % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var model = ProcessingModel()
    @State private var isTargeted = false
    @State private var panelTab: PanelTab = .info
    @State private var isArtworkTargeted = false
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var clickMonitor: Any?
    @State private var transcriptWindowController: NSWindowController?

    private func openTranscriptWindow() {
        if let wc = transcriptWindowController, wc.window?.isVisible == true {
            wc.window?.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: TranscriptView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Transcript"
        window.setContentSize(NSSize(width: 500, height: 420))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        let wc = NSWindowController(window: window)
        transcriptWindowController = wc
        wc.showWindow(nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    headerView
                        .padding(.bottom, 20)

                    dropZoneView
                        .padding(.bottom, 16)

                    optionsView
                        .padding(.bottom, 16)

                    if !model.logs.isEmpty {
                        logView
                            .padding(.bottom, 12)
                    }

                    if model.isDone, let url = model.outputURL {
                        actionView(url: url)
                    }
                }
                .padding(28)
                .frame(width: 480)

                Divider()
                chaptersPanel
            }

            if model.inputURL != nil {
                Divider()
                waveformPanel
            }
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 49 else { return event }  // 49 = space bar
                let responder = NSApp.keyWindow?.firstResponder
                let isTyping = responder is NSTextView || responder is NSTextField
                if !isTyping {
                    model.togglePlayback()
                    return nil  // consume event
                }
                return event
            }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                if let window = NSApp.keyWindow,
                   let hit = window.contentView?.hitTest(event.locationInWindow) {
                    let isTextField = hit is NSTextView || hit is NSTextField
                    if !isTextField { window.makeFirstResponder(nil) }
                }
                return event  // never consume — just side-effect
            }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard model.inputURL != nil else { return event }
                model.waveformScroll(dx: Double(event.scrollingDeltaX),
                                     dy: Double(event.scrollingDeltaY))
                return nil  // consume — waveform is the only scrollable element
            }
        }
        .onDisappear {
            if let m = keyMonitor    { NSEvent.removeMonitor(m); keyMonitor = nil }
            if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
            if let m = clickMonitor  { NSEvent.removeMonitor(m); clickMonitor = nil }
        }
    }

    private var headerView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                if let img = NSImage(named: "Wheat") {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                }
                Text("DeChaff")
                    .font(.system(size: 26, weight: .semibold))
            }
            Text("Prepares sermon recordings for podcast — cleans audio, normalises loudness, encodes to MP3, and adds chapter markers with ID3 tags.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Developed for City On a Hill AV team")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    private var dropZoneView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: isTargeted ? [] : [8, 5])
                )
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isTargeted
                              ? Color.accentColor.opacity(0.07)
                              : Color.secondary.opacity(0.03))
                )
                .animation(.easeInOut(duration: 0.15), value: isTargeted)

            if model.isProcessing {
                processingOverlay
            } else if model.isDone {
                doneOverlay
            } else {
                idleOverlay
            }
        }
        .frame(height: 210)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            loadDroppedFile(from: providers)
        }
    }

    private var processingOverlay: some View {
        VStack(spacing: 16) {
            Text("Processing…")
                .font(.headline)
                .foregroundStyle(.secondary)
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .frame(width: 300)
            Text("\(Int(model.progress * 100))%")
                .font(.system(.subheadline, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var doneOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Done!")
                .font(.headline)
            Text("Drop another file to process again")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var idleOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            Text("Drop audio file here")
                .font(.headline)
                .foregroundStyle(isTargeted ? Color.accentColor : Color.primary)
            Text("WAV · MP3 · M4A · AIFF · FLAC · CAF")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
                .frame(width: 48)
                .padding(.vertical, 2)
            Button("Choose File…") {
                openFilePicker()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Voice Isolation",     isOn: $model.doIsolation)
            Toggle("Dynamic Compression", isOn: $model.doCompression)
            HStack(spacing: 10) {
                Toggle("Loudness Normalization", isOn: $model.doNormalization)
                if model.doNormalization {
                    Spacer()
                    Text(String(format: "%.0f LUFS", model.targetLUFS))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Slider(value: $model.targetLUFS, in: -32 ... -6, step: 0.5)
                        .frame(width: 100)
                        .controlSize(.small)
                }
            }
            Toggle("Mono output", isOn: $model.monoOutput)
            HStack(spacing: 10) {
                Toggle("Shorten long silences", isOn: $model.shortenSilences)
                if model.shortenSilences {
                    Spacer()
                    Slider(value: $model.maxSilenceDuration, in: 0.3...3.0, step: 0.1)
                        .frame(width: 90)
                        .controlSize(.small)
                    Text(String(format: "%.1fs max", model.maxSilenceDuration))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                }
            }

            Toggle("Transcribe audio (on-device)", isOn: $model.doTranscription)

            Divider()

            HStack(spacing: 12) {
                Text("MP3 bitrate")
                    .font(.callout)
                Spacer()
                Picker("", selection: $model.mp3Bitrate) {
                    ForEach([64, 96, 128, 192, 256], id: \.self) { br in
                        Text("\(br) kbps").tag(br)
                    }
                }
                .frame(width: 90)
                .controlSize(.small)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(model.isProcessing)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.logs.enumerated()), id: \.offset) { index, message in
                        Text(message)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 90)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .onChange(of: model.logs.count) { newCount in
                if newCount > 0 {
                    withAnimation { proxy.scrollTo(newCount - 1) }
                }
            }
        }
    }

    private func actionView(url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.checkmark")
                .foregroundStyle(.green)
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Waveform panel

    private var waveformPanel: some View {
        VStack(spacing: 0) {
            Group {
                if model.isLoadingWaveform {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Loading waveform…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.waveformSamples.isEmpty {
                    Color.clear
                } else {
                    WaveformView(
                        samples: model.waveformSamples,
                        duration: model.inputDuration,
                        trimIn: $model.trimInSeconds,
                        trimOut: $model.trimOutSeconds,
                        playhead: model.playheadSeconds,
                        chapters: model.chapters,
                        trimInOffset: model.trimInSeconds,
                        onSeek: { model.seekPlayback(to: $0) },
                        onChapterMove: { id, newOutputTime in
                            if let idx = model.chapters.firstIndex(where: { $0.id == id }) {
                                model.chapters[idx].timeSeconds = newOutputTime
                            }
                        },
                        detailSamples: model.detailSamples,
                        detailRangeStart: model.detailRangeStart,
                        detailRangeEnd: model.detailRangeEnd,
                        onNeedDetail: { s, e in model.requestDetailWaveform(start: s, end: e) },
                        zoom: $model.waveformZoom,
                        visibleStart: $model.waveformVisibleStart,
                        onViewWidth: { model.waveformViewWidth = $0 }
                    )
                    .padding(.horizontal, 16)
                }
            }
            .frame(height: 110)

            HStack(spacing: 8) {
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(model.waveformSamples.isEmpty)

                Text(formatPlaybackTime(model.playheadSeconds))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 52, alignment: .leading)

                Spacer()

                Button("Set In") { model.trimInSeconds = min(model.playheadSeconds, model.trimOutSeconds - 0.5) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.waveformSamples.isEmpty)
                    .help("Set trim-in to current playhead position")

                Text("\(formatPlaybackTime(model.trimInSeconds)) – \(formatPlaybackTime(model.trimOutSeconds))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button("Set Out") { model.trimOutSeconds = max(model.playheadSeconds, model.trimInSeconds + 0.5) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.waveformSamples.isEmpty)
                    .help("Set trim-out to current playhead position")

                Spacer()

                if !model.isProcessing {
                    Button("Process →") {
                        model.startProcessing()
                        if model.doTranscription {
                            let trimIn = model.trimInSeconds
                            model.startTranscription(trimIn: trimIn)
                            openTranscriptWindow()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.isLoadingWaveform)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(height: 150)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Chapters panel

    private var chaptersPanel: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 8) {
                Picker("", selection: $panelTab) {
                    Text("Info").tag(PanelTab.info)
                    Text("Chapters").tag(PanelTab.chapters)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if panelTab == .chapters {
                    Button {
                        withAnimation {
                            let nextTime = model.chapters.last.map { $0.timeSeconds + 60 } ?? 0
                            let idx = model.chapters.count
                            let title: String
                            switch idx {
                            case 0: title = model.tagBibleReading.isEmpty ? "Bible Reading:" : "Bible Reading: \(model.tagBibleReading)"
                            case 1: title = model.tagSermonTitle.isEmpty   ? "Sermon:"        : "Sermon: \(model.tagSermonTitle)"
                            default: title = "Chapter \(idx + 1)"
                            }
                            model.chapters.append(Chapter(timeSeconds: nextTime, title: title))
                        }
                    } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add chapter")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Tab content
            switch panelTab {
            case .info:     infoTabView
            case .chapters: chaptersTabView
            }

        }
        .frame(width: 260)
    }

    private var infoTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                artworkDropZone
                tagField("Sermon Title",  $model.tagSermonTitle)
                tagField("Bible Reading", $model.tagBibleReading)
                tagField("Preacher",      $model.tagPreacher)
                tagField("Series",        $model.tagSeries)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Date")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    DatePicker("", selection: $model.tagDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
    }

    private var chaptersTabView: some View {
        Group {
            if model.chapters.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No chapters yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Tap + to add chapter markers")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.chapters) { chapter in
                            ChapterRow(chapter: chapterBinding(for: chapter)) {
                                withAnimation { model.chapters.removeAll { $0.id == chapter.id } }
                            }
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tagField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
    }

    private var artworkDropZone: some View {
        ZStack {
            if let data = model.tagArtwork, let nsImg = NSImage(data: data) {
                Image(nsImage: nsImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack {
                    HStack {
                        Spacer()
                        Button { model.tagArtwork = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                        }
                        .buttonStyle(.borderless)
                        .padding(6)
                    }
                    Spacer()
                }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isArtworkTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: isArtworkTargeted ? 2 : 1,
                                           dash: isArtworkTargeted ? [] : [5, 3]))
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(isArtworkTargeted
                              ? Color.accentColor.opacity(0.07)
                              : Color.secondary.opacity(0.04)))
                    .animation(.easeInOut(duration: 0.15), value: isArtworkTargeted)
                VStack(spacing: 6) {
                    Image(systemName: isArtworkTargeted ? "photo.fill" : "photo.badge.plus")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(isArtworkTargeted ? Color.accentColor : Color.secondary)
                    Text("Drop image or click to browse")
                        .font(.caption2)
                        .foregroundStyle(isArtworkTargeted ? Color.accentColor : Color.secondary)
                        .multilineTextAlignment(.center)
                }
                .allowsHitTesting(false)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture { if model.tagArtwork == nil { openArtworkPicker() } }
        .onDrop(of: [UTType.fileURL], isTargeted: $isArtworkTargeted) { providers in
            loadArtwork(from: providers)
        }
    }

    private func openArtworkPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose album artwork"
        if panel.runModal() == .OK, let url = panel.url {
            DispatchQueue.main.async { self.loadArtworkFromURL(url) }
        }
    }

    private func loadArtwork(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            guard let url else { return }
            DispatchQueue.main.async { self.loadArtworkFromURL(url) }
        }
        return true
    }

    private func loadArtworkFromURL(_ url: URL) {
        guard let nsImage = NSImage(contentsOf: url),
              let tiff   = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg   = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return }
        model.tagArtwork = jpeg
    }

    private func chapterBinding(for chapter: Chapter) -> Binding<Chapter> {
        guard let idx = model.chapters.firstIndex(where: { $0.id == chapter.id }) else {
            fatalError("Chapter not found in model")
        }
        return $model.chapters[idx]
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an audio file to process"
        if panel.runModal() == .OK, let url = panel.url {
            DispatchQueue.main.async { self.model.loadFile(url: url) }
        }
    }

    private func loadDroppedFile(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let u = item as? URL {
                url = u
            }
            guard let url = url else { return }
            DispatchQueue.main.async { self.model.loadFile(url: url) }
        }
        return true
    }
}

// MARK: - Transcript Window

struct TranscriptView: View {
    @ObservedObject var model: ProcessingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcript")
                    .font(.headline)
                Spacer()
                if model.isTranscribing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 4)
                    Text("Transcribing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !model.transcriptText.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.transcriptText, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding()

            Divider()

            if let error = model.transcriptError {
                Text(error)
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if model.transcriptText.isEmpty {
                Text(model.isTranscribing ? "Waiting for first results…" : "No transcript yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(model.transcriptText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}

#Preview {
    ContentView()
}

private struct ChapterRow: View {
    @Binding var chapter: Chapter
    var onDelete: () -> Void

    @State private var timeText = ""
    @FocusState private var timeFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("0:00", text: $timeText)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 56)
                .multilineTextAlignment(.center)
                .focused($timeFocused)
                .onAppear { timeText = formatChapterTime(chapter.timeSeconds) }
                .onChange(of: chapter.timeSeconds) { _ in
                    if !timeFocused { timeText = formatChapterTime(chapter.timeSeconds) }
                }
                .onSubmit { commitTime() }
                .onChange(of: timeFocused) { focused in
                    if !focused { commitTime() }
                }

            TextField("Chapter title", text: $chapter.title)
                .font(.caption)
                .textFieldStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red.opacity(0.6))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func commitTime() {
        if let secs = parseChapterTime(timeText) {
            chapter.timeSeconds = secs
            timeText = formatChapterTime(secs)
        } else {
            timeText = formatChapterTime(chapter.timeSeconds)
        }
    }
}

private func formatChapterTime(_ seconds: Double) -> String {
    let t = max(0, Int(seconds))
    let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

private func parseChapterTime(_ text: String) -> Double? {
    let parts = text.trimmingCharacters(in: .whitespaces)
                    .split(separator: ":", omittingEmptySubsequences: false)
                    .compactMap { Int($0) }
    switch parts.count {
    case 1: return parts[0] >= 0 ? Double(parts[0]) : nil
    case 2: guard parts[0] >= 0, (0..<60).contains(parts[1]) else { return nil }
            return Double(parts[0] * 60 + parts[1])
    case 3: guard parts[0] >= 0, (0..<60).contains(parts[1]), (0..<60).contains(parts[2]) else { return nil }
            return Double(parts[0] * 3600 + parts[1] * 60 + parts[2])
    default: return nil
    }
}
