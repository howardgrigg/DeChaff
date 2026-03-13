import SwiftUI
import UniformTypeIdentifiers
import AppKit

@MainActor
class ProcessingModel: ObservableObject {
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var logs: [String] = []
    @Published var outputURL: URL?
    @Published var isDone = false

    // Processing options — all on by default
    @Published var doIsolation   = true
    @Published var doCompression = true
    @Published var doNormalization = true
    @Published var monoOutput    = true
    @Published var targetLUFS: Double = -16.0
    @Published var outputFormat: OutputFormat = .mp3
    @Published var mp3Bitrate: Int = 64
    @Published var chapters: [Chapter] = []
    @Published var tagSermonTitle = ""
    @Published var tagBibleReading = ""
    @Published var tagPreacher = ""
    @Published var tagSeries   = ""
    @Published var tagYear     = ""
    @Published var tagArtwork: Data? = nil

    func processFile(url: URL) {
        guard !isProcessing else { return }

        let inputPath = url.path
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension
        let dir = url.deletingLastPathComponent().path
        let outputPath = "\(dir)/\(baseName)_dechaff.\(outputFormat.fileExtension)"

        isProcessing = true
        isDone = false
        progress = 0
        logs = ["Input: \(url.lastPathComponent)"]
        outputURL = URL(fileURLWithPath: outputPath)

        let options = ProcessingOptions(
            voiceIsolation: doIsolation,
            compression:    doCompression,
            normalization:  doNormalization,
            monoOutput:     monoOutput,
            targetLUFS:     targetLUFS,
            outputFormat:   outputFormat,
            mp3Bitrate:     mp3Bitrate
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let processor = VoiceIsolationProcessor()
            let success = processor.process(
                inputPath: inputPath,
                outputPath: outputPath,
                options: options,
                progressHandler: { p in DispatchQueue.main.async { self?.progress = p } },
                logHandler:      { m in DispatchQueue.main.async { self?.logs.append(m) } }
            )
            DispatchQueue.main.async {
                self?.isProcessing = false
                self?.isDone = success
                if !success { self?.outputURL = nil }
            }
        }
    }

    func saveTags() {
        guard let url = outputURL, isDone, !isProcessing else { return }
        let path      = url.path
        let chapters  = self.chapters
        let titleParts = [tagSermonTitle, tagBibleReading].filter { !$0.isEmpty }
        let combinedTitle = titleParts.joined(separator: ", ")
        let metadata  = ID3Metadata(title: combinedTitle, artist: tagPreacher,
                                    album: tagSeries, year: tagYear, artwork: tagArtwork)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let processor = VoiceIsolationProcessor()
            processor.writeTags(chapters: chapters, metadata: metadata, to: path) { msg in
                DispatchQueue.main.async { self?.logs.append(msg) }
            }
        }
    }
}

private enum PanelTab { case info, chapters }

struct ContentView: View {
    @StateObject private var model = ProcessingModel()
    @State private var isTargeted = false
    @State private var panelTab: PanelTab = .info
    @State private var isArtworkTargeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                headerView
                    .padding(.bottom, 20)

                dropZoneView
                    .padding(.bottom, 16)

                optionsView
                    .padding(.bottom, 16)

                if !model.logs.isEmpty {
                    logView
                        .padding(.bottom, 12)
                }

