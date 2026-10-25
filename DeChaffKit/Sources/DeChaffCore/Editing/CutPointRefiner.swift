import Foundation

// MARK: - Energy envelope

/// Short-time loudness of a stretch of audio: one RMS level (dBFS) per fixed-length frame.
/// Frame `i` covers `[startTime + i·frameDuration, startTime + (i+1)·frameDuration)`.
public struct EnergyEnvelope: Sendable {
    public let startTime: Double
    public let frameDuration: Double
    public let levelsDB: [Float]

    /// Level reported for digital silence, so log(0) never reaches the maths.
    public static let silenceDB: Float = -120

    public init(startTime: Double, frameDuration: Double, levelsDB: [Float]) {
        self.startTime = startTime
        self.frameDuration = frameDuration
        self.levelsDB = levelsDB
    }

    /// Builds an envelope from mono samples.
    public init(samples: [Float], sampleRate: Double, startTime: Double = 0, frameDuration: Double = 0.01) {
        let frameLength = max(1, Int(sampleRate * frameDuration))
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frameLength + 1)
        var i = 0
        while i < samples.count {
            let end = min(i + frameLength, samples.count)
            var sum: Float = 0
            for j in i..<end { sum += samples[j] * samples[j] }
            levels.append(EnergyEnvelope.decibels(meanSquare: sum / Float(end - i)))
            i = end
        }
        self.init(startTime: startTime, frameDuration: Double(frameLength) / sampleRate, levelsDB: levels)
    }

    public static func decibels(meanSquare: Float) -> Float {
        meanSquare > 1e-12 ? max(silenceDB, 10 * log10f(meanSquare)) : silenceDB
    }

    public var endTime: Double { startTime + Double(levelsDB.count) * frameDuration }

    /// Index of the frame containing `t`, clamped to the envelope.
    public func frame(at t: Double) -> Int {
        guard !levelsDB.isEmpty else { return 0 }
        let i = Int(((t - startTime) / frameDuration).rounded(.down))
        return min(max(i, 0), levelsDB.count - 1)
    }

    public func frameStart(_ i: Int) -> Double { startTime + Double(i) * frameDuration }

    public func level(at t: Double) -> Float {
        levelsDB.isEmpty ? EnergyEnvelope.silenceDB : levelsDB[frame(at: t)]
    }

    func percentile(_ p: Double) -> Float {
        guard !levelsDB.isEmpty else { return EnergyEnvelope.silenceDB }
        let sorted = levelsDB.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))]
    }
}

// MARK: - Results

public enum CutEdge: String, Sendable, Codable {
    /// Audio before the cut is dropped (trim-in, chapter start).
    case start
    /// Audio after the cut is dropped (trim-out).
    case end
}

public enum CutQuality: String, Sendable, Codable {
    /// The cut sits in silence with the full pre-/post-roll.
    case clean
    /// The cut sits in silence, but the gap was shorter than the requested roll.
    case tight
    /// No usable silence nearby — the cut is at the quietest point and may clip sound.
    case forced
}

public struct CutRefinement: Sendable {
    public let edge: CutEdge
    public let requestedTime: Double
    /// The refined cut point, in the same timeline as the words/envelope.
    public let time: Double
    public let quality: CutQuality
    /// Index of the word kept nearest the cut (first kept word for `.start`, last for `.end`).
    public let wordIndex: Int?
    public let word: String?
    /// Where the transcript says the boundary word starts (`.start`) or ends (`.end`).
    public let transcriptBoundary: Double?
    /// Where the audio says that speech actually starts (`.start`) or ends (`.end`).
    public let detectedBoundary: Double?
    public let levelAtCutDB: Float
    public let noiseFloorDB: Float
    public let notes: [String]
}

// MARK: - Refiner

