import AVFoundation
import SoundAnalysis

extension VoiceIsolationProcessor {

    // MARK: - Music detection (for skipping voice isolation on music)

    /// Detects music segments so the isolation AU can be bypassed there.
    /// Runs on the original (untrimmed) `audioFile`, but reports segment times
    /// relative to the *trimmed* timeline (0 = first kept sample) — the same
    /// frame-position math as `renderLoop`/`copyPass` — so callers can compare
    /// directly against `totalFrames` inside the AU render loop.
    func detectMusicSegments(audioFile: AVAudioFile, options: ProcessingOptions,
                             progressStart: Double, progressEnd: Double) -> [MusicSegment]? {
        let minMusicDuration = 3.0
        let musicConfidenceThreshold = 0.35

        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            if !request.knownClassifications.contains("music") ||
               !request.knownClassifications.contains("speech") {
                logHandler("⚠️ Music detection: classifier missing expected labels — skipping")
                return nil
            }

            let format = audioFile.processingFormat
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let collector = MusicClassificationCollector()
            try analyzer.add(request, withObserver: collector)

            let sr = format.sampleRate
            let inFrame  = AVAudioFramePosition(options.trimInSeconds * sr)
            let outFrame = min(options.trimOutSeconds > 0
                ? AVAudioFramePosition(options.trimOutSeconds * sr)
                : audioFile.length, audioFile.length)
            let trimLength = AVAudioFrameCount(max(0, outFrame - inFrame))
            guard trimLength > 0 else { return [] }

            let chunkSize: AVAudioFrameCount = 4096
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else { return nil }

            audioFile.framePosition = inFrame
            var readFrames: AVAudioFrameCount = 0
            // Frame position handed to the analyzer, relative to the trimmed start —
            // this is what makes the observer's timeRange values trim-relative too.
            var relativeFramePosition: AVAudioFramePosition = 0

            while readFrames < trimLength {
                if isCancelled { logHandler("⏹ Cancelled"); return nil }
                let toRead = min(chunkSize, trimLength - readFrames)
                buf.frameLength = toRead
                try audioFile.read(into: buf, frameCount: toRead)
                guard buf.frameLength > 0 else { break }

                analyzer.analyze(buf, atAudioFramePosition: relativeFramePosition)

                relativeFramePosition += AVAudioFramePosition(buf.frameLength)
                readFrames += buf.frameLength
                progressHandler(progressStart + (progressEnd - progressStart) * Double(readFrames) / Double(trimLength))
            }
            analyzer.completeAnalysis()

            // Merge windows classified as music into contiguous spans.
            var spans: [(start: Double, end: Double)] = []
            for window in collector.windows where window.isMusic(threshold: musicConfidenceThreshold) {
                if let last = spans.last, window.start <= last.end {
                    spans[spans.count - 1].end = max(last.end, window.end)
                } else {
                    spans.append((start: window.start, end: window.end))
                }
            }

            // Bridge short gaps — a couple of quiet seconds mid-song (a vocal-only
            // passage, an instrumental lull) commonly reads as "not music" for a
            // window or two. Without bridging, isolation would flip on/off repeatedly
            // during a single song instead of staying off for the whole thing.
            let maxGapToBridge = 2.0
            var bridged: [(start: Double, end: Double)] = []
            for span in spans {
                if let last = bridged.last, span.start - last.end <= maxGapToBridge {
                    bridged[bridged.count - 1].end = span.end
                } else {
                    bridged.append(span)
                }
            }

            let segments = bridged
                .filter { $0.end - $0.start >= minMusicDuration }
                .map { MusicSegment(startSeconds: $0.start, endSeconds: $0.end) }

            if segments.isEmpty {
                logHandler("🎵 No music segments detected")
            } else {
                let total = segments.reduce(0.0) { $0 + ($1.endSeconds - $1.startSeconds) }
                logHandler(String(format: "🎵 Detected %d music segment%@ (%.0fs) — isolation will be skipped there",
                                  segments.count, segments.count == 1 ? "" : "s", total))
            }
            return segments
        } catch {
            logHandler("⚠️ Music detection failed: \(error.localizedDescription) — skipping")
            return nil
        }
    }
}

// MARK: - Classification collector

private struct ClassifiedWindow {
    let start: Double
    let end: Double
    let musicConfidence: Double
    let speechConfidence: Double

    func isMusic(threshold: Double) -> Bool {
        // Flag as music whenever music confidence clears the threshold, even if
        // speech is also present — e.g. the speaker talking over background music,
        // which we still want isolation to skip.
        musicConfidence >= threshold
    }
}

/// Synchronously accumulates classification results as `analyze(_:atAudioFramePosition:)`
/// delivers them — `SNAudioStreamAnalyzer` documents that call as blocking to indicate
/// backpressure, so results for completed windows are available before it returns.
private final class MusicClassificationCollector: NSObject, SNResultsObserving {
    var windows: [ClassifiedWindow] = []

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let music  = result.classification(forIdentifier: "music")?.confidence  ?? 0
        let speech = result.classification(forIdentifier: "speech")?.confidence ?? 0
        windows.append(ClassifiedWindow(
            start: result.timeRange.start.seconds,
            end: (result.timeRange.start + result.timeRange.duration).seconds,
            musicConfidence: music, speechConfidence: speech
        ))
    }
}
