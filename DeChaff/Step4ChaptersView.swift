import SwiftUI
import DeChaffCore

extension ContentView {

    // MARK: - Step 4: Chapters

    var step4View: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeader(
                title: "Add chapter markers",
                subtitle: "Navigate to key moments and tap + to drop a chapter marker."
            )

            waveformBlock(showChapters: true)
                .padding(.horizontal, 24)

            chapterPlaybackBar
                .padding(.horizontal, 24)
                .padding(.top, 10)

            chapterListView
                .padding(.horizontal, 24)
                .padding(.top, 10)

            Spacer()
        }
    }

    var chapterPlaybackBar: some View {
        HStack(spacing: 10) {
            playPauseButton
            playheadTimeLabel
            Spacer()
            Button { addChapterAtPlayhead() } label: {
                Label("Add Chapter", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(model.waveformSamples.isEmpty)
        }
    }

    var chapterListView: some View {
        Group {
            if model.chapters.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.indent").foregroundStyle(.quaternary)
                    Text("No chapters yet — navigate and tap + Add Chapter")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.chapters) { chapter in
                            ChapterRow(
                                chapter: chapterBinding(for: chapter),
                                // Rows show the listener's timeline, not the source
                                // file's — a chapter 4 min into a podcast reads 4:00
                                // however much pre-roll was trimmed or cut.
                                keptTime: sourceToKept(chapter.timeSeconds, keptRanges: model.keptSpans),
                                isExcluded: isExcluded(chapter.timeSeconds, keptRanges: model.keptSpans),
                                onCommitKeptTime: { newKept in
                                    guard let idx = model.chapters.firstIndex(where: { $0.id == chapter.id }) else { return }
                                    let oldTime = model.chapters[idx].timeSeconds
                                    model.chapters[idx].timeSeconds = keptToSource(newKept, keptRanges: model.keptSpans)
                                    model.chapters.sort { $0.timeSeconds < $1.timeSeconds }
                                    registerChapterMoveUndo(id: chapter.id, oldTime: oldTime)
                                }
                            ) {
                                let removed = chapter
                                withAnimation { model.chapters.removeAll { $0.id == chapter.id } }
                                registerChapterRemoveUndo(chapter: removed)
                            }
                            if chapter.id != model.chapters.last?.id {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                }
                .frame(maxHeight: 150)
            }
        }
    }

    func addChapterAtPlayhead() {
        let idx = model.chapters.count
        // Chapters are stored in source time so exclusions never disturb them.
        // First chapter defaults to the start of the kept audio, second to 2 min in
        // (measured on the listener's timeline), the rest to the playhead.
        let spans = model.keptSpans
        let sourceTime: Double
        switch idx {
        case 0: sourceTime = keptToSource(0, keptRanges: spans)
        case 1: sourceTime = keptToSource(120, keptRanges: spans)
        default: sourceTime = model.playback.playheadSeconds
        }
        let title: String
        switch idx {
        case 0: title = model.tagBibleReading.isEmpty ? "Bible Reading" : "Bible Reading: \(model.tagBibleReading)"
        case 1: title = model.tagSermonTitle.isEmpty   ? "Sermon"        : "Sermon: \(model.tagSermonTitle)"
        default: title = "Chapter \(idx + 1)"
        }
        let newChapter = Chapter(timeSeconds: sourceTime, title: title)
        withAnimation {
            model.chapters.append(newChapter)
            model.chapters.sort { $0.timeSeconds < $1.timeSeconds }
        }
        registerChapterAddUndo(chapter: newChapter)
    }

    func chapterBinding(for chapter: Chapter) -> Binding<Chapter> {
        Binding(
            get: {
                model.chapters.first(where: { $0.id == chapter.id }) ?? chapter
            },
            set: { newValue in
                if let idx = model.chapters.firstIndex(where: { $0.id == chapter.id }) {
                    model.chapters[idx] = newValue
                }
            }
        )
    }
}

// MARK: - Chapter Row

struct ChapterRow: View {
    @Binding var chapter: Chapter
    /// The chapter's position on the listener's timeline — what the row shows and
    /// what typed edits are interpreted as. `chapter.timeSeconds` stays source time.
    let keptTime: Double
    let isExcluded: Bool
    var onCommitKeptTime: (Double) -> Void
    var onDelete: () -> Void

    @State private var timeText = ""
    @FocusState private var timeFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("0:00", text: $timeText)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 56)
                .multilineTextAlignment(.center)
                .focused($timeFocused)
                .onAppear { timeText = formatChapterTime(keptTime) }
                .onChange(of: keptTime) { _ in
                    if !timeFocused { timeText = formatChapterTime(keptTime) }
                }
                .onSubmit { commitTime() }
                .onChange(of: timeFocused) { focused in if !focused { commitTime() } }

            TextField("Chapter title", text: $chapter.title)
                .font(.caption).textFieldStyle(.plain)

            if isExcluded {
                Image(systemName: "scissors")
                    .font(.caption2).foregroundStyle(.red.opacity(0.7))
                    .help("This chapter sits in an excluded section — it will move to the cut")
            }

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.6))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chapter: \(chapter.title.isEmpty ? "Untitled" : chapter.title)")
        .accessibilityValue("at \(formatChapterTime(keptTime))\(isExcluded ? ", inside an excluded section" : "")")
    }

    private func commitTime() {
        if let secs = parseChapterTime(timeText) {
            onCommitKeptTime(secs)
            timeText = formatChapterTime(secs)
        } else {
            timeText = formatChapterTime(keptTime)
        }
    }
}

func formatChapterTime(_ seconds: Double) -> String {
    let t = max(0, Int(seconds))
    let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

func parseChapterTime(_ text: String) -> Double? {
    let parts = text.trimmingCharacters(in: .whitespaces)
                    .split(separator: ":", omittingEmptySubsequences: false)
                    .compactMap { Int($0) }
    switch parts.count {
    case 1: return parts[0] >= 0 ? Double(parts[0]) : nil
    case 2: guard parts[0] >= 0, (0..<60).contains(parts[1]) else { return nil }
            return Double(parts[0] * 60 + parts[1])
    case 3: guard parts[0] >= 0, (0..<60).contains(parts[1]), (0..<60).contains(parts[2]) else { return nil }
            return Double(parts[0] * 3600 + parts[1] * 60 + parts[2])
    default: return nil
    }
}