public struct CutRefinementOptions: Sendable {
    /// Silence left before speech at a `.start` cut.
    public var preRoll: Double = 0.15
    /// Silence left after speech at an `.end` cut — room for the last syllable's decay.
    public var postRoll: Double = 0.30
    /// How far before the transcript's word start to look for the real onset.
    public var onsetSearch: Double = 0.6
    /// How far after the transcript's word end to look for trailing sound
    /// (final consonants, reverb), which recognisers routinely clip.
    public var offsetSearch: Double = 0.8
    /// Silence that counts as a boundary between phrases. Longer than a stop-consonant
    /// closure, so the gap inside "that" or "kept" isn't mistaken for the end of the word.
    public var boundaryQuiet: Double = 0.10
    /// Fallback minimum when words run closer together than `boundaryQuiet`.
    public var minQuiet: Double = 0.04
    /// Keep this far from the neighbouring sound when the cut is placed inside a gap.
    public var guardTime: Double = 0.05
    /// Window searched either side of a bare time (no transcript) for silence.
    public var energyOnlySearch: Double = 0.75
    /// Silence threshold = noise floor + 35% of the floor-to-speech range, clamped to these.
    public var minThresholdAboveFloorDB: Float = 6
    public var maxThresholdAboveFloorDB: Float = 15

    public init() {}
}

/// Turns approximate cut points (a transcript word, or a bare time) into cuts that
/// sit in silence, so trimming never clips the start or end of a word.
///
/// Speech recognisers time words from the voiced core: they tend to start a word
/// late (missing a breathy or plosive onset) and end it early (missing a trailing
/// "s", "t", or room decay). The refiner therefore treats the transcript time as a
/// hint and searches the audio's energy envelope outward from it for the real
/// boundary — the nearest sustained run below a silence threshold derived from the
/// local noise floor — then leaves a pre-/post-roll of silence inside that gap.
public struct CutPointRefiner: Sendable {
    public var options: CutRefinementOptions

    public init(options: CutRefinementOptions = CutRefinementOptions()) {
        self.options = options
    }

    /// The stretch of audio `refine` needs around `time`; read only this much into the envelope.
    public func analysisWindow(around time: Double) -> ClosedRange<Double> {
        let reach = max(options.onsetSearch + options.preRoll, options.offsetSearch + options.postRoll,
                        options.energyOnlySearch + max(options.preRoll, options.postRoll))
        // A few seconds either side gives the noise-floor estimate some silence to find.
        return max(0, time - reach - 6)...(time + reach + 6)
    }

    // MARK: Word selection

    /// The first word kept by a `.start` cut at `time`: the word containing `time`,
    /// or the next one if `time` falls between words. A word is never cut in half.
    public static func wordIndex(startingAt time: Double, in words: [TranscriptWord]) -> Int? {
        words.firstIndex { $0.endTime > time }
    }

    /// The last word kept by an `.end` cut at `time`.
    public static func wordIndex(endingAt time: Double, in words: [TranscriptWord]) -> Int? {
        words.lastIndex { $0.startTime < time }
    }

    // MARK: Entry points

    /// Refines a cut given as a time, snapping to the word boundary when a transcript is available.
    public func refine(edge: CutEdge, time: Double, words: [TranscriptWord],
                       envelope: EnergyEnvelope) -> CutRefinement {
        let index = edge == .start
            ? Self.wordIndex(startingAt: time, in: words)
            : Self.wordIndex(endingAt: time, in: words)
        guard let index else { return refine(edge: edge, time: time, envelope: envelope) }
        return refine(edge: edge, wordIndex: index, words: words, envelope: envelope, requestedTime: time)
    }

    /// Refines a cut placed just before (`.start`) or just after (`.end`) `words[wordIndex]`.
    public func refine(edge: CutEdge, wordIndex: Int, words: [TranscriptWord],
                       envelope: EnergyEnvelope, requestedTime: Double? = nil) -> CutRefinement {
        precondition(words.indices.contains(wordIndex), "word index out of range")
        switch edge {
        case .start: return refineStart(wordIndex, words, envelope, requestedTime)
        case .end:   return refineEnd(wordIndex, words, envelope, requestedTime)
        }
    }

