import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - ContentView

struct ContentView: View {
    @StateObject var model = ProcessingModel()
    @EnvironmentObject var ytManager: YtDlpManager
    @StateObject var youtube = YouTubeViewModel()
    @State var currentStep = 0
    @State var isTargeted = false
    @State var isArtworkTargeted = false
    @State private var scrollMonitor: Any?
    @State private var clickMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var showLog = false
    @AppStorage("dechaff.youtube.channelURL") var ytChannelURL = "https://www.youtube.com/@cityonahillnz"
    @AppStorage("dechaff.youtube.videoLimit") var ytVideoLimit = 10
    @State var ytTab: Int = 2   // 0 = YouTube URL, 1 = Videos, 2 = Live Streams
    @State var trimTab: Int = 0  // 0 = Waveform, 1 = Transcript
    @State var ytDirectURL: String = ""
    @Environment(\.undoManager) var undoManager

    let stepTitles = ["Load", "Trim", "Info", "Chapters", "Output"]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                appHeader
                if !model.isProcessing && !model.isDone {
                    stepIndicator
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider()

            ZStack {
                if model.isProcessing {
                    processingView.transition(.opacity)
                } else if model.isDone {
                    doneView.transition(.opacity)
                } else {
                    stepContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: model.isProcessing)
            .animation(.easeInOut(duration: 0.2), value: model.isDone)

            if !model.isProcessing && !model.isDone {
                Divider()
                navigationFooter
                    .padding(.horizontal, 36)
                    .padding(.vertical, 16)
            }
        }
        .frame(width: 760)
        .frame(minHeight: 520)
        .focusedSceneValue(\.processingModel, model)
        .focusedSceneValue(\.currentStep, $currentStep)
        .focusedSceneValue(\.appActions, AppActions(
            openFile: { openFilePicker() },
            addChapter: { addChapterAtPlayhead() },
            startProcessing: { startProcessing() }
        ))
        .focusedSceneValue(\.windowUndoManager, undoManager)
        .onAppear {
            setupMonitors()
            Task { await ytManager.checkAndUpdate() }
        }
        .onDisappear { teardownMonitors() }
        .onReceive(NotificationCenter.default.publisher(for: .openAudioFile)) { notif in
            guard let url = notif.object as? URL else { return }
            model.loadFile(url: url)
            withAnimation { currentStep = 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadFromURL)) { notif in
            guard let rawURL = notif.object as? String else { return }
            withAnimation { currentStep = 0 }
            ytTab = 0
            ytDirectURL = rawURL
            youtube.selectURL(rawURL, manager: ytManager) { fileURL in
                model.loadFile(url: fileURL)
                ytDirectURL = ""
                withAnimation { currentStep = 1 }
            }
        }
    }

    // MARK: - App Header

