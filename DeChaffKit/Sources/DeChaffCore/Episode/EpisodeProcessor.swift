import Foundation

/// Everything needed to turn a source recording into a finished episode.
public struct EpisodeRequest: Sendable {
    public var inputURL: URL
    public var outputURL: URL
    /// Processing settings, including the trim range on the source timeline.
    public var options: ProcessingOptions
    public var metadata: ID3Metadata
    /// Chapter times on the trimmed timeline (0 = trim-in), before silence shortening.
    public var chapters: [Chapter]

    public init(inputURL: URL, outputURL: URL, options: ProcessingOptions,
                metadata: ID3Metadata, chapters: [Chapter]) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.options = options
        self.metadata = metadata
        self.chapters = chapters
    }
}

public struct EpisodeResult: Sendable {
    public let outputURL: URL
    /// Chapters as written to the file — shifted to account for shortened silences.
    public let chapters: [Chapter]
    public let silenceSegments: [SilenceSegment]
}

public enum EpisodeOutcome: Sendable {
    case finished(EpisodeResult)
    case failed
    /// Cancelled via `cancel()`; any partial output has been removed.
    case cancelled
}

/// Runs the whole pipeline for one episode: audio passes, encoding, chapter remapping
/// and ID3 tagging. `run` blocks until done, so call it off the main thread;
/// `cancel()` may be called from any thread.
public final class EpisodeProcessor: @unchecked Sendable {
    private let processor = VoiceIsolationProcessor()

    /// - Parameter lamePath: LAME encoder to use; nil = the `lame` resource in the main bundle.
    public init(lamePath: String? = nil) {
        processor.lamePath = lamePath
    }

    public func cancel() { processor.cancel() }
    public var isCancelled: Bool { processor.isCancelled }

    public func run(_ request: EpisodeRequest,
                    progress: @escaping (Double) -> Void,
                    log: @escaping (String) -> Void) -> EpisodeOutcome {
        let outputPath = request.outputURL.path
        let success = processor.process(
            inputPath: request.inputURL.path,
            outputPath: outputPath,
            options: request.options,
            progressHandler: progress,
            logHandler: log
        )
        guard success else {
            if processor.isCancelled {
                try? FileManager.default.removeItem(atPath: outputPath)
                return .cancelled
            }
            return .failed
        }

        let segments = processor.detectedSilenceSegments
        var chapters = request.chapters
        if !segments.isEmpty {
            chapters = chapters.map { c in
                var c2 = c; c2.timeSeconds = remapChapterTime(c.timeSeconds, using: segments); return c2
            }
        }

        if request.options.outputFormat == .mp3 {
            processor.writeTags(chapters: chapters, metadata: request.metadata, to: outputPath, logHandler: log)
        }

        return .finished(EpisodeResult(outputURL: request.outputURL, chapters: chapters,
                                       silenceSegments: segments))
    }
}