    /// Refines a bare time using the audio alone: moves it into the nearest silence.
    public func refine(edge: CutEdge, time: Double, envelope env: EnergyEnvelope) -> CutRefinement {
        let lv = levels(env)
        let o = options
        guard !env.levelsDB.isEmpty else {
            return CutRefinement(edge: edge, requestedTime: time, time: time, quality: .forced,
                                 wordIndex: nil, word: nil, transcriptBoundary: nil, detectedBoundary: nil,
                                 levelAtCutDB: EnergyEnvelope.silenceDB, noiseFloorDB: lv.floor,
                                 notes: ["No audio around \(formatCutTime(time)) — left as requested."])
        }
        let lo = env.frame(at: time - o.energyOnlySearch)
        let hi = env.frame(at: time + o.energyOnlySearch)

        for quietDuration in [o.boundaryQuiet, o.minQuiet] {
            let runs = quietRuns(env, lo...hi, lv.threshold, frames(quietDuration, env))
            // Prefer the gap containing the requested time, then the nearest one.
            let best = runs.min { distance(time, $0, env) < distance(time, $1, env) }
            guard let run = best else { continue }
            let gapStart = env.frameStart(run.lowerBound), gapEnd = env.frameStart(run.upperBound)
            var (cut, quality) = place(edge, inGap: gapStart, gapEnd, preferring: time)
            if quietDuration < o.boundaryQuiet { quality = .tight }
            cut = max(0, cut)
            var notes: [String] = []
            if abs(cut - time) >= 0.01 {
                notes.append("Moved \(formatShift(cut - time)) into silence (\(formatCutTime(gapStart))–\(formatCutTime(gapEnd))).")
            }
            if quality == .tight {
                notes.append("Only \(formatMs(gapEnd - gapStart)) of silence here; cut placed mid-gap.")
            }
            return CutRefinement(edge: edge, requestedTime: time, time: cut, quality: quality,
                                 wordIndex: nil, word: nil, transcriptBoundary: nil, detectedBoundary: nil,
                                 levelAtCutDB: env.level(at: cut), noiseFloorDB: lv.floor, notes: notes)
        }

        let q = quietestFrame(env, lo...hi)
        let cut = max(0, env.frameStart(q) + env.frameDuration / 2)
        return CutRefinement(
            edge: edge, requestedTime: time, time: cut, quality: .forced,
            wordIndex: nil, word: nil, transcriptBoundary: nil, detectedBoundary: nil,
            levelAtCutDB: env.levelsDB[q], noiseFloorDB: lv.floor,
            notes: ["No silence within ±\(formatMs(o.energyOnlySearch)) of \(formatCutTime(time)); "
                    + "cut at the quietest point (\(formatDB(env.levelsDB[q])), "
                    + "\(formatDB(env.levelsDB[q] - lv.floor, signed: true)) above the noise floor)."])
    }

    // MARK: Word-anchored edges