    private var appHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            if let img = NSImage(named: "Wheat") {
                Image(nsImage: img).resizable().scaledToFit().frame(width: 22, height: 22)
            }
            Text("DeChaff").font(.system(size: 17, weight: .semibold))
            Spacer()
            if let url = model.inputURL {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").foregroundStyle(.secondary).font(.caption)
                    Text(url.lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(0..<stepTitles.count, id: \.self) { step in
                HStack(spacing: 0) {
                    stepDot(step: step)
                    if step < stepTitles.count - 1 {
                        Rectangle()
                            .fill(step < currentStep ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2))
                            .frame(height: 1.5)
                            .frame(maxWidth: .infinity)
                            .animation(.easeInOut(duration: 0.25), value: currentStep)
                    }
                }
            }
        }
    }

    private func stepDot(step: Int) -> some View {
        let isCompleted = step < currentStep
        let isCurrent   = step == currentStep
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(isCompleted ? Color.accentColor
                          : isCurrent  ? Color.accentColor.opacity(0.12)
                          : Color.secondary.opacity(0.1))
                    .frame(width: 30, height: 30)
                    .animation(.easeInOut(duration: 0.25), value: currentStep)
                if isCompleted {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(step + 1)")
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                }
            }
            Text(stepTitles[step])
                .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .animation(.easeInOut(duration: 0.25), value: currentStep)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step + 1): \(stepTitles[step])")
        .accessibilityValue(isCompleted ? "completed" : isCurrent ? "current" : "upcoming")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    // MARK: - Navigation Footer

    private var navigationFooter: some View {
        HStack {
            if currentStep > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { currentStep -= 1 }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("Back")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Spacer()
            if currentStep < stepTitles.count - 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { currentStep += 1 }
                } label: {
                    HStack(spacing: 4) {
                        Text("Next")
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canAdvance)
            } else {
                Button { startProcessing() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.badge.sparkles")
                        Text("Process").fontWeight(.semibold)
                    }
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isProcessing || model.isLoadingWaveform)
            }
        }
    }

    private var canAdvance: Bool {
        switch currentStep {
        case 0: return model.inputURL != nil && !model.isLoadingWaveform
        default: return true
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        ZStack {
            if currentStep == 0 { step1View.transition(.opacity) }
            if currentStep == 1 { step2View.transition(.opacity) }
            if currentStep == 2 { step3View.transition(.opacity) }
            if currentStep == 3 { step4View.transition(.opacity) }
            if currentStep == 4 { step5View.transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.18), value: currentStep)
        .onChange(of: currentStep) { newStep in
            if newStep != 1 && newStep != 3 { model.pausePlayback() }
            if newStep == 1 { model.startTrimTranscription() }  // begin in background; ready if user opens Transcript tab
            if newStep == 3, model.inputDuration > 0 {
                // Scroll waveform to the trim-in point when entering chapters step
                let visibleDuration = model.inputDuration / model.waveformZoom
                model.waveformVisibleStart = max(0, min(model.trimInSeconds, model.inputDuration - visibleDuration))
            }
        }
    }

    // MARK: - Processing View

    private var processingView: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 6) {
                Text(model.processingStageLabel)
                    .font(.title3.weight(.medium))
                    .animation(.default, value: model.processingStageLabel)
                Text("This may take a few minutes for long recordings")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(width: 380)
                Text("\(Int(model.progress * 100))%")
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !model.logs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Button { withAnimation { showLog.toggle() } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showLog ? "chevron.down" : "chevron.right").font(.caption2)
                            Text("Show details").font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    if showLog {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(Array(model.logs.enumerated()), id: \.offset) { idx, msg in
                                        Text(msg)
                                            .font(.system(.caption2, design: .monospaced))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .id(idx)
                                    }
                                }
                                .padding(10)
                            }
                            .frame(width: 380, height: 80)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .onChange(of: model.logs.count) { count in
                                if count > 0 { withAnimation { proxy.scrollTo(count - 1) } }
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Processing audio")
        .accessibilityValue("\(Int(model.progress * 100)) percent, \(model.processingStageLabel)")
    }

    // MARK: - Done View

    private var doneView: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 52)).foregroundStyle(.green)
                    Text("Done!").font(.title2.weight(.semibold))
                    if let url = model.outputURL {
                        Text(url.lastPathComponent)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 48)
                            .draggable(url)
                            .help("Drag to export the file")
                    }
                }
                .padding(.top, 28)

                HStack(spacing: 12) {
                    if let url = model.outputURL {
                        Button {
                            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                        } label: { Label("Reveal in Finder", systemImage: "folder") }
                        .buttonStyle(.borderedProminent).controlSize(.large)

                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                    }
                    Button("Process Another") {
                        model.isDone = false; model.outputURL = nil
                        withAnimation { currentStep = 0 }
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }

                if model.doTranscription {
                    Divider().padding(.horizontal, 36)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center) {
                            Text("Transcript").font(.headline)
                            Spacer()
                            if !model.transcriptText.isEmpty && model.transcriptError == nil {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green).font(.caption)
                                    Text("Done").font(.caption).foregroundStyle(.secondary)
                                }
                            } else if model.isTranscribing {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.65)
                                    Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if !model.transcriptText.isEmpty {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(model.transcriptText, forType: .string)
                                } label: { Label("Copy", systemImage: "doc.on.doc") }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        if let error = model.transcriptError {
                            Text(error).font(.subheadline).foregroundStyle(.red)
                        } else if model.transcriptText.isEmpty {
                            Text(model.isTranscribing ? "Generating transcript…" : "No transcript available.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                Text(model.transcriptText)
                                    .textSelection(.enabled).font(.subheadline)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            }
                            .frame(maxHeight: 180)
                            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 36)
                }

                if model.aiAssistantEnabled {
                    Divider().padding(.horizontal, 36)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center) {
                            Text("AI Assistant").font(.headline)
                            Spacer()
                            if !model.aiAssistantResponse.isEmpty && model.aiAssistantError == nil {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green).font(.caption)
                                    Text("Done").font(.caption).foregroundStyle(.secondary)
                                }
                            } else if model.isAIAssistantLoading {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.65)
                                    Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if !model.aiAssistantResponse.isEmpty {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(model.aiAssistantResponse, forType: .string)
                                } label: { Label("Copy", systemImage: "doc.on.doc") }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                            if !model.isAIAssistantLoading {
                                Button {
                                    model.startAIAssistant()
                                } label: { Label("Retry", systemImage: "arrow.clockwise") }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(model.transcriptText.isEmpty)
                            }
                        }
                        if let error = model.aiAssistantError {
                            Text(error).font(.subheadline).foregroundStyle(.red)
                        } else if model.aiAssistantResponse.isEmpty {
                            if model.isAIAssistantLoading {
                                Text("Sending transcript to Claude…")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            } else if model.transcriptText.isEmpty {
                                Text("Waiting for transcript…")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                Text("Click Retry to send transcript to Claude.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        } else {
                            ScrollView {
                                Text(model.aiAssistantResponse)
                                    .textSelection(.enabled).font(.subheadline)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            }
                            .frame(maxHeight: 300)
                            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 36)
                }
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shared view helpers (used by multiple steps)

    func waveformBlock(showChapters: Bool) -> some View {
        Group {
            if model.isLoadingWaveform {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.75)
                    Text("Loading waveform…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.waveformSamples.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform").font(.system(size: 30, weight: .light)).foregroundStyle(.quaternary)
                    Text("Load a file first").font(.caption).foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let data = model.waveformData {
                WaveformView(
                    waveformData: data,
                    duration: model.inputDuration,
                    trimIn: $model.trimInSeconds,
                    trimOut: $model.trimOutSeconds,
                    playhead: model.playback.playheadSeconds,
                    chapters: showChapters ? model.chapters : [],
                    trimInOffset: model.trimInSeconds,
                    onSeek: { model.seekPlayback(to: $0) },
                    onChapterMove: showChapters ? { id, newTime in
                        if let idx = model.chapters.firstIndex(where: { $0.id == id }) {
                            model.chapters[idx].timeSeconds = newTime
                        }
                    } : nil,
                    onTrimDragEnd: { oldIn, oldOut in
                        registerTrimUndo(oldIn: oldIn, oldOut: oldOut)
                    },
                    onChapterDragEnd: showChapters ? { id, oldTime in
                        registerChapterMoveUndo(id: id, oldTime: oldTime)
                    } : nil,
                    zoom: $model.waveformZoom,
                    visibleStart: $model.waveformVisibleStart,
                    onViewWidth: { model.waveformViewWidth = $0 },
                    onCursorFraction: { model.waveformCursorFraction = $0 },
                    tileCache: model.tileCache,
                    transcriptWords: model.trimWords
                )
            }
        }
        .frame(height: 120)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottom) {
            if model.isTrimTranscribing || !model.trimWords.isEmpty {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.accentColor.opacity(model.isTrimTranscribing ? 0.5 : 0.25))
                        .frame(width: max(6, geo.size.width * model.trimTranscriptProgress),
                               height: 3)
                        .animation(.linear(duration: 0.3), value: model.trimTranscriptProgress)
                }
                .frame(height: 3)
                .padding(.horizontal, 12)
                .padding(.bottom, 5)
                .allowsHitTesting(false)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waveform editor")
        .accessibilityValue(model.inputDuration > 0
            ? "Duration \(formatPlaybackTime(model.inputDuration)), trim \(formatPlaybackTime(model.trimInSeconds)) to \(formatPlaybackTime(model.trimOutSeconds))"
            : "No audio loaded")
    }

    func playbackControls(showSetInOut: Bool) -> some View {
        HStack(spacing: 10) {
            playPauseButton
            playheadTimeLabel
            Spacer()
            if showSetInOut {
                Button("Set In") {
                    let oldIn = model.trimInSeconds
                    let oldOut = model.trimOutSeconds
                    model.trimInSeconds = min(model.playback.playheadSeconds, model.trimOutSeconds - 0.5)
                    registerTrimUndo(oldIn: oldIn, oldOut: oldOut)
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.waveformSamples.isEmpty)

                Text("\(formatPlaybackTime(model.trimInSeconds)) – \(formatPlaybackTime(model.trimOutSeconds))")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)

                Button("Set Out") {
                    let oldIn = model.trimInSeconds
                    let oldOut = model.trimOutSeconds
                    model.trimOutSeconds = max(model.playback.playheadSeconds, model.trimInSeconds + 0.5)
                    registerTrimUndo(oldIn: oldIn, oldOut: oldOut)
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.waveformSamples.isEmpty)
            }
        }
    }

    var playPauseButton: some View {
        Button { model.togglePlayback() } label: {
            Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .disabled(model.waveformSamples.isEmpty)
    }

    var playheadTimeLabel: some View {
        Text(formatPlaybackTime(model.playback.playheadSeconds))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
    }

    func stepHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Undo/Redo

    func registerTrimUndo(oldIn: Double, oldOut: Double) {
        let newIn = model.trimInSeconds
        let newOut = model.trimOutSeconds
        undoManager?.registerUndo(withTarget: model) { m in
            m.trimInSeconds = oldIn
            m.trimOutSeconds = oldOut
            self.undoManager?.registerUndo(withTarget: m) { m in
                m.trimInSeconds = newIn
                m.trimOutSeconds = newOut
            }
            self.undoManager?.setActionName("Trim")
        }
        undoManager?.setActionName("Trim")
    }

    func registerChapterMoveUndo(id: UUID, oldTime: Double) {
        guard let idx = model.chapters.firstIndex(where: { $0.id == id }) else { return }
        let newTime = model.chapters[idx].timeSeconds
        undoManager?.registerUndo(withTarget: model) { m in
            if let i = m.chapters.firstIndex(where: { $0.id == id }) {
                m.chapters[i].timeSeconds = oldTime
            }
            self.undoManager?.registerUndo(withTarget: m) { m in
                if let i = m.chapters.firstIndex(where: { $0.id == id }) {
                    m.chapters[i].timeSeconds = newTime
                }
            }
            self.undoManager?.setActionName("Move Chapter")
        }
        undoManager?.setActionName("Move Chapter")
    }

    func registerChapterAddUndo(chapter: Chapter) {
        undoManager?.registerUndo(withTarget: model) { m in
            m.chapters.removeAll { $0.id == chapter.id }
            self.undoManager?.registerUndo(withTarget: m) { m in
                m.chapters.append(chapter)
                m.chapters.sort { $0.timeSeconds < $1.timeSeconds }
            }
            self.undoManager?.setActionName("Add Chapter")
        }
        undoManager?.setActionName("Add Chapter")
    }

    func registerChapterRemoveUndo(chapter: Chapter) {
        undoManager?.registerUndo(withTarget: model) { m in
            m.chapters.append(chapter)
            m.chapters.sort { $0.timeSeconds < $1.timeSeconds }
            self.undoManager?.registerUndo(withTarget: m) { m in
                m.chapters.removeAll { $0.id == chapter.id }
            }
            self.undoManager?.setActionName("Remove Chapter")
        }
        undoManager?.setActionName("Remove Chapter")
    }

    func registerArtworkUndo(oldArtwork: Data?) {
        let newArtwork = model.tagArtwork
        undoManager?.registerUndo(withTarget: model) { m in
            m.tagArtwork = oldArtwork
            self.undoManager?.registerUndo(withTarget: m) { m in
                m.tagArtwork = newArtwork
            }
            self.undoManager?.setActionName("Artwork")
        }
        undoManager?.setActionName("Artwork")
    }

    // MARK: - Event Monitors

    private func setupMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Let text fields handle their own keys
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            // Spacebar — play/pause on waveform steps
            if event.keyCode == 49,
               self.model.inputURL != nil,
               self.currentStep == 1 || self.currentStep == 3 {
                self.model.togglePlayback()
                return nil
            }
            return event
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if let window = NSApp.keyWindow,
               let hit = window.contentView?.hitTest(event.locationInWindow),
               !(hit is NSTextView || hit is NSTextField) {
                window.makeFirstResponder(nil)
            }
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Only intercept scroll on waveform tab; transcript tab needs scroll for its ScrollView
            let onWaveform = (self.currentStep == 1 && self.trimTab == 0) || self.currentStep == 3
            guard self.model.inputURL != nil, onWaveform else { return event }
            let dy = Double(event.scrollingDeltaY)
            let dx = Double(event.scrollingDeltaX)
            let precise = event.hasPreciseScrollingDeltas
            if abs(dy) > abs(dx) {
                // Vertical — zoom
                guard abs(dy) > 0.5 else { return event }
                self.model.waveformZoomScroll(dy: dy, isPrecise: precise)
            } else {
                // Horizontal — pan (only when zoomed in)
                guard abs(dx) > 0.5, self.model.waveformZoom > 1.0 else { return event }
                self.model.waveformPanScroll(dx: dx, isPrecise: precise)
            }
            return nil
        }
    }

    private func teardownMonitors() {
        if let m = keyMonitor    { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        if let m = clickMonitor  { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    // MARK: - Processing

    private func startProcessing() {
        model.startProcessing()
        if model.doTranscription {
            model.startTranscription(trimIn: model.trimInSeconds, trimOut: model.trimOutSeconds)
        }
    }
}

#Preview { ContentView() }
