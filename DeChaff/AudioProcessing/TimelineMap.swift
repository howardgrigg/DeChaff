import Foundation
import AVFoundation

// MARK: - Timelines
//
// Three timelines exist in the pipeline, and every time value belongs to exactly one:
//
//   S — source seconds, i.e. position in the input file. trimIn/trimOut, the
//       playhead, transcript word timings and Chapter.timeSeconds all live here.
//   K — kept seconds, i.e. position in the audio that survives trim + exclusions.
//       The AU/copy pass materialises K, so every later pass (leveler, LUFS,
//       silence detection, MP3) reads audio already in K. SilenceSegment and
//       MusicSegment times are K.
//   O — output seconds, i.e. K minus the silence removed by silence shortening.
//       ID3 chapter frames are written in O.
//
// S → K is `sourceToKept` (below); K → O is `remapChapterTime` in SilenceProcessor.
// Composing the two in that order is the only correct way to place a chapter.

/// A span of audio that the user has cut out of the middle of the recording.
/// Times are source seconds (S).
struct ExcludedRange: Identifiable, Equatable {
    let id: UUID
    var startSeconds: Double
    var endSeconds: Double

    init(id: UUID = UUID(), startSeconds: Double, endSeconds: Double) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    var duration: Double { max(0, endSeconds - startSeconds) }
}

/// A contiguous span of source audio that survives trimming and exclusion.
struct KeptSpan: Equatable {
    let start: Double   // source seconds
    let end: Double     // source seconds

    var duration: Double { max(0, end - start) }
}

/// The spans of source audio that survive `trimIn`/`trimOut` and `excluding`.
///
/// This is the single place exclusions are normalised — sorted, merged where they
/// overlap or touch, clamped to the trim range, and dropped when empty. The UI and
/// the processing pipeline both route through it, so they can never disagree about
/// where a cut falls. Exclusions are clipped here rather than mutated on the model,
/// so undoing a trim drag brings back any exclusion the drag had hidden.
func keptRanges(trimIn: Double, trimOut: Double, excluding: [ExcludedRange]) -> [KeptSpan] {
    let lo = max(0, trimIn)
    let hi = max(lo, trimOut)
    guard hi > lo else { return [] }

    // Clip to the trim window, drop empties, sort, merge overlapping/touching.
    let clipped = excluding
        .map { (start: max(lo, $0.startSeconds), end: min(hi, $0.endSeconds)) }
        .filter { $0.end > $0.start }
        .sorted { $0.start < $1.start }

    var merged: [(start: Double, end: Double)] = []
    for span in clipped {
        if let last = merged.last, span.start <= last.end {
            merged[merged.count - 1].end = max(last.end, span.end)
        } else {
            merged.append(span)
        }
    }

    var kept: [KeptSpan] = []
    var cursor = lo
    for gap in merged {
        if gap.start > cursor { kept.append(KeptSpan(start: cursor, end: gap.start)) }
        cursor = max(cursor, gap.end)
    }
    if hi > cursor { kept.append(KeptSpan(start: cursor, end: hi)) }
    return kept
}

/// Total duration of the kept audio — the length of the K timeline.
func keptDuration(_ ranges: [KeptSpan]) -> Double {
    ranges.reduce(0) { $0 + $1.duration }
}

/// Maps a source time (S) to its position in the kept audio (K).
///
/// A time inside an excluded span has no kept counterpart, so it snaps forward to
/// the cut point — the same convention `remapChapterTime` uses for a chapter that
/// lands inside removed silence.
func sourceToKept(_ t: Double, keptRanges ranges: [KeptSpan]) -> Double {
    var elapsed = 0.0
    for span in ranges {
        if t < span.start { return elapsed }          // inside a cut (or before the trim)
        if t <= span.end  { return elapsed + (t - span.start) }
        elapsed += span.duration
    }
    return elapsed                                    // at or past the end
}

/// Maps a kept time (K) back to the source time (S) it came from.
func keptToSource(_ k: Double, keptRanges ranges: [KeptSpan]) -> Double {
    guard let first = ranges.first else { return 0 }
    if k <= 0 { return first.start }
    var elapsed = 0.0
    for span in ranges {
        if k < elapsed + span.duration { return span.start + (k - elapsed) }
        elapsed += span.duration
    }
    return ranges.last?.end ?? first.start
}

/// True when `t` falls inside a cut — i.e. it is within the trim range but not in
/// any kept span. Used to grey out chapters and transcript words the user has cut.
func isExcluded(_ t: Double, keptRanges ranges: [KeptSpan]) -> Bool {
    guard let first = ranges.first, let last = ranges.last else { return false }
    guard t >= first.start, t <= last.end else { return false }
    return !ranges.contains { t >= $0.start && t <= $0.end }
}

// MARK: - Frame ranges for the processing passes

/// The kept spans of `options` expressed as frame ranges in a file of `fileLength`
/// frames at `sampleRate`. Every pass that materialises the trim — `runAUPass`,
/// `copyPass`, `detectMusicSegments` — reads exactly these ranges, in order, so
/// their notions of the K timeline stay identical.
func keptFrameRanges(options: ProcessingOptions,
                     fileLength: AVAudioFramePosition,
                     sampleRate: Double) -> [(start: AVAudioFramePosition, end: AVAudioFramePosition)] {
    let fileDuration = Double(fileLength) / sampleRate
    let trimOut = options.trimOutSeconds > 0 ? min(options.trimOutSeconds, fileDuration) : fileDuration
    let spans = keptRanges(trimIn: options.trimInSeconds, trimOut: trimOut,
                           excluding: options.excludedRanges)
    return spans.compactMap { span in
        let s = max(0, min(AVAudioFramePosition(span.start * sampleRate), fileLength))
        let e = max(s, min(AVAudioFramePosition(span.end * sampleRate), fileLength))
        return e > s ? (start: s, end: e) : nil
    }
}
