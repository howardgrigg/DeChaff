import Foundation
import AVFoundation
import Speech
import CoreMedia

// MARK: - TranscriptWord

struct TranscriptWord: Identifiable {
    let id = UUID()
    let text: String
    let startTime: Double   // seconds into the original file
    let endTime: Double
}

// MARK: - Audio extraction

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

// MARK: - Chunked transcription helpers

/// Transcribes one audio file, streaming finalized words via `onWords` as they arrive.
/// `chunkDuration` is the non-overlapping chunk length used to normalise progress (0–1).
/// `onProgress` is called for every result (including non-final) for smooth progress tracking.
/// `onWords` is called with each batch of finalized words so the UI can update incrementally.
func transcribeChunkWords(
    url: URL, timeOffset: Double, chunkDuration: Double,
    onProgress: @escaping @Sendable (Double) async -> Void = { _ in },
    onWords:    @escaping @Sendable ([TranscriptWord]) async -> Void = { _ in }
) async throws -> [TranscriptWord] {
    let transcriber = SpeechTranscriber(locale: .current, preset: .timeIndexedProgressiveTranscription)

    // Status check must use the same transcriber instance that will be passed to SpeechAnalyzer.
    let status = await AssetInventory.status(forModules: [transcriber])
    if status < .installed {
        if let dl = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await dl.downloadAndInstall()
        }
    }

    let file     = try AVAudioFile(forReading: url)
    let analyzer = SpeechAnalyzer(modules: [transcriber])

    // Two concurrent child tasks:
    //   Analyzer  – feeds audio via analyzeSequence, then sleeps 3 s.
    //               The sleep lets the recogniser flush all pending final results
    //               naturally before the stream closes. Without the sleep, cancelAll()
    //               fires too early and the last ~1–2 min of words per chunk are lost.
    //   Collector – iterates transcriber.results until the stream closes naturally
    //               (during the 3 s window). Finishes first; group.next() returns.
    //               cancelAll() then wakes the sleeping analyzer immediately.
    actor WordBag { var words: [TranscriptWord] = []; func add(_ w: TranscriptWord) { words.append(w) } }
    let bag = WordBag()

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            _ = try? await analyzer.analyzeSequence(from: file)
            // Hold open so the results stream can drain naturally before we cancel.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        group.addTask {
            do {
                for try await result in transcriber.results {
                    // Report progress from every result (including non-final) for smooth tracking.
                    if let tr = result.text.runs.first?.audioTimeRange {
                        await onProgress(min(tr.start.seconds / chunkDuration, 1.0))
                    }
                    guard result.isFinal else { continue }
                    var batch: [TranscriptWord] = []
                    for run in result.text.runs {
                        let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty, let tr = run.audioTimeRange else { continue }
                        let start = tr.start.seconds + timeOffset
                        let end   = (tr.start + tr.duration).seconds + timeOffset
                        guard start.isFinite && end.isFinite && end > start else { continue }
                        batch.append(TranscriptWord(text: text, startTime: start, endTime: end))
                    }
                    if !batch.isEmpty {
                        for word in batch { await bag.add(word) }
                        await onWords(batch)
                    }
                }
            } catch { /* stream closed or cancelled — exit cleanly */ }
        }
        await group.next()  // collector finishes first (stream closed naturally)
        group.cancelAll()   // wake the sleeping analyzer immediately
    }

    return await bag.words
}

/// Merges per-chunk word arrays, deduplicating each overlap region at its midpoint.
/// Skips empty chunks so partial results during progressive updates look correct.
func mergeTranscriptChunks(chunkWords: [[TranscriptWord]], chunkStarts: [Double], overlapSecs: Double) -> [TranscriptWord] {
    var merged: [TranscriptWord] = []
    for (i, words) in chunkWords.enumerated() {
        guard !words.isEmpty else { continue }
        if merged.isEmpty {
            merged = words
        } else {
            let mid = chunkStarts[i] + overlapSecs / 2.0
            merged = merged.filter { $0.startTime < mid } + words.filter { $0.startTime >= mid }
        }
    }
    return merged.sorted { $0.startTime < $1.startTime }
}
