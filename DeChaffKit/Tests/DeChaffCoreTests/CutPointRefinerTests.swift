import Foundation
import Testing
@testable import DeChaffCore

/// Builds synthetic recordings: a low noise floor with loud "speech" bursts at known times,
/// so we can check refined cuts against the real boundaries rather than the transcript's.
private struct Synth {
    static let sampleRate = 16_000.0
    var samples: [Float]
    private var rng = SplitMix(seed: 42)

    init(duration: Double, noiseDB: Float = -60) {
        samples = []
        let amp = powf(10, noiseDB / 20) * sqrtf(3)  // uniform noise with this RMS
        for _ in 0..<Int(duration * Self.sampleRate) { samples.append(amp * rng.nextSigned()) }
    }

    mutating func speech(_ from: Double, _ to: Double, db: Float = -20) {
        let amp = powf(10, db / 20) * sqrtf(2)
        for i in Int(from * Self.sampleRate)..<min(samples.count, Int(to * Self.sampleRate)) {
            samples[i] += amp * sinf(Float(2 * Double.pi * 220 * Double(i) / Self.sampleRate))
        }
    }

    var envelope: EnergyEnvelope { EnergyEnvelope(samples: samples, sampleRate: Self.sampleRate) }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextSigned() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24) * 2 - 1
    }
}

private func w(_ text: String, _ s: Double, _ e: Double) -> TranscriptWord {
    TranscriptWord(text: text, startTime: s, endTime: e)
}

@Suite struct CutPointRefinerTests {
    let refiner = CutPointRefiner()

    @Test func startCutCatchesOnsetTheTranscriptMissed() {
        var a = Synth(duration: 20)
        a.speech(4, 8)
        a.speech(10.00, 10.40)   // "Good" really starts at 10.00…
        a.speech(10.50, 11.00)
        // …but the recogniser says 10.12.
        let words = [w("amen.", 7.6, 7.95), w("Good", 10.12, 10.40), w("morning", 10.50, 11.0)]

        let r = refiner.refine(edge: .start, wordIndex: 1, words: words, envelope: a.envelope)
        #expect(r.quality == .clean)
        #expect(abs((r.detectedBoundary ?? 0) - 10.00) <= 0.011)
        #expect(abs(r.time - (10.00 - 0.15)) <= 0.015)
        #expect(r.time < 10.00)
        #expect(r.notes.contains { $0.contains("before the transcript") })
    }

    @Test func endCutKeepsTrailingSoundTheTranscriptClipped() {
        var a = Synth(duration: 30)
        a.speech(18, 20.30)      // "Amen" really ends at 20.30…
        a.speech(22, 23)
        let words = [w("Amen.", 19.8, 20.15), w("Please", 22.0, 22.4)]  // …transcript says 20.15

        let r = refiner.refine(edge: .end, wordIndex: 0, words: words, envelope: a.envelope)
        #expect(r.quality == .clean)
        #expect(abs((r.detectedBoundary ?? 0) - 20.30) <= 0.011)
        // Plenty of silence before "Please", so the cut leaves the full end tail.
        #expect(abs(r.time - (20.30 + CutRefinementOptions().endTail)) <= 0.015)
    }

    @Test func endTailStopsShortOfTheNextWord() {
        var a = Synth(duration: 30)
        a.speech(18, 20.30)
        a.speech(20.80, 23)      // only 0.5 s of silence — less than the end tail
        let words = [w("Amen.", 19.8, 20.30), w("Please", 20.80, 21.2)]

        let r = refiner.refine(edge: .end, wordIndex: 0, words: words, envelope: a.envelope)
        #expect(r.quality == .clean)
        #expect(r.time >= 20.30 + CutRefinementOptions().postRoll - 0.015)
        #expect(r.time <= 20.80 - CutRefinementOptions().guardTime + 0.015)
    }

