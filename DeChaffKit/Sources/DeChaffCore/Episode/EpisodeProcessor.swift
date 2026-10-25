import Foundation

/// Everything needed to turn a source recording into a finished episode.
public struct EpisodeRequest: Sendable {
    public var inputURL: URL
    public var outputURL: URL
    /// Processing settings, including the trim range on the source timeline.
    public var options: ProcessingOptions
    public var metadata: ID3Metadata
    /// Chapter times on the source timeline (S). They are mapped through the trim and
    /// any excluded ranges, then through shortened silences, when the file is tagged.
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
        // Chapters are stored in source time, so they always need the S→K map
        // (trim + exclusions); silence shortening then composes K→O on top.
        let options = request.options
        let spans = keptRanges(trimIn: options.trimInSeconds,
                               trimOut: options.trimOutSeconds > 0 ? options.trimOutSeconds : .greatestFiniteMagnitude,
                               excluding: options.excludedRanges)
        var chapters = request.chapters.map { c in
            var c2 = c
            let kept = sourceToKept(c.timeSeconds, keptRanges: spans)
            c2.timeSeconds = segments.isEmpty ? kept : remapChapterTime(kept, using: segments)
            return c2
        }
        chapters = Self.collapseCoincidentChapters(chapters, log: log)

        if request.options.outputFormat == .mp3 {
            processor.writeTags(chapters: chapters, metadata: request.metadata, to: outputPath, logHandler: log)
        }

        return .finished(EpisodeResult(outputURL: request.outputURL, chapters: chapters,
                                       silenceSegments: segments))
    }

    /// Chapters either side of a cut can map to the same output time — a chapter
    /// inside an excluded range snaps to the cut point, where a chapter placed just
    /// after the cut already sits. Two chapters at the same millisecond would emit a
    /// zero-length CHAP frame, so keep the first and drop the rest.
    public static func collapseCoincidentChapters(_ chapters: [Chapter],
                                                  log: (String) -> Void) -> [Chapter] {
        let sorted = chapters.sorted { $0.timeSeconds < $1.timeSeconds }
        var result: [Chapter] = []
        var dropped: [String] = []
        for chapter in sorted {
            if let last = result.last, abs(chapter.timeSeconds - last.timeSeconds) < 0.001 {
                dropped.append(chapter.title.isEmpty ? "Untitled" : chapter.title)
            } else {
                result.append(chapter)
            }
        }
        if !dropped.isEmpty {
            log("⚠️ Dropped \(dropped.count) chapter\(dropped.count == 1 ? "" : "s") landing on a cut: \(dropped.joined(separator: ", "))")
        }
        return result
    }
}
