import SwiftUI
import CoreMedia
import DeChaffCore

extension ContentView {

    // MARK: - Step 2: Trim

    var step2View: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeader(
                title: "Trim your recording",
                subtitle: "Set the start and end of the audio you want to keep — and shift-drag to cut sections out of the middle."
            )

            // Tab switcher
            Picker("", selection: $trimTab) {
                Text("Waveform").tag(0)
                Text("Transcript").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            if trimTab == 0 {
                waveformBlock(showChapters: false)
                    .padding(.horizontal, 24)

                playbackControls(showSetInOut: true)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)

                exclusionListView
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
            } else {
                TranscriptTrimView(
                    model: model,
                    trimIn: $model.trimInSeconds,
                    trimOut: $model.trimOutSeconds,
                    onExclude: { start, end in
                        model.selectionStart = start
                        model.selectionEnd = end
                        excludeSelection()
                    }
                )
                .padding(.horizontal, 24)
                .frame(maxHeight: .infinity)
            }

            Spacer()
        }
        .onChange(of: trimTab) { _, newTab in
            if newTab == 1 { model.startTrimTranscription() }
        }
    }

    // MARK: - Excluded sections list

    @ViewBuilder
    var exclusionListView: some View {
        if !model.excludedRanges.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Excluded sections", systemImage: "scissors")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Output length \(formatPlaybackTime(model.keptDurationSeconds))")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.excludedRanges) { range in
                            ExclusionRow(
                                range: exclusionBinding(for: range),
                                onCommit: { oldStart, oldEnd in
                                    registerExclusionEditUndo(id: range.id, oldStart: oldStart, oldEnd: oldEnd)
                                    model.excludedRanges.sort { $0.startSeconds < $1.startSeconds }
                                },
                                onPlay: { model.seekPlayback(to: max(0, range.startSeconds - 3)) },
                                onDelete: {
                                    let removed = range
                                    withAnimation { model.excludedRanges.removeAll { $0.id == range.id } }
                                    registerExclusionRemoveUndo(range: removed)
                                }
                            )
                            if range.id != model.excludedRanges.last?.id {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                }
                .frame(maxHeight: 110)
            }
        }
    }

    func exclusionBinding(for range: ExcludedRange) -> Binding<ExcludedRange> {
        Binding(
            get: { model.excludedRanges.first(where: { $0.id == range.id }) ?? range },
            set: { newValue in
                if let idx = model.excludedRanges.firstIndex(where: { $0.id == range.id }) {
                    model.excludedRanges[idx] = newValue
                }
            }
        )
    }
}

// MARK: - ExclusionRow

struct ExclusionRow: View {
    @Binding var range: ExcludedRange
    /// Called with the pre-edit values so the caller can register undo.
    var onCommit: (Double, Double) -> Void
    var onPlay: () -> Void
    var onDelete: () -> Void

