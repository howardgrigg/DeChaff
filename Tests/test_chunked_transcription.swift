#!/usr/bin/env swift
// Tests chunked parallel audio transcription vs sequential.
//
// Usage:
//   swift Tests/test_chunked_transcription.swift <path-to-audio-file> [chunk-minutes] [overlap-seconds]
//
// Defaults: 5-minute chunks, 5-second overlap.
// Requires: Apple Silicon Mac, macOS 26+, Apple Intelligence enabled.
//
// What it tests:
//   1. Splits the audio into N equal chunks with a configurable overlap at each boundary.
//   2. Transcribes all chunks concurrently using TaskGroup (one SpeechAnalyzer per chunk).
//   3. Merges the per-chunk word lists, deduplicating the overlap regions by splitting
//      each boundary at the midpoint of the overlap window.
//   4. Runs the same file sequentially as a baseline.
//   5. Prints wall-clock time for each approach, word counts, and a diff of the
//      first and last 5 words to spot boundary drift.

import Foundation
import AVFoundation
import Speech
import CoreMedia

// ---------------------------------------------------------------------------
// MARK: - Entry point
// ---------------------------------------------------------------------------

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: swift test_chunked_transcription.swift <audio-file> [chunk-minutes] [overlap-seconds] [--skip-baseline] [--serial-chunks]\n", stderr)
    exit(1)
}

let inputPath     = args[1]
let chunkMins     = args.count >= 3 ? Double(args[2]) ?? 5.0 : 5.0
let overlapSecs   = args.count >= 4 ? Double(args[3]) ?? 5.0 : 5.0
let skipBaseline  = args.contains("--skip-baseline")
let serialChunks  = args.contains("--serial-chunks")  // run chunks one-at-a-time to isolate concurrency effects

let inputURL = URL(fileURLWithPath: inputPath)
guard FileManager.default.fileExists(atPath: inputPath) else {
    fputs("File not found: \(inputPath)\n", stderr); exit(1)
}

// Run async work from a synchronous main thread using a semaphore.
let sema = DispatchSemaphore(value: 0)
Task {
    await runTest(inputURL: inputURL, chunkMinutes: chunkMins, overlapSeconds: overlapSecs,
                  skipBaseline: skipBaseline, serialChunks: serialChunks)
    sema.signal()
}
sema.wait()

// ---------------------------------------------------------------------------
// MARK: - TranscriptWord
// ---------------------------------------------------------------------------

struct TWord {
    let text: String
    let startTime: Double  // seconds into the original file
    let endTime: Double
}

actor WordBag {
    private(set) var words: [TWord] = []
    private(set) var nonFinalWordCount = 0
    func append(_ word: TWord) { words.append(word) }
    func countNonFinal(_ n: Int) { nonFinalWordCount += n }
}


// ---------------------------------------------------------------------------
// MARK: - Audio extraction
// ---------------------------------------------------------------------------

