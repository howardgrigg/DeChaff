import AVFoundation
import Foundation
import Testing
@testable import DeChaffCore

/// Runs the whole pipeline on a sermon-length recording. Short renders hide losses that
/// scale with length: the slow leveler once dropped 68 frames a second, which is 30 ms on
/// a 19 s clip but cut the closing "Amen" off a 38-minute episode.
@Suite struct LongRecordingTests {
    @Test func pipelineKeepsEveryFrameOfALongRecording() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dechaff-long-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("service.wav"), output = dir.appendingPathComponent("episode.wav")

        let sr = 44_100.0, minutes = 10.0
        try writeSpeechLikeRecording(to: input, seconds: minutes * 60, sampleRate: sr)

        let trimIn = 15.0, trimOut = minutes * 60 - 20
        let cut = ExcludedRange(startSeconds: 200, endSeconds: 260)
        let options = ProcessingOptions(
            voiceIsolation: false,   // the AU pass still runs, for compression
            outputFormat: .wav, shortenSilences: true, maxSilenceDuration: 1.0, slowLeveler: true,
            trimInSeconds: trimIn, trimOutSeconds: trimOut, excludedRanges: [cut])
        let chapters = [Chapter(timeSeconds: trimIn, title: "Reading"),
                        Chapter(timeSeconds: 300, title: "Sermon"),
                        Chapter(timeSeconds: 500, title: "Response")]
        let request = EpisodeRequest(inputURL: input, outputURL: output, options: options,
                                     metadata: ID3Metadata(), chapters: chapters)

        guard case .finished(let result) = EpisodeProcessor().run(request, progress: { _ in }, log: { _ in }) else {
            Issue.record("Processing didn't finish"); return
        }

        let kept = keptDuration(keptRanges(trimIn: trimIn, trimOut: trimOut, excluding: [cut]))
        let removed = result.silenceSegments.reduce(0.0) { $0 + max(0, ($1.endSeconds - $1.startSeconds) - $1.keptSeconds) }
        let file = try AVAudioFile(forReading: output)
        let outputSeconds = Double(file.length) / file.fileFormat.sampleRate

        #expect(removed > 10, "the recording's long pauses should have been shortened")
        // Trim and cut points round to whole frames, so allow a few milliseconds.
        #expect(abs(outputSeconds - (kept - removed)) < 0.05,
                "output \(outputSeconds) s, expected \(kept - removed) s (kept \(kept) − silence \(removed))")

        #expect(result.chapters.map(\.title) == ["Reading", "Sermon", "Response"])
        #expect(result.chapters.first?.timeSeconds == 0)
        #expect(zip(result.chapters, result.chapters.dropFirst()).allSatisfy { $0.timeSeconds < $1.timeSeconds })
        #expect((result.chapters.last?.timeSeconds ?? .infinity) < outputSeconds)
    }

    /// Phrases of varying loudness separated by pauses of 0.3–3 s, so the leveler, the
    /// loudness pass and silence shortening all have real work to do.
    private func writeSpeechLikeRecording(to url: URL, seconds: Double, sampleRate sr: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let total = Int(seconds * sr)
        let chunk = AVAudioFrameCount(sr)   // write a second at a time
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        var rng: UInt64 = 0x9E3779B97F4A7C15
        func random() -> Double {   // SplitMix64, so the recording is the same every run
            rng &+= 0x9E3779B97F4A7C15
            var z = rng
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double(z ^ (z >> 31)) / Double(UInt64.max)
        }

        var segmentLeft = 0, inPhrase = false, level: Float = 0, pitch = 180.0
        var written = 0
        while written < total {
            let n = min(Int(chunk), total - written)
            buf.frameLength = AVAudioFrameCount(n)
            let d = buf.floatChannelData![0]
            for i in 0..<n {
                if segmentLeft == 0 {
                    inPhrase.toggle()
                    segmentLeft = Int((inPhrase ? 2 + random() * 6 : 0.3 + random() * 2.7) * sr)
                    level = Float(0.04 + random() * 0.3)
                    pitch = 120 + random() * 160
                }
                segmentLeft -= 1
                let t = Double(written + i) / sr
                let noiseFloor = Float(random() - 0.5) * 0.002
                if inPhrase {
                    // A voiced buzz with a syllable-rate wobble.
                    let syllable = Float(0.6 + 0.4 * sin(2 * .pi * 4 * t))
                    d[i] = level * syllable * Float(sin(2 * .pi * pitch * t) + 0.3 * sin(4 * .pi * pitch * t)) + noiseFloor
                } else {
                    d[i] = noiseFloor
                }
            }
            try file.write(from: buf)
            written += n
        }
    }
}