    @Test func endCutIsNotFooledByStopConsonantClosure() {
        var a = Synth(duration: 30)
        a.speech(19.5, 20.00)    // "tha-"
        a.speech(20.06, 20.12)   // "-t" release after a 60 ms closure
        a.speech(22, 23)
        let words = [w("that.", 19.5, 19.98), w("Now", 22.0, 22.3)]

        let r = refiner.refine(edge: .end, wordIndex: 0, words: words, envelope: a.envelope)
        #expect((r.detectedBoundary ?? 0) >= 20.12 - 0.011)
        #expect(r.time > 20.12 + 0.2)
    }

    @Test func tightGapPlacesCutMidGap() {
        var a = Synth(duration: 40)
        a.speech(29, 30.00)
        a.speech(30.12, 31)      // only 120 ms between words
        let words = [w("so", 29.6, 30.0), w("Let's", 30.15, 30.5)]

        let r = refiner.refine(edge: .start, wordIndex: 1, words: words, envelope: a.envelope)
        #expect(r.quality == .tight)
        #expect(r.time > 30.00 && r.time < 30.12)
    }

    @Test func wordsRunningTogetherAreFlagged() {
        var a = Synth(duration: 40)
        a.speech(29, 31)
        let words = [w("and", 29.5, 30.0), w("then", 30.0, 30.4)]

        let r = refiner.refine(edge: .start, wordIndex: 1, words: words, envelope: a.envelope)
        #expect(r.quality == .forced)
        #expect(!r.notes.isEmpty)
    }

    @Test func refinementIsIdempotent() {
        var a = Synth(duration: 20)
        a.speech(10.00, 10.40)
        a.speech(13.00, 14.00)
        let words = [w("Good", 10.12, 10.40), w("evening", 13.0, 13.9)]
        let env = a.envelope

        let first = refiner.refine(edge: .start, time: 10.2, words: words, envelope: env)
        let second = refiner.refine(edge: .start, time: first.time, words: words, envelope: env)
        #expect(first.wordIndex == 0 && second.wordIndex == 0)
        #expect(abs(first.time - second.time) < 1e-9)

        let end1 = refiner.refine(edge: .end, time: 10.3, words: words, envelope: env)
        let end2 = refiner.refine(edge: .end, time: end1.time, words: words, envelope: env)
        #expect(end1.wordIndex == 0 && end2.wordIndex == 0)
        #expect(abs(end1.time - end2.time) < 1e-9)
    }

    @Test func energyOnlyMovesCutOutOfSpeech() {
        var a = Synth(duration: 20)
        a.speech(5, 10.0)
        a.speech(11.0, 15)
        // Requested trim-in lands 50 ms into the phrase starting at 11.0.
        let r = refiner.refine(edge: .start, time: 11.05, envelope: a.envelope)
        #expect(r.quality == .clean)
        #expect(abs(r.time - (11.0 - 0.15)) <= 0.015)

        // A trim-out requested 50 ms before the phrase ends at 10.0 is pushed past it.
        let e = refiner.refine(edge: .end, time: 9.95, envelope: a.envelope)
        #expect(e.time >= 10.0 + 0.3 - 0.015)
    }

    @Test func energyOnlyLeavesCutsAlreadyInSilence() {
        var a = Synth(duration: 20)
        a.speech(5, 8)
        a.speech(12, 15)
        let r = refiner.refine(edge: .start, time: 10.0, envelope: a.envelope)
        #expect(abs(r.time - 10.0) < 1e-9)
        #expect(r.notes.isEmpty)
    }

    @Test func wordSelectionNeverSplitsAWord() {
        let words = [w("a", 1, 2), w("b", 3, 4), w("c", 5, 6)]
        #expect(CutPointRefiner.wordIndex(startingAt: 3.5, in: words) == 1)  // inside "b": keep it
        #expect(CutPointRefiner.wordIndex(startingAt: 2.5, in: words) == 1)  // in the gap: next word
        #expect(CutPointRefiner.wordIndex(endingAt: 3.5, in: words) == 1)    // inside "b": keep it
        #expect(CutPointRefiner.wordIndex(endingAt: 4.5, in: words) == 1)    // in the gap: previous word
        #expect(CutPointRefiner.wordIndex(startingAt: 7, in: words) == nil)
    }
}
