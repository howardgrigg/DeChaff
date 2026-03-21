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
    @Published var mp3Bitrate: Int = 128
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
        didSet { UserDefaults.standard.set(tagArtwork, forKey: "dechaff.artwork") }
    }

    // File load state
    @Published var inputURL: URL? = nil
    @Published var inputDuration: Double = 0
    @Published var waveformSamples: [Float] = []
    @Published var isLoadingWaveform = false

    // Trim
    @Published var trimInSeconds: Double = 0
    @Published var trimOutSeconds: Double = 0

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

    // Waveform viewport
    @Published var waveformZoom: Double = 1.0
    @Published var waveformVisibleStart: Double = 0.0
    var waveformViewWidth: CGFloat = 700

    init() {
        tagSeries   = UserDefaults.standard.string(forKey: "dechaff.series") ?? ""
        tagPreacher = UserDefaults.standard.string(forKey: "dechaff.preacher") ?? ""
        tagArtwork  = UserDefaults.standard.data(forKey: "dechaff.artwork")
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

    // MARK: - Playback

    func togglePlayback() { isPlaying ? pausePlayback() : playFrom(playheadSeconds) }

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

    func pausePlayback() { audioPlayer?.pause(); isPlaying = false; playbackTimer?.invalidate() }

    func stopPlayback() {
        audioPlayer?.stop(); audioPlayer = nil
        isPlaying = false; playbackTimer?.invalidate(); playheadSeconds = 0
    }

    func seekPlayback(to time: Double) {
        playheadSeconds = time
        audioPlayer?.currentTime = time
    }

    func waveformScroll(dx: Double, dy: Double) {
        guard inputDuration > 0 else { return }
        let visibleDuration = inputDuration / waveformZoom
        if abs(dx) >= abs(dy) {
            guard waveformZoom > 1.0 else { return }
            let shift = dx / Double(waveformViewWidth) * visibleDuration
            waveformVisibleStart = max(0, min(waveformVisibleStart + shift, inputDuration - visibleDuration))
        } else {
            let centre = waveformVisibleStart + visibleDuration / 2
            waveformZoom = max(1.0, min(40.0, waveformZoom * (1.0 + dy * 0.025)))
            let newVD = inputDuration / waveformZoom
            waveformVisibleStart = max(0, min(centre - newVD / 2, inputDuration - newVD))
        }
    }

    func requestDetailWaveform(start: Double, end: Double) {
        detailLoadTask?.cancel()
        let url = inputURL
        detailLoadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self, let url else { return }
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            let samples = await generateDetailWaveform(url: url, start: start, end: end)
            await MainActor.run {
                self.detailSamples = samples
                self.detailRangeStart = start
                self.detailRangeEnd = end
            }
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
    var peaks = [Float](); peaks.reserveCapacity(buckets)
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
    if maxPeak > 0 { var s = 1 / maxPeak; vDSP_vsmul(peaks, 1, &s, &peaks, 1, vDSP_Length(peaks.count)) }
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
    var peaks = [Float](); peaks.reserveCapacity(buckets)
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

struct WaveformView: View {
    let samples: [Float]
    let duration: Double
    @Binding var trimIn: Double
    @Binding var trimOut: Double
    let playhead: Double
    let chapters: [Chapter]
    let trimInOffset: Double
    var onSeek: (Double) -> Void
    var onChapterMove: ((UUID, Double) -> Void)?
    let detailSamples: [Float]
    let detailRangeStart: Double
    let detailRangeEnd: Double
    var onNeedDetail: ((Double, Double) -> Void)?
    @Binding var zoom: Double
    @Binding var visibleStart: Double
    var onViewWidth: ((CGFloat) -> Void)?

    @State private var dragHandle: Int? = nil
    @State private var dragChapterID: UUID? = nil
    @State private var dragStartVisibleStart: Double = 0
    @State private var dragStartX: CGFloat = 0
    @State private var lastMagnification: Double = 1.0

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

                Canvas { ctx, _ in
                    guard !samples.isEmpty, duration > 0 else { return }

                    let trimInX  = xFor(trimIn,  width: w)
                    let trimOutX = xFor(trimOut, width: w)
                    let visEnd   = visibleStart + visibleDuration

                    // Dim outside trim
                    let dimColor = Color.black.opacity(0.35)
                    if trimInX > 0 { ctx.fill(Path(CGRect(x: 0, y: 0, width: min(trimInX, w), height: h)), with: .color(dimColor)) }
                    if trimOutX < w { ctx.fill(Path(CGRect(x: max(0, trimOutX), y: 0, width: w - max(0, trimOutX), height: h)), with: .color(dimColor)) }

                    // Waveform bars
                    let useDetail = !detailSamples.isEmpty && detailRangeStart <= visibleStart && detailRangeEnd >= visEnd
                    let drawSamples  = useDetail ? detailSamples  : samples
                    let drawOrigin   = useDetail ? detailRangeStart : 0.0
                    let drawDuration = useDetail ? (detailRangeEnd - detailRangeStart) : duration
                    let midY = h / 2
                    let barW = max(1.0, w * CGFloat(zoom * drawDuration / duration) / CGFloat(drawSamples.count))
                    let firstIdx = max(0, Int((visibleStart - drawOrigin) / drawDuration * Double(drawSamples.count)) - 1)
                    let lastIdx  = min(drawSamples.count - 1, Int(ceil((visEnd - drawOrigin) / drawDuration * Double(drawSamples.count))) + 1)
                    if firstIdx <= lastIdx {
                        for i in firstIdx...lastIdx {
                            let sampleTime = drawOrigin + drawDuration * Double(i) / Double(drawSamples.count)
                            let x = xFor(sampleTime, width: w)
                            let barH = max(1, CGFloat(drawSamples[i]) * midY * 0.9)
                            let inTrim = sampleTime >= trimIn && sampleTime <= trimOut
                            ctx.fill(Path(CGRect(x: x, y: midY - barH, width: max(1, barW - 0.5), height: barH * 2)),
                                     with: .color(inTrim ? .accentColor : Color.secondary.opacity(0.4)))
                        }
                    }

                    // Chapter markers
                    var lastLabelX: CGFloat = -100
                    for chapter in chapters.sorted(by: { $0.timeSeconds < $1.timeSeconds }) {
                        let inputTime = chapter.timeSeconds + trimInOffset
                        let x = xFor(inputTime, width: w)
                        guard x >= -1 && x <= w + 1 else { continue }
                        let isDragging = chapter.id == dragChapterID
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h)) },
                                   with: .color(isDragging ? Color.yellow : Color.purple.opacity(0.8)),
                                   lineWidth: isDragging ? 2 : 1.5)
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: h * 0.5 - 4, width: 8, height: 8)),
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

                    // Playhead
                    if playhead >= visibleStart && playhead <= visEnd {
                        let px = xFor(playhead, width: w)
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: px, y: 0)); p.addLine(to: CGPoint(x: px, y: h)) },
                                   with: .color(Color(red: 1.0, green: 0.78, blue: 0.0)), lineWidth: 1.5)
                    }

                    // Zoom indicator
                    if zoom > 1.01 {
                        let label = zoom >= 10 ? String(format: "%.0f×", zoom) : String(format: "%.1f×", zoom)
                        ctx.draw(Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.white),
                                 at: CGPoint(x: w - 6, y: 6), anchor: .topTrailing)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            let startX = value.startLocation.x
                            let curX   = value.location.x
                            if dragHandle == nil {
                                let inX  = xFor(trimIn,  width: w)
                                let outX = xFor(trimOut, width: w)
                                let dIn  = abs(startX - inX)
                                let dOut = abs(startX - outX)
                                if dIn <= 12 || dOut <= 12 {
                                    dragHandle = dIn < dOut ? 0 : 1
                                } else {
                                    var best: (dist: CGFloat, id: UUID)? = nil
                                    for ch in chapters {
                                        let cx = xFor(ch.timeSeconds + trimInOffset, width: w)
                                        let d  = abs(startX - cx)
                                        if d <= 10, best == nil || d < best!.dist { best = (d, ch.id) }
                                    }
                                    if let hit = best {
                                        dragHandle = -2; dragChapterID = hit.id
                                    } else {
                                        dragHandle = -1
                                        dragStartVisibleStart = visibleStart; dragStartX = startX
                                    }
                                }
                            }
                            switch dragHandle {
                            case 0: trimIn = min(timeFor(curX, width: w), trimOut - 0.5); onSeek(trimIn)
                            case 1: trimOut = max(timeFor(curX, width: w), trimIn + 0.5); onSeek(trimOut)
                            case -2:
                                if let id = dragChapterID {
                                    let originalTime = timeFor(curX, width: w)
                                    onChapterMove?(id, max(0, originalTime - trimInOffset))
                                    onSeek(originalTime)
                                }
                            default:
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
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.2)) { zoom = 1.0; visibleStart = 0 }
                }
                .onChange(of: playhead) { ph in
                    guard zoom > 1.0 else { return }
                    let vEnd = visibleStart + visibleDuration
                    if ph < visibleStart || ph > vEnd { visibleStart = clampStart(ph - visibleDuration * 0.1) }
                }
                .onChange(of: duration) { _ in zoom = 1.0; visibleStart = 0 }
                .onChange(of: visibleStart) { _ in requestDetail() }
                .onChange(of: zoom)         { _ in requestDetail() }
            }
            if zoom > 1.01 {
                Slider(value: Binding(
                    get: { let s = duration - visibleDuration; return s > 0 ? visibleStart / s : 0 },
                    set: { visibleStart = clampStart($0 * (duration - visibleDuration)) }
                ))
                .controlSize(.mini)
                .padding(.horizontal, 4)
            }
        }
    }

    private func requestDetail() {
        guard zoom > 2.0, duration > 0 else { return }
        let buffer   = visibleDuration * 0.25
        let reqStart = max(0, visibleStart - buffer)
        let reqEnd   = min(duration, visibleStart + visibleDuration + buffer)
        onNeedDetail?(reqStart, reqEnd)
    }
}