    @State private var startText = ""
    @State private var endText = ""
    @FocusState private var focusedField: Int?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "scissors").font(.caption2).foregroundStyle(.red.opacity(0.7))

            TextField("0:00", text: $startText)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 62).multilineTextAlignment(.center)
                .focused($focusedField, equals: 0)
                .onSubmit { commit() }

            Text("→").font(.caption2).foregroundStyle(.tertiary)

            TextField("0:00", text: $endText)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 62).multilineTextAlignment(.center)
                .focused($focusedField, equals: 1)
                .onSubmit { commit() }

            Text("(\(formatPlaybackTime(range.duration)))")
                .font(.caption).foregroundStyle(.secondary)

            Spacer()

            Button(action: onPlay) {
                Image(systemName: "play.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Play from just before this cut")

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .help("Restore this section")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .onAppear { syncText() }
        .onChange(of: range.startSeconds) { _ in if focusedField == nil { syncText() } }
        .onChange(of: range.endSeconds)   { _ in if focusedField == nil { syncText() } }
        .onChange(of: focusedField) { field in if field == nil { commit() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Excluded section")
        .accessibilityValue("\(formatPlaybackTime(range.startSeconds)) to \(formatPlaybackTime(range.endSeconds))")
    }

    private func syncText() {
        startText = formatChapterTime(range.startSeconds)
        endText   = formatChapterTime(range.endSeconds)
    }

    private func commit() {
        let oldStart = range.startSeconds, oldEnd = range.endSeconds
        let newStart = parseChapterTime(startText) ?? oldStart
        let newEnd   = parseChapterTime(endText)   ?? oldEnd
        // An inverted or empty range would silently cut nothing — clamp instead.
        guard newEnd > newStart else { syncText(); return }
        guard newStart != oldStart || newEnd != oldEnd else { syncText(); return }
        range.startSeconds = newStart
        range.endSeconds = newEnd
        syncText()
        onCommit(oldStart, oldEnd)
    }
}

// MARK: - TranscriptTrimView

struct TranscriptTrimView: View {
    @ObservedObject var model: ProcessingModel
    @Binding var trimIn: Double
    @Binding var trimOut: Double
    /// Cuts the given source-time span out of the middle of the recording.
    var onExclude: (Double, Double) -> Void

    @State private var startIdx: Int = -1
    @State private var endIdx:   Int = -1
    /// Cached sentence grouping — recomputing O(n) on every body evaluation is
    /// noticeable with ~10k words, and body runs on every tap and stream batch.
    @State private var sentences: [[Int]] = []
    /// Word indices falling in a trimmed-away or excluded span. Cached for the same
    /// reason as `sentences` — testing every word on each body pass is O(n·spans).
    @State private var cutWordIndices: Set<Int> = []

    private var words: [TranscriptWord] { model.trimWords }

    /// Group word indices into sentences, splitting after words that end with . ? !
    private func regroupSentences() {
        var result: [[Int]] = []
        var current: [Int] = []
        for i in words.indices {
            current.append(i)
            let last = words[i].text.last
            if last == "." || last == "?" || last == "!" {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        sentences = result
    }

    private func recomputeCutWords() {
        let spans = model.keptSpans
        guard let first = spans.first, let last = spans.last else { cutWordIndices = []; return }
        var cut = Set<Int>()
        for i in words.indices {
            let t = words[i].startTime
            if t < first.start || t > last.end || isExcluded(t, keptRanges: spans) { cut.insert(i) }
        }
        cutWordIndices = cut
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            selectionBar
            refinementNotes
            mainContent
        }
        .onAppear { regroupSentences(); recomputeCutWords(); syncIndicesFromTrimPoints() }
        .onChange(of: trimIn)      { _, _ in recomputeCutWords(); syncIndicesFromTrimPoints() }
        .onChange(of: trimOut)     { _, _ in recomputeCutWords(); syncIndicesFromTrimPoints() }
        .onChange(of: model.excludedRanges) { _, _ in recomputeCutWords() }
        .onChange(of: words.count) { _, _ in regroupSentences(); recomputeCutWords(); syncIndicesFromTrimPoints() }
        .onChange(of: model.isTrimTranscribing) { _, transcribing in
            // Final merge can replace words without changing the count
            if !transcribing { regroupSentences(); recomputeCutWords() }
        }
    }

    /// Map the current trimIn/trimOut values back to the first and last words they keep.
    /// Called when the waveform view changes trim points so the transcript selection stays in sync.
    /// Cuts refined into silence sit just outside their words, so "kept" (not "nearest")
    /// is what keeps the selection on the words the user tapped.
    private func syncIndicesFromTrimPoints() {
        guard !words.isEmpty else { return }
        let tolerance = 0.001
        startIdx = words.firstIndex { $0.startTime >= trimIn - tolerance }
            ?? words.indices.min { abs(words[$0].startTime - trimIn) < abs(words[$1].startTime - trimIn) }!
        endIdx = words.lastIndex { $0.endTime <= trimOut + tolerance }
            ?? words.indices.min { abs(words[$0].endTime - trimOut) < abs(words[$1].endTime - trimOut) }!
        // Ensure ordering
        if startIdx > endIdx { swap(&startIdx, &endIdx) }
    }

    // MARK: Selection bar

    @ViewBuilder
    private var selectionBar: some View {
        HStack(spacing: 10) {
            if startIdx < 0 {
                Image(systemName: "hand.tap").foregroundStyle(.secondary)
                Text("Tap a word to mark the start of your selection.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            } else if endIdx < 0 {
                Image(systemName: "1.circle.fill").foregroundStyle(.orange)
                Text("Start: \(formatTime(words[startIdx].startTime))")
                    .font(.system(size: 13, weight: .medium))
                Text("— now tap a word to mark the end.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { startIdx = -1 }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                Image(systemName: "text.insert").foregroundStyle(.orange)
                Text("\(formatTime(words[startIdx].startTime)) → \(formatTime(words[endIdx].endTime))")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Keep Only This") { applyTrim() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .help("Trim the recording to this passage")
                Button {
                    onExclude(words[startIdx].startTime, words[endIdx].endTime)
                    startIdx = -1; endIdx = -1
                } label: {
                    Label("Exclude", systemImage: "scissors")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Cut this passage out and keep the rest")
                Button("Clear") { startIdx = -1; endIdx = -1 }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .animation(.easeInOut(duration: 0.15), value: startIdx >= 0)
        .animation(.easeInOut(duration: 0.15), value: endIdx >= 0)
    }

    /// Shown when a cut couldn't land in clean silence (words run together), so the
    /// user knows to check that edge by ear.
    @ViewBuilder
    private var refinementNotes: some View {
        if !model.trimRefinementNotes.isEmpty && endIdx >= 0 {
            Label(model.trimRefinementNotes.joined(separator: " "), systemImage: "waveform.badge.exclamationmark")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Main content

    @ViewBuilder
    private var mainContent: some View {
        if model.isTrimTranscribing && model.trimWords.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                let pct = Int(model.trimTranscriptProgress * 100)
                Text(pct > 0 ? "Transcribing… \(pct)%" : "Transcribing…")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                ProgressView(value: model.trimTranscriptProgress)
                    .progressViewStyle(.linear)
                    .animation(.linear(duration: 0.3), value: model.trimTranscriptProgress)
            }
            .padding(.top, 8)
        } else if let error = model.trimTranscriptError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .padding(.top, 8)
        } else if model.trimWords.isEmpty {
            Text("No transcript available.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .padding(.top, 8)
        } else {
            wordList
        }
    }

    // MARK: Word list — sentence-per-line with lazy loading

    private var wordList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(sentences.enumerated()), id: \.offset) { _, indices in
                    SentenceRow(words: words, indices: indices,
                                startIdx: startIdx, endIdx: endIdx,
                                cutIndices: cutWordIndices,
                                onTap: handleTap)
                }

                if model.isTrimTranscribing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Transcribing…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: Tap handling

    private func handleTap(_ idx: Int) {
        if startIdx < 0 {
            // Nothing selected — set start
            startIdx = idx
        } else if endIdx < 0 {
            // Start set, no end yet
            if idx == startIdx {
                startIdx = -1                      // tap start again → clear
            } else if idx < startIdx {
                endIdx = startIdx; startIdx = idx  // tapped before start → swap
            } else {
                endIdx = idx
            }
        } else {
            // Both set — start fresh from this word
            startIdx = idx; endIdx = -1
        }
    }

    /// A completed selection offers both actions, so neither is applied until the
    /// user picks one — trimming on the second tap would pre-empt Exclude.
    private func applyTrim() {
        guard startIdx >= 0, endIdx >= 0 else { return }
        // Sets the transcript timings, then snaps both cuts into silence in the background.
        model.applyTranscriptTrim(startWord: startIdx, endWord: endIdx)
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - SentenceRow

/// One sentence rendered as a wrapping row of word chips.
/// Extracted so LazyVStack can instantiate only the visible rows.
private struct SentenceRow: View {
    let words: [TranscriptWord]
    let indices: [Int]
    let startIdx: Int
    let endIdx: Int
    let cutIndices: Set<Int>
    let onTap: (Int) -> Void

    var body: some View {
        WordFlowLayout(spacing: 2) {
            ForEach(indices, id: \.self) { idx in
                WordChip(text: words[idx].text, state: chipState(idx),
                         isCut: cutIndices.contains(idx), onTap: { onTap(idx) })
            }
        }
    }

    private func chipState(_ idx: Int) -> WordChipState {
        guard startIdx >= 0 else { return .none }
        let lo = min(startIdx, endIdx < 0 ? startIdx : endIdx)
        let hi = max(startIdx, endIdx < 0 ? startIdx : endIdx)
        if idx == lo { return endIdx >= 0 ? .start : .start }
        if idx == hi && endIdx >= 0 { return .end }
        if idx > lo && idx < hi { return .inRange }
        return .none
    }
}

// MARK: - WordChip

private enum WordChipState { case none, start, inRange, end }

private struct WordChip: View {
    let text: String
    let state: WordChipState
    let isCut: Bool
    let onTap: () -> Void

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .strikethrough(isCut, color: .red.opacity(0.5))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(bgColor, in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(isCut ? Color.secondary.opacity(0.5)
                             : state == .none ? Color.secondary : Color.primary)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .animation(.easeInOut(duration: 0.08), value: state == .none)
    }

    private var bgColor: Color {
        switch state {
        case .none:    return .clear
        case .inRange: return Color.orange.opacity(0.15)
        case .start:   return Color.orange.opacity(0.45)
        case .end:     return Color.orange.opacity(0.45)
        }
    }
}

// MARK: - WordFlowLayout

/// Left-to-right wrapping layout (CSS flex-wrap equivalent).
private struct WordFlowLayout: Layout {
    var spacing: CGFloat = 2

    struct CacheData { var sizes: [CGSize] }

    func makeCache(subviews: Subviews) -> CacheData {
        CacheData(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) -> CGSize {
        let maxW = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for size in cache.sizes {
            if x + size.width > maxW, x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            x += size.width + spacing; rowH = max(rowH, size.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for (subview, size) in zip(subviews, cache.sizes) {
            if x + size.width > bounds.maxX, x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowH = max(rowH, size.height)
        }
    }
}
