import Foundation
import AVFoundation
import Speech
import CoreMedia
import Accelerate

// MARK: - Audio extraction

public func extractTrimmedAudio(from sourceURL: URL, trimIn: Double, trimOut: Double) throws -> URL {
    let source = try AVAudioFile(forReading: sourceURL)
    let format = source.processingFormat
    let sr = format.sampleRate
    let nch = Int(format.channelCount)
    let startFrame = AVAudioFramePosition(trimIn * sr)
    let endFrame: AVAudioFramePosition = trimOut > trimIn + 0.5
        ? min(AVAudioFramePosition(trimOut * sr), source.length) : source.length
    let totalFrames = AVAudioFrameCount(max(0, endFrame - startFrame))
    guard totalFrames > 0 else { throw CocoaError(.fileReadInvalidFileName) }
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dechaff_transcript_\(UUID().uuidString).caf")

    // Write mono — the speech models don't use stereo, and float32 stereo temp
    // files add up to gigabytes per sermon across the four parallel chunks.
    let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
    let dest = try AVAudioFile(forWriting: tempURL, settings: monoFormat.settings)
    source.framePosition = startFrame
    let chunkSize: AVAudioFrameCount = 65536
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize),
          let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunkSize) else {
        throw CocoaError(.fileReadUnknown)
    }
    var remaining = totalFrames
    while remaining > 0 {
        let toRead = min(chunkSize, remaining)
        buffer.frameLength = toRead
        try source.read(into: buffer, frameCount: toRead)
        let n = Int(buffer.frameLength)
        guard n > 0 else { break }
        monoBuffer.frameLength = buffer.frameLength
        if let out = monoBuffer.floatChannelData?[0] {
            if nch == 1, let src = buffer.floatChannelData?[0] {
                memcpy(out, src, n * MemoryLayout<Float>.size)
            } else {
                // Average all channels
                vDSP_vclr(out, 1, vDSP_Length(n))
                for ch in 0..<nch {
                    guard let src = buffer.floatChannelData?[ch] else { continue }
                    vDSP_vadd(out, 1, src, 1, out, 1, vDSP_Length(n))
                }
                var divisor = Float(nch)
                vDSP_vsdiv(out, 1, &divisor, out, 1, vDSP_Length(n))
            }
        }
        try dest.write(from: monoBuffer)
        remaining -= AVAudioFrameCount(n)
    }
    return tempURL
}

// MARK: - Chunked transcription helpers

/// Transcribes one audio file, streaming finalized words via `onWords` as they arrive.
/// `chunkDuration` is the non-overlapping chunk length used to normalise progress (0–1).
/// `onProgress` is called for every result (including non-final) for smooth progress tracking.
/// `onWords` is called with each batch of finalized words so the UI can update incrementally.
public func transcribeChunkWords(
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
            var lastProgress = -1.0
            do {
                for try await result in transcriber.results {
                    // Volatile results stream continuously — only report progress in 1%
                    // steps; every report is two actor hops plus a published UI update.
                    if let tr = result.text.runs.first?.audioTimeRange {
                        let p = min(tr.start.seconds / chunkDuration, 1.0)
                        if p - lastProgress >= 0.01 {
                            lastProgress = p
                            await onProgress(p)
                        }
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
public func mergeTranscriptChunks(chunkWords: [[TranscriptWord]], chunkStarts: [Double], overlapSecs: Double) -> [TranscriptWord] {
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

// MARK: - Chunked word-level transcription

public enum TranscriptionError: LocalizedError {
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .unsupported: return "On-device speech recognition requires Apple Silicon and macOS 26+."
        }
    }
}

/// Transcribes a whole file with word-level timings, splitting it into `chunkCount`
/// equal chunks (each overlapping the next by `overlapSeconds`) that run in parallel.
/// `onProgress` reports 0–1 across all chunks; `onPartial` delivers the merged words
/// so far each time a chunk produces finalized results.
public func transcribeWords(
    url: URL, chunkCount: Int = 4, overlapSeconds: Double = 5.0,
    onProgress: @escaping @Sendable (Double) async -> Void = { _ in },
    onPartial:  @escaping @Sendable ([TranscriptWord]) async -> Void = { _ in }
) async throws -> [TranscriptWord] {
    // Check / install on-device speech models
    let probe = SpeechTranscriber(locale: .current, preset: .timeIndexedProgressiveTranscription)
    let status = await AssetInventory.status(forModules: [probe])
    if status == .unsupported { throw TranscriptionError.unsupported }
    if status < .installed {
        if let dl = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await dl.downloadAndInstall()
        }
    }

    // Get file duration and plan equal chunks with overlap
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    guard duration > 0 else { throw CocoaError(.fileReadInvalidFileName) }

    let nChunks = max(1, chunkCount)
    let chunkSecs = duration / Double(nChunks)
    let chunkStarts = (0..<nChunks).map { Double($0) * chunkSecs }
    let chunkEnds   = chunkStarts.map { min($0 + chunkSecs + overlapSeconds, duration) }

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
    let chunkProgress    = ChunkProgress(count: nChunks)
    let chunkAccumulator = ChunkAccumulator(count: nChunks)

    // Transcribe all chunks in parallel; words stream out via onPartial as each
    // result is finalised.
    try await withThrowingTaskGroup(of: (Int, [TranscriptWord]).self) { group in
        for i in 0..<nChunks {
            let s = chunkStarts[i], e = chunkEnds[i], idx = i
            group.addTask {
                let tempURL = try extractTrimmedAudio(from: url, trimIn: s, trimOut: e)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                let words = try await transcribeChunkWords(
                    url: tempURL, timeOffset: s, chunkDuration: chunkSecs,
                    onProgress: { p in
                        guard !Task.isCancelled else { return }
                        await chunkProgress.update(index: idx, value: p)
                        await onProgress(await chunkProgress.overall)
                    },
                    onWords: { batch in
                        guard !Task.isCancelled else { return }
                        await chunkAccumulator.append(batch, to: idx)
                        await onPartial(mergeTranscriptChunks(
                            chunkWords: await chunkAccumulator.all,
                            chunkStarts: chunkStarts, overlapSecs: overlapSeconds))
                    }
                )
                // Chunk fully done — snap its progress to 1.0 so the bar
                // doesn't stall waiting for recogniser lookahead to drain.
                await chunkProgress.update(index: idx, value: 1.0)
                await onProgress(await chunkProgress.overall)
                return (idx, words)
            }
        }
        // As each chunk completes, replace its accumulated words with the
        // authoritative final list (handles any overlap-dedup edge cases).
        for try await (idx, words) in group {
            try Task.checkCancellation()
            await chunkAccumulator.set(words, at: idx)
            await onPartial(mergeTranscriptChunks(
                chunkWords: await chunkAccumulator.all,
                chunkStarts: chunkStarts, overlapSecs: overlapSeconds))
        }
    }

    return mergeTranscriptChunks(chunkWords: await chunkAccumulator.all,
                                 chunkStarts: chunkStarts, overlapSecs: overlapSeconds)
}