// MARK: - Helpers

func formatPlaybackTime(_ seconds: Double) -> String {
    let t = max(0, seconds)
    let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject var model = ProcessingModel()
    @State var currentStep = 0
    @State var isTargeted = false
    @State var isArtworkTargeted = false
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var clickMonitor: Any?
    @State private var showLog = false

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
        .onAppear { setupMonitors() }
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
            } else {
                WaveformView(
                    samples: model.waveformSamples,
                    duration: model.inputDuration,
                    trimIn: $model.trimInSeconds,
                    trimOut: $model.trimOutSeconds,
                    playhead: model.playheadSeconds,
                    chapters: showChapters ? model.chapters : [],
                    trimInOffset: model.trimInSeconds,
                    onSeek: { model.seekPlayback(to: $0) },
                    onChapterMove: showChapters ? { id, newTime in
                        if let idx = model.chapters.firstIndex(where: { $0.id == id }) {
                            model.chapters[idx].timeSeconds = newTime
                        }
                    } : nil,
                    detailSamples: model.detailSamples,
                    detailRangeStart: model.detailRangeStart,
                    detailRangeEnd: model.detailRangeEnd,
                    onNeedDetail: { s, e in model.requestDetailWaveform(start: s, end: e) },
                    zoom: $model.waveformZoom,
                    visibleStart: $model.waveformVisibleStart,
                    onViewWidth: { model.waveformViewWidth = $0 }
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
                    model.trimInSeconds = min(model.playheadSeconds, model.trimOutSeconds - 0.5)
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.waveformSamples.isEmpty)

                Text("\(formatPlaybackTime(model.trimInSeconds)) – \(formatPlaybackTime(model.trimOutSeconds))")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)

                Button("Set Out") {
                    model.trimOutSeconds = max(model.playheadSeconds, model.trimInSeconds + 0.5)
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.waveformSamples.isEmpty)
            }
        }
    }

    var playPauseButton: some View {
        Button { model.togglePlayback() } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .disabled(model.waveformSamples.isEmpty)
    }

    var playheadTimeLabel: some View {
        Text(formatPlaybackTime(model.playheadSeconds))
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
            guard event.keyCode == 49 else { return event }
            let responder = NSApp.keyWindow?.firstResponder
            let isTyping = responder is NSTextView || responder is NSTextField
            if !isTyping && (self.currentStep == 1 || self.currentStep == 3) {
                self.model.togglePlayback(); return nil
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
            self.model.waveformScroll(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY))
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