/// Extracts [startSec, endSec] from source into a temp CAF file.
/// If endSec == 0 the full file is extracted.
func extractChunk(from sourceURL: URL, startSec: Double, endSec: Double) throws -> URL {
    let source  = try AVAudioFile(forReading: sourceURL)
    let format  = source.processingFormat
    let sr      = format.sampleRate
    let startF  = AVAudioFramePosition(startSec * sr)
    let endF: AVAudioFramePosition = endSec > startSec + 0.5
        ? min(AVAudioFramePosition(endSec * sr), source.length)
        : source.length
    let total   = AVAudioFrameCount(max(0, endF - startF))
    guard total > 0 else { throw NSError(domain: "Chunk", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty chunk"]) }

    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dechaff-chunk-\(UUID().uuidString).caf")
    let dest    = try AVAudioFile(forWriting: tempURL, settings: format.settings)
    source.framePosition = startF

    let chunkSize: AVAudioFrameCount = 65536
    guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
        throw NSError(domain: "Chunk", code: 2, userInfo: [NSLocalizedDescriptionKey: "Buffer alloc failed"])
    }
    var remaining = total
    while remaining > 0 {
        let toRead = min(chunkSize, remaining)
        buf.frameLength = toRead
        try source.read(into: buf, frameCount: toRead)
        try dest.write(from: buf)
        remaining -= toRead
    }
    return tempURL
}

// ---------------------------------------------------------------------------
// MARK: - Transcription (single chunk)
// ---------------------------------------------------------------------------

/// Transcribes a CAF file and returns words with times offset by `timeOffset`.
/// `label` is printed with live progress so you can see the script is alive.
func transcribeChunk(url: URL, timeOffset: Double, label: String = "") async throws -> (words: [TWord], nonFinalSkipped: Int) {
    let transcriber = SpeechTranscriber(locale: .current, preset: .timeIndexedProgressiveTranscription)
                                                                                                                      
    let status = await AssetInventory.status(forModules: [transcriber])
    if status == .unsupported {
        throw NSError(domain: "Speech", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence not supported on this device"])
    }
    if status < .installed {
        if let dl = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await dl.downloadAndInstall()
        }
    }
                                                                                                                      
    let file     = try AVAudioFile(forReading: url)
    let analyzer = SpeechAnalyzer(modules: [transcriber])

    // Two concurrent tasks in a group:
    //   Analyzer – feeds audio via analyzeSequence, then sleeps 3 seconds.
    //              The sleep gives the results stream time to flush all final
    //              results after analyzeSequence signals completion.
    //   Collector – iterates transcriber.results until the stream closes.
    //
    // The collector always wins the race (finishes before the 3 s sleep).
    // group.cancelAll() then wakes the sleeping analyzer task immediately.
    // Both try? wrappers let external cancellation exit cleanly.
    let bag = WordBag()
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            _ = try? await analyzer.analyzeSequence(from: file)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        group.addTask {
            var lastPrintedMinute = -1
            for try await result in transcriber.results {
                if let tr = result.text.runs.first?.audioTimeRange {
                    let minute = Int((tr.start.seconds + timeOffset) / 60)
                    if minute != lastPrintedMinute {
                        lastPrintedMinute = minute
                        let preview = String(result.text.characters).prefix(40)
                        print("  \(label) ~\(minute)m: \(preview)…")
                    }
                }
                guard result.isFinal else { continue }
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty, let tr = run.audioTimeRange else { continue }
                    let start = tr.start.seconds + timeOffset
                    let end   = (tr.start + tr.duration).seconds + timeOffset
                    guard start.isFinite && end.isFinite && end > start else { continue }
                    await bag.append(TWord(text: text, startTime: start, endTime: end))
                }
            }
        }
        try? await group.next() // collector finishes first; get its completion
        group.cancelAll()       // wake and exit the sleeping analyzer task
    }
    return (words: await bag.words, nonFinalSkipped: await bag.nonFinalWordCount)
}

// ---------------------------------------------------------------------------
// MARK: - Merge helpers
// ---------------------------------------------------------------------------

/// Given words from two adjacent chunks and the boundary time between them,
/// keeps words from `left` up to the midpoint and words from `right` from
/// the midpoint onwards, removing duplicates in the overlap region.
func mergeAtBoundary(left: [TWord], right: [TWord], boundaryStart: Double, boundaryEnd: Double) -> [TWord] {
    let mid = (boundaryStart + boundaryEnd) / 2.0
    let leftKept  = left.filter  { $0.startTime < mid }
    let rightKept = right.filter { $0.startTime >= mid }
    return leftKept + rightKept
}

/// Merges an ordered list of per-chunk word arrays, applying overlap dedup at each boundary.
func mergeChunks(chunkWords: [[TWord]], chunkStarts: [Double], chunkEnds: [Double], overlapSecs: Double) -> [TWord] {
    guard !chunkWords.isEmpty else { return [] }
    var merged = chunkWords[0]
    for i in 1..<chunkWords.count {
        let boundaryStart = chunkStarts[i]           // = chunkEnds[i-1] - overlapSecs
        let boundaryEnd   = boundaryStart + overlapSecs
        merged = mergeAtBoundary(left: merged, right: chunkWords[i],
                                 boundaryStart: boundaryStart, boundaryEnd: boundaryEnd)
    }
    return merged.sorted { $0.startTime < $1.startTime }
}

// ---------------------------------------------------------------------------
// MARK: - Main test
// ---------------------------------------------------------------------------

