import SwiftUI
import CoreMedia

extension ContentView {

    // MARK: - Step 2: Trim

    var step2View: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeader(
                title: "Trim your recording",
                subtitle: "Set the start and end of the audio you want to keep."
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
            } else {
                TranscriptTrimView(
                    model: model,
                    trimIn: $model.trimInSeconds,
                    trimOut: $model.trimOutSeconds
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
}

// MARK: - TranscriptTrimView

struct TranscriptTrimView: View {
    @ObservedObject var model: ProcessingModel
    @Binding var trimIn: Double
    @Binding var trimOut: Double

    @State private var startIdx: Int = -1
    @State private var endIdx:   Int = -1

    private var words: [TranscriptWord] { model.trimWords }

    /// Group word indices into sentences, splitting after words that end with . ? !
    private var sentences: [[Int]] {
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
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            selectionBar
            mainContent
        }
        .onAppear { syncIndicesFromTrimPoints() }
        .onChange(of: trimIn)      { _, _ in syncIndicesFromTrimPoints() }
        .onChange(of: trimOut)     { _, _ in syncIndicesFromTrimPoints() }
        .onChange(of: words.count) { _, _ in syncIndicesFromTrimPoints() }
    }

    /// Map the current trimIn/trimOut values back to the nearest word indices.
    /// Called when the waveform view changes trim points so the transcript selection stays in sync.
    private func syncIndicesFromTrimPoints() {
        guard !words.isEmpty else { return }
        // Only sync if trim points differ from what the current selection already represents
        let currentIn  = startIdx >= 0 ? words[startIdx].startTime : -1
        let currentOut = endIdx   >= 0 ? words[endIdx].endTime     : -1
        guard trimIn != currentIn || trimOut != currentOut else { return }

        if let idx = words.indices.min(by: { abs(words[$0].startTime - trimIn)  < abs(words[$1].startTime - trimIn)  }) { startIdx = idx }
        if let idx = words.indices.min(by: { abs(words[$0].endTime   - trimOut) < abs(words[$1].endTime   - trimOut) }) { endIdx   = idx }
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
                Image(systemName: "scissors").foregroundStyle(.orange)
                Text("Keeping \(formatTime(words[startIdx].startTime)) → \(formatTime(words[endIdx].endTime))")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
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
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(sentences.enumerated()), id: \.offset) { _, indices in
                    SentenceRow(words: words, indices: indices,
                                startIdx: startIdx, endIdx: endIdx,
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
                apply()
            } else {
                endIdx = idx
                apply()
            }
        } else {
            // Both set — start fresh from this word
            startIdx = idx; endIdx = -1
        }
    }

    private func apply() {
        guard startIdx >= 0, endIdx >= 0 else { return }
        trimIn  = words[startIdx].startTime
        trimOut = words[endIdx].endTime
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
    let onTap: (Int) -> Void

    var body: some View {
        WordFlowLayout(spacing: 2) {
            ForEach(indices, id: \.self) { idx in
                WordChip(text: words[idx].text, state: chipState(idx), onTap: { onTap(idx) })
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
    let onTap: () -> Void

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(bgColor, in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(state == .none ? Color.secondary : Color.primary)
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