    private func refineStart(_ w: Int, _ words: [TranscriptWord], _ env: EnergyEnvelope,
                             _ requested: Double?) -> CutRefinement {
        let o = options
        let word = words[w]
        let prevEnd = w > 0 ? words[w - 1].endTime : -Double.infinity
        let lv = levels(env)
        let top = env.frame(at: word.startTime)
        // Transcript words can overlap slightly; never let the search window invert.
        let low = min(top, env.frame(at: max(word.startTime - o.onsetSearch, prevEnd)))

        func result(_ cut: Double, _ quality: CutQuality, onset: Double?, _ notes: [String]) -> CutRefinement {
            let cut = max(0, cut)
            return CutRefinement(edge: .start, requestedTime: requested ?? word.startTime, time: cut,
                                 quality: quality, wordIndex: w, word: word.text,
                                 transcriptBoundary: word.startTime, detectedBoundary: onset,
                                 levelAtCutDB: env.level(at: cut), noiseFloorDB: lv.floor, notes: notes)
        }

        for quietDuration in [o.boundaryQuiet, o.minQuiet] {
            let need = frames(quietDuration, env)
            // Walk back from the transcript's word start until we've seen `need` quiet frames.
            var run = 0, i = top, onsetFrame: Int? = nil
            while i >= low {
                if env.levelsDB[i] < lv.threshold {
                    run += 1
                    if run >= need { onsetFrame = i + need; break }
                } else {
                    run = 0
                }
                i -= 1
            }
            guard let onsetFrame else { continue }
            // A quiet word start means the transcript started it early; never cut later than it says.
            let onset = min(env.frameStart(onsetFrame), word.startTime)

            // Extend the gap backwards to see how much room there is for pre-roll.
            var q = onsetFrame - need
            let earliestNeeded = onset - o.preRoll - o.guardTime
            while q > 0, env.levelsDB[q - 1] < lv.threshold, env.frameStart(q - 1) >= earliestNeeded - env.frameDuration {
                q -= 1
            }
            let gapStart = env.frameStart(q)
            var (cut, quality) = place(.start, inGap: gapStart, onset, preferring: onset - o.preRoll)
            if quietDuration < o.boundaryQuiet { quality = .tight }

            var notes: [String] = []
            let early = word.startTime - onset
            if early >= 0.03 {
                notes.append("Speech starts \(formatMs(early)) before the transcript's timing for “\(word.text)” — kept it.")
            }
            if quality == .tight {
                let prev = w > 0 ? "“\(words[w - 1].text)” and " : ""
                notes.append("Only \(formatMs(onset - gapStart)) of silence between \(prev)“\(word.text)”; cut placed mid-gap.")
            }
            return result(cut, quality, onset: onset, notes)
        }

        // No silence at all: the words run together. Cut at the quietest point.
        let qf = quietestFrame(env, low...top)
        let cut = env.frameStart(qf) + env.frameDuration / 2
        return result(cut, .forced, onset: nil, [
            "No silence before “\(word.text)” (words run together); cut at the quietest point "
            + "(\(formatDB(env.levelsDB[qf] - lv.floor, signed: true)) above the noise floor). Check it by ear."
        ])
    }

    private func refineEnd(_ w: Int, _ words: [TranscriptWord], _ env: EnergyEnvelope,
                           _ requested: Double?) -> CutRefinement {
        let o = options
        let word = words[w]
        let nextStart = w + 1 < words.count ? words[w + 1].startTime : Double.infinity
        let lv = levels(env)
        let bottom = env.frame(at: word.endTime)
        let high = max(bottom, env.frame(at: min(word.endTime + o.offsetSearch, nextStart)))

        func result(_ cut: Double, _ quality: CutQuality, offset: Double?, _ notes: [String]) -> CutRefinement {
            let cut = max(0, cut)
            return CutRefinement(edge: .end, requestedTime: requested ?? word.endTime, time: cut,
                                 quality: quality, wordIndex: w, word: word.text,
                                 transcriptBoundary: word.endTime, detectedBoundary: offset,
                                 levelAtCutDB: env.level(at: cut), noiseFloorDB: lv.floor, notes: notes)
        }

        for quietDuration in [o.boundaryQuiet, o.minQuiet] {
            let need = frames(quietDuration, env)
            // Walk forward from the transcript's word end until we've seen `need` quiet frames.
            var run = 0, i = bottom, offsetFrame: Int? = nil
            while i <= high {
                if env.levelsDB[i] < lv.threshold {
                    run += 1
                    if run >= need { offsetFrame = i - need + 1; break }
                } else {
                    run = 0
                }
                i += 1
            }
            guard let offsetFrame else { continue }
            // A quiet word end means the transcript ended it late; never cut earlier than it says.
            let offset = max(env.frameStart(offsetFrame), word.endTime)

            // Extend the gap forwards to see how much room there is for post-roll.
            var q = offsetFrame + need - 1
            let latestNeeded = offset + o.postRoll + o.guardTime
            while q + 1 < env.levelsDB.count, env.levelsDB[q + 1] < lv.threshold,
                  env.frameStart(q + 1) + env.frameDuration <= latestNeeded + env.frameDuration {
                q += 1
            }
            let gapEnd = env.frameStart(q) + env.frameDuration
            var (cut, quality) = place(.end, inGap: offset, gapEnd, preferring: offset + o.postRoll)
            if quietDuration < o.boundaryQuiet { quality = .tight }

            var notes: [String] = []
            let late = offset - word.endTime
            if late >= 0.03 {
                notes.append("Sound continues \(formatMs(late)) past the transcript's end of “\(word.text)” "
                             + "(trailing consonant or decay) — kept it.")
            }
            if quality == .tight {
                let next = w + 1 < words.count ? " and “\(words[w + 1].text)”" : ""
                notes.append("Only \(formatMs(gapEnd - offset)) of silence between “\(word.text)”\(next); cut placed mid-gap.")
            }
            return result(cut, quality, offset: offset, notes)
        }

        let qf = quietestFrame(env, bottom...high)
        let cut = env.frameStart(qf) + env.frameDuration / 2
        return result(cut, .forced, offset: nil, [
            "No silence after “\(word.text)” (words run together); cut at the quietest point "
            + "(\(formatDB(env.levelsDB[qf] - lv.floor, signed: true)) above the noise floor). Check it by ear."
        ])
    }

