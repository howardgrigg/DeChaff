import Foundation
import AVFoundation
import Speech
import CoreMedia
import Accelerate

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
    let sr = source.processingFormat.sampleRate
    let end = trimOut > trimIn + 0.5 ? trimOut : Double(source.length) / sr
    return try extractKeptAudio(from: sourceURL, spans: [KeptSpan(start: trimIn, end: end)])
}

/// Writes the given source spans, back to back, into one mono temp file.
/// A single span is the plain trim case; several spans splice out the user's
/// excluded ranges so the transcript covers only what will ship.
func extractKeptAudio(from sourceURL: URL, spans: [KeptSpan]) throws -> URL {
    let source = try AVAudioFile(forReading: sourceURL)
    let format = source.processingFormat
    let sr = format.sampleRate
    let nch = Int(format.channelCount)

    let ranges: [(start: AVAudioFramePosition, end: AVAudioFramePosition)] = spans.compactMap { span in
        let s = max(0, min(AVAudioFramePosition(span.start * sr), source.length))
        let e = max(s, min(AVAudioFramePosition(span.end * sr), source.length))
        return e > s ? (start: s, end: e) : nil
    }
    let totalFrames = ranges.reduce(AVAudioFramePosition(0)) { $0 + ($1.end - $1.start) }
    guard totalFrames > 0 else { throw CocoaError(.fileReadInvalidFileName) }
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dechaff_transcript_\(UUID().uuidString).caf")

    // Write mono — the speech models don't use stereo, and float32 stereo temp
    // files add up to gigabytes per sermon across the four parallel chunks.
    let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
    let dest = try AVAudioFile(forWriting: tempURL, settings: monoFormat.settings)
    let chunkSize: AVAudioFrameCount = 65536
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize),
          let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunkSize) else {
        throw CocoaError(.fileReadUnknown)
    }

    for range in ranges {
        source.framePosition = range.start
        var remaining = AVAudioFrameCount(range.end - range.start)
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