func runTest(inputURL: URL, chunkMinutes: Double, overlapSeconds: Double, skipBaseline: Bool, serialChunks: Bool) async {
    let chunkSecs = chunkMinutes * 60.0

    // Get file duration
    let asset    = AVURLAsset(url: inputURL)
    let duration: Double
    do {
        let cmDur = try await asset.load(.duration)
        duration  = cmDur.seconds
    } catch {
        fputs("Failed to load duration: \(error)\n", stderr); return
    }
    guard duration > 0 else { fputs("Zero duration file\n", stderr); return }

    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("File:     \(inputURL.lastPathComponent)")
    print(String(format: "Duration: %.1f min (%.0f sec)", duration / 60, duration))
    print(String(format: "Chunks:   %.0f min each, %.0f sec overlap", chunkMinutes, overlapSeconds))

    // Plan chunks
    var chunkStarts: [Double] = []
    var chunkEnds:   [Double] = []
    var start = 0.0
    while start < duration {
        let end = min(start + chunkSecs + overlapSeconds, duration)
        chunkStarts.append(start)
        chunkEnds.append(end)
        start += chunkSecs
        if start >= duration { break }
    }
    let nChunks = chunkStarts.count
    print("Planned:  \(nChunks) chunk(s)")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    // ── SEQUENTIAL ─────────────────────────────────────────────────
    var seqWords: [TWord] = []
    var seqElapsed = 0.0
    if skipBaseline {
        print("\n▶ Sequential baseline skipped (--skip-baseline)")
    } else {
        print("\n▶ Sequential (baseline) — \(String(format: "%.0f", duration))s of audio, this will take a while…")
        let seqStart = Date()
        do {
            let tempURL = try extractChunk(from: inputURL, startSec: 0, endSec: 0)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let seqResult = try await transcribeChunk(url: tempURL, timeOffset: 0, label: "[seq]")
            seqWords = seqResult.words
            print("  (non-final words skipped: \(seqResult.nonFinalSkipped))")
        } catch {
            print("  Sequential failed: \(error)")
        }
        seqElapsed = Date().timeIntervalSince(seqStart)
        print(String(format: "  Done in %.1f sec — %d words", seqElapsed, seqWords.count))
    }

    // ── CHUNKED (PARALLEL or SERIAL) ───────────────────────────────
    let maxConcurrent = serialChunks ? 1 : 4
    let modeLabel = serialChunks ? "serial (1 at a time)" : "parallel (4 at a time)"
    print("\n▶ Chunked \(modeLabel) — \(nChunks) chunks…")
    let parStart = Date()
    var chunkResults: [[TWord]] = Array(repeating: [], count: nChunks)

    do {
        try await withThrowingTaskGroup(of: (Int, [TWord]).self) { group in
            for i in 0..<nChunks {
                if i >= maxConcurrent {
                    if let (idx, words) = try await group.next() {
                        chunkResults[idx] = words
                    }
                }
                let s = chunkStarts[i], e = chunkEnds[i], idx = i
                group.addTask {
                    let tempURL = try extractChunk(from: inputURL, startSec: s, endSec: e)
                    defer { try? FileManager.default.removeItem(at: tempURL) }
                    print("  [Start] Chunk \(idx+1)/\(nChunks): \(String(format: "%.0f", s))s–\(String(format: "%.0f", e))s")
                    let (words, nonFinal) = try await transcribeChunk(url: tempURL, timeOffset: s, label: "[chunk \(idx+1)]")
                    print("  [Done]  Chunk \(idx+1)/\(nChunks): \(words.count) final words, \(nonFinal) non-final skipped")
                    return (idx, words)
                }
            }
            for try await (idx, words) in group { chunkResults[idx] = words }
        }
    } catch {
        print("  Chunked failed: \(error)")
    }

    let merged     = mergeChunks(chunkWords: chunkResults, chunkStarts: chunkStarts,
                                  chunkEnds: chunkEnds, overlapSecs: overlapSeconds)
    let parElapsed = Date().timeIntervalSince(parStart)
    print(String(format: "  Done in %.1f sec — %d words after merge", parElapsed, merged.count))

    // ── COMPARISON ─────────────────────────────────────────────────
    print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("RESULTS")
    if !skipBaseline {
        print(String(format: "  Sequential (full file): %.1f sec,  %d words", seqElapsed, seqWords.count))
    }
    print(String(format: "  Chunked (\(modeLabel)): %.1f sec,  %d words", parElapsed, merged.count))
    if !skipBaseline && seqElapsed > 0 {
        print(String(format: "  Speedup:         %.2fx", seqElapsed / parElapsed))
        let wordDiff = abs(seqWords.count - merged.count)
        let pct = seqWords.count > 0 ? Double(wordDiff) / Double(seqWords.count) * 100 : 0
        print(String(format: "  Word count diff: %d (%.1f%%)", wordDiff, pct))
        print("\n  Sequential first 10: " + seqWords.prefix(10).map { $0.text }.joined(separator: " "))
        print("  Chunked    first 10: " + merged.prefix(10).map { $0.text }.joined(separator: " "))
        print("\n  Sequential last  10: " + seqWords.suffix(10).map { $0.text }.joined(separator: " "))
        print("  Chunked    last  10: " + merged.suffix(10).map { $0.text }.joined(separator: " "))
    } else {
        print("\n  Per-chunk word counts:")
        for i in 0..<nChunks {
            print(String(format: "    Chunk %2d: %d words", i+1, chunkResults[i].count))
        }
        print("\n  First 10 words: " + merged.prefix(10).map { $0.text }.joined(separator: " "))
        print("  Last  10 words: " + merged.suffix(10).map { $0.text }.joined(separator: " "))
    }

    print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
}
