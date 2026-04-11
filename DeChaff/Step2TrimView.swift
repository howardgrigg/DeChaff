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

    @State private var selectionStart: Int = -1
    @State private var selectionEnd:   Int = -1
    @State private var isDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            selectionBar
            mainContent
        }
    }

    // MARK: Selection summary bar

    @ViewBuilder
    private var selectionBar: some View {
        HStack(spacing: 10) {
            if hasSelection {
                let lo = min(selectionStart, selectionEnd)
                let hi = max(selectionStart, selectionEnd)
                let words = model.trimWords
                let startSec = words[lo].startTime
                let endSec   = words[hi].endTime
                Image(systemName: "scissors").foregroundStyle(.orange)
                Text("Keep \(formatTime(startSec)) → \(formatTime(endSec))")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Apply") { trimIn = startSec; trimOut = endSec }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Clear") { clearSelection() }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                Image(systemName: "hand.tap").foregroundStyle(.secondary)
                Text("Click or drag words to select the region you want to keep.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .animation(.easeInOut(duration: 0.15), value: hasSelection)
    }

    // MARK: Main content

    @ViewBuilder
    private var mainContent: some View {
        if model.isTrimTranscribing && model.trimWords.isEmpty {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            wordFlow
        }
    }

    // MARK: Word flow

    private var wordFlow: some View {
        ScrollView {
            WordFlowLayout(spacing: 4) {
                ForEach(Array(model.trimWords.enumerated()), id: \.offset) { index, word in
                    WordChip(word: word, isSelected: isSelected(index), onTap: { handleTap(index: index) })
                        .gesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { _ in
                                    if !isDragging {
                                        isDragging = true
                                        selectionStart = index
                                    }
                                    if index != selectionEnd { selectionEnd = index }
                                }
                                .onEnded { _ in isDragging = false }
                        )
                }
            }
            .padding(.vertical, 4)

            if model.isTrimTranscribing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Transcribing…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
        .frame(maxHeight: 340)
    }

    // MARK: Helpers

    private var hasSelection: Bool { selectionStart >= 0 && selectionEnd >= 0 }

    private func isSelected(_ index: Int) -> Bool {
        guard hasSelection else { return false }
        let lo = min(selectionStart, selectionEnd)
        let hi = max(selectionStart, selectionEnd)
        return index >= lo && index <= hi
    }

    private func handleTap(index: Int) {
        if !hasSelection || (selectionStart == selectionEnd && selectionStart == index) {
            if selectionStart == index { clearSelection() } else { selectionStart = index; selectionEnd = index }
        } else {
            selectionStart = index; selectionEnd = index
        }
    }

    private func clearSelection() { selectionStart = -1; selectionEnd = -1 }

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - WordChip

private struct WordChip: View {
    let word: TranscriptWord
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Text(word.text)
            .font(.system(size: 13))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isSelected ? Color.orange.opacity(0.2) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .animation(.easeInOut(duration: 0.1), value: isSelected)
    }
}

// MARK: - WordFlowLayout

/// Left-to-right wrapping layout (CSS flex-wrap equivalent).
private struct WordFlowLayout: Layout {
    var spacing: CGFloat = 4

    struct CacheData {
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> CacheData {
        CacheData(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) -> CGSize {
        let maxWidth = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0

        for size in cache.sizes {
            if x + size.width > maxWidth, x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0

        for (subview, size) in zip(subviews, cache.sizes) {
            if x + size.width > bounds.maxX, x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