                if model.isDone, let url = model.outputURL {
                    actionView(url: url)
                }
            }
            .padding(28)
            .frame(width: 480)

            Divider()
            chaptersPanel
        }
    }

    private var headerView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.purple)
                Text("DeChaff")
                    .font(.system(size: 26, weight: .semibold))
            }
            Text("Remove background noise using Apple's built-in Voice Isolation engine")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var dropZoneView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: isTargeted ? [] : [8, 5])
                )
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isTargeted
                              ? Color.accentColor.opacity(0.07)
                              : Color.secondary.opacity(0.03))
                )
                .animation(.easeInOut(duration: 0.15), value: isTargeted)

            if model.isProcessing {
                processingOverlay
            } else if model.isDone {
                doneOverlay
            } else {
                idleOverlay
            }
        }
        .frame(height: 210)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            loadDroppedFile(from: providers)
        }
    }

    private var processingOverlay: some View {
        VStack(spacing: 16) {
            Text("Processing…")
                .font(.headline)
                .foregroundStyle(.secondary)
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .frame(width: 300)
            Text("\(Int(model.progress * 100))%")
                .font(.system(.subheadline, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var doneOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Done!")
                .font(.headline)
            Text("Drop another file to process again")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var idleOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            Text("Drop audio file here")
                .font(.headline)
                .foregroundStyle(isTargeted ? Color.accentColor : Color.primary)
            Text("WAV · MP3 · M4A · AIFF · FLAC · CAF")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
                .frame(width: 48)
                .padding(.vertical, 2)
            Button("Choose File…") {
                openFilePicker()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Voice Isolation",     isOn: $model.doIsolation)
            Toggle("Dynamic Compression", isOn: $model.doCompression)
            HStack(spacing: 10) {
                Toggle("Loudness Normalization", isOn: $model.doNormalization)
                if model.doNormalization {
                    Spacer()
                    Text(String(format: "%.0f LUFS", model.targetLUFS))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Slider(value: $model.targetLUFS, in: -32 ... -6, step: 0.5)
                        .frame(width: 100)
                        .controlSize(.small)
                }
            }
            Toggle("Mono output (voice channel only)", isOn: $model.monoOutput)

            Divider()

            HStack(spacing: 12) {
                Text("MP3 bitrate")
                    .font(.callout)
                Spacer()
                Picker("", selection: $model.mp3Bitrate) {
                    ForEach([64, 96, 128, 192, 256], id: \.self) { br in
                        Text("\(br) kbps").tag(br)
                    }
                }
                .frame(width: 90)
                .controlSize(.small)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(model.isProcessing)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.logs.enumerated()), id: \.offset) { index, message in
                        Text(message)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 90)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .onChange(of: model.logs.count) { newCount in
                if newCount > 0 {
                    withAnimation { proxy.scrollTo(newCount - 1) }
                }
            }
        }
    }

    private func actionView(url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.checkmark")
                .foregroundStyle(.green)
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
        )
    }

    private var chaptersPanel: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 8) {
                Picker("", selection: $panelTab) {
                    Text("Info").tag(PanelTab.info)
                    Text("Chapters").tag(PanelTab.chapters)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if panelTab == .chapters {
                    Button {
                        withAnimation {
                            let nextTime = model.chapters.last.map { $0.timeSeconds + 60 } ?? 0
                            model.chapters.append(
                                Chapter(timeSeconds: nextTime,
                                        title: "Chapter \(model.chapters.count + 1)"))
                        }
                    } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add chapter")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Tab content
            switch panelTab {
            case .info:     infoTabView
            case .chapters: chaptersTabView
            }

            // Save button
            if model.isDone, model.outputURL != nil {
                Divider()
                Button(action: { model.saveTags() }) {
                    Label("Save Tags to MP3", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isProcessing)
                .padding(12)
            }
        }
        .frame(width: 260)
    }

    private var infoTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                artworkDropZone
                tagField("Sermon Title",  $model.tagSermonTitle)
                tagField("Bible Reading", $model.tagBibleReading)
                tagField("Preacher",      $model.tagPreacher)
                tagField("Series",        $model.tagSeries)
                tagField("Year",   Binding(
                    get: { model.tagYear },
                    set: { model.tagYear = String($0.filter(\.isNumber).prefix(4)) }
                ))
            }
            .padding(12)
        }
    }

    private var chaptersTabView: some View {
        Group {
            if model.chapters.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No chapters yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Tap + to add chapter markers")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.chapters) { chapter in
                            ChapterRow(chapter: chapterBinding(for: chapter)) {
                                withAnimation { model.chapters.removeAll { $0.id == chapter.id } }
                            }
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tagField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
    }

    private var artworkDropZone: some View {
        ZStack {
            if let data = model.tagArtwork, let nsImg = NSImage(data: data) {
                Image(nsImage: nsImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack {
                    HStack {
                        Spacer()
                        Button { model.tagArtwork = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                        }
                        .buttonStyle(.borderless)
                        .padding(6)
                    }
                    Spacer()
                }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isArtworkTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: isArtworkTargeted ? 2 : 1,
                                           dash: isArtworkTargeted ? [] : [5, 3]))
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(isArtworkTargeted
                              ? Color.accentColor.opacity(0.07)
                              : Color.secondary.opacity(0.04)))
                    .animation(.easeInOut(duration: 0.15), value: isArtworkTargeted)
                VStack(spacing: 6) {
                    Image(systemName: isArtworkTargeted ? "photo.fill" : "photo.badge.plus")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(isArtworkTargeted ? Color.accentColor : Color.secondary)
                    Text("Drop image or click to browse")
                        .font(.caption2)
                        .foregroundStyle(isArtworkTargeted ? Color.accentColor : Color.secondary)
                        .multilineTextAlignment(.center)
                }
                .allowsHitTesting(false)  // let taps pass through to onTapGesture
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture { if model.tagArtwork == nil { openArtworkPicker() } }
        .onDrop(of: [UTType.fileURL], isTargeted: $isArtworkTargeted) { providers in
            loadArtwork(from: providers)
        }
    }

    private func openArtworkPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose album artwork"
        if panel.runModal() == .OK, let url = panel.url {
            DispatchQueue.main.async { self.loadArtworkFromURL(url) }
        }
    }

    private func loadArtwork(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            guard let url else { return }
            DispatchQueue.main.async { self.loadArtworkFromURL(url) }
        }
        return true
    }

    private func loadArtworkFromURL(_ url: URL) {
        guard let nsImage = NSImage(contentsOf: url),
              let tiff   = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg   = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return }
        model.tagArtwork = jpeg
    }

    private func chapterBinding(for chapter: Chapter) -> Binding<Chapter> {
        guard let idx = model.chapters.firstIndex(where: { $0.id == chapter.id }) else {
            fatalError("Chapter not found in model")
        }
        return $model.chapters[idx]
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an audio file to process"
        if panel.runModal() == .OK, let url = panel.url {
            DispatchQueue.main.async { self.model.processFile(url: url) }
        }
    }

    private func loadDroppedFile(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let u = item as? URL {
                url = u
            }
            guard let url = url else { return }
            DispatchQueue.main.async { self.model.processFile(url: url) }
        }
        return true
    }
}

#Preview {
    ContentView()
}

private struct ChapterRow: View {
    @Binding var chapter: Chapter
    var onDelete: () -> Void

    @State private var timeText = ""
    @FocusState private var timeFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("0:00", text: $timeText)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 56)
                .multilineTextAlignment(.center)
                .focused($timeFocused)
                .onAppear { timeText = formatChapterTime(chapter.timeSeconds) }
                .onSubmit { commitTime() }
                .onChange(of: timeFocused) { focused in
                    if !focused { commitTime() }
                }

            TextField("Chapter title", text: $chapter.title)
                .font(.caption)
                .textFieldStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red.opacity(0.6))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func commitTime() {
        if let secs = parseChapterTime(timeText) {
            chapter.timeSeconds = secs
            timeText = formatChapterTime(secs)
        } else {
            timeText = formatChapterTime(chapter.timeSeconds)
        }
    }
}

private func formatChapterTime(_ seconds: Double) -> String {
    let t = max(0, Int(seconds))
    let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

private func parseChapterTime(_ text: String) -> Double? {
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
