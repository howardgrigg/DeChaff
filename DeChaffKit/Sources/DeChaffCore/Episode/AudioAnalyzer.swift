import AVFoundation

/// A quick survey of a source recording, used to plan trims before processing.
public struct AudioAnalysis: Sendable {
    public let duration: Double
    public let sampleRate: Double
    public let channels: Int
    /// Integrated loudness (EBU R128) of the whole file; nil if it couldn't be measured.
    public let integratedLUFS: Double?
    /// Spans below −40 dBFS lasting at least the requested minimum.
    public let silences: [SilenceSegment]
    /// Stretches classified as music (worship, intros) — likely trim candidates.
    public let musicSegments: [MusicSegment]
}

/// Measures a file with the same detectors the processing pipeline uses.
/// `analyze` blocks, so call it off the main thread; `cancel()` may be called from any thread.
public final class AudioAnalyzer: @unchecked Sendable {
    private let processor = VoiceIsolationProcessor()

    public init() {}

    public func cancel() { processor.cancel() }

    public func analyze(url: URL, detectMusic: Bool = true, minSilence: Double = 2.0,
                        progress: @escaping (Double) -> Void = { _ in },
                        log: @escaping (String) -> Void = { _ in }) -> AudioAnalysis? {
        processor.progressHandler = progress
        processor.logHandler = log
        guard let file = processor.loadAudioFile(path: url.path) else { return nil }
        let format = file.fileFormat
        let duration = Double(file.length) / format.sampleRate

        // Untrimmed options — every detector reads the whole file.
        let whole = ProcessingOptions()
        let musicEnd = detectMusic ? 0.5 : 0.0
        let music = detectMusic
            ? processor.detectMusicSegments(audioFile: file, options: whole, progressStart: 0, progressEnd: musicEnd) ?? []
            : []
        if processor.isCancelled { return nil }

        let lufs = processor.measureLUFS(path: url.path, options: whole,
                                         progressStart: musicEnd, progressEnd: musicEnd + (1 - musicEnd) * 0.6)
        if processor.isCancelled { return nil }

        let silences = (processor.detectSilences(inputPath: url.path, maxKept: 0) ?? [])
            .filter { $0.endSeconds - $0.startSeconds >= minSilence }
        if processor.isCancelled { return nil }
        progress(1.0)

        return AudioAnalysis(duration: duration, sampleRate: format.sampleRate,
                             channels: Int(format.channelCount), integratedLUFS: lufs,
                             silences: silences, musicSegments: music)
    }
}