    // MARK: Helpers

    /// Places a cut inside the silent gap `[gapStart, gapEnd)`: as close to `preferred` as
    /// possible while leaving the roll on the speech side and a guard on the other.
    /// Gaps too short for both get the midpoint.
    private func place(_ edge: CutEdge, inGap gapStart: Double, _ gapEnd: Double,
                       preferring preferred: Double) -> (Double, CutQuality) {
        let lo: Double, hi: Double
        switch edge {
        case .start: lo = gapStart + options.guardTime; hi = gapEnd - options.preRoll
        case .end:   lo = gapStart + options.postRoll;  hi = gapEnd - options.guardTime
        }
        if lo <= hi { return (min(max(preferred, lo), hi), .clean) }
        return ((gapStart + gapEnd) / 2, .tight)
    }

    private func levels(_ env: EnergyEnvelope) -> (floor: Float, threshold: Float) {
        let floor = env.percentile(0.10)
        let speech = env.percentile(0.90)
        let above = min(max((speech - floor) * 0.35, options.minThresholdAboveFloorDB),
                        options.maxThresholdAboveFloorDB)
        return (floor, floor + above)
    }

    private func frames(_ seconds: Double, _ env: EnergyEnvelope) -> Int {
        max(1, Int((seconds / env.frameDuration).rounded(.up)))
    }

    /// Maximal runs of frames below `threshold` within `range`, at least `minFrames` long.
    /// Returned as half-open frame ranges.
    private func quietRuns(_ env: EnergyEnvelope, _ range: ClosedRange<Int>, _ threshold: Float,
                           _ minFrames: Int) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int? = nil
        for i in range {
            if env.levelsDB[i] < threshold {
                if start == nil { start = i }
            } else if let s = start {
                if i - s >= minFrames { runs.append(s..<i) }
                start = nil
            }
        }
        if let s = start, range.upperBound + 1 - s >= minFrames { runs.append(s..<(range.upperBound + 1)) }
        return runs
    }

    private func distance(_ t: Double, _ run: Range<Int>, _ env: EnergyEnvelope) -> Double {
        let a = env.frameStart(run.lowerBound), b = env.frameStart(run.upperBound)
        return t < a ? a - t : (t > b ? t - b : 0)
    }

    private func quietestFrame(_ env: EnergyEnvelope, _ range: ClosedRange<Int>) -> Int {
        range.min { env.levelsDB[$0] < env.levelsDB[$1] } ?? range.lowerBound
    }
}

// MARK: - Formatting

/// "m:ss.ss" — precise enough to talk about cut points.
public func formatCutTime(_ seconds: Double) -> String {
    let s = max(0, seconds)
    let m = Int(s / 60)
    return String(format: "%d:%05.2f", m, s - Double(m) * 60)
}

private func formatMs(_ seconds: Double) -> String { "\(Int((seconds * 1000).rounded())) ms" }

private func formatShift(_ seconds: Double) -> String {
    seconds < 0 ? "\(formatMs(-seconds)) earlier" : "\(formatMs(seconds)) later"
}

private func formatDB(_ db: Float, signed: Bool = false) -> String {
    String(format: signed ? "%+.0f dB" : "%.0f dBFS", db)
}
