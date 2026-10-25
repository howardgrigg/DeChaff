import SwiftUI
import UniformTypeIdentifiers
import AppKit
import DeChaffCore

extension ContentView {

    // MARK: - Step 1: Load Audio

    var step1View: some View {
        ScrollView {
            VStack(spacing: 24) {
                if model.inputURL == nil, let plan = resumablePlan {
                    resumeBanner(plan)
                }
                VStack(spacing: 16) {
                    dropZone
                    if let url = model.inputURL, !model.isLoadingWaveform {
                        fileInfoRow(url: url)
                    }
                }

                Divider()

                youtubeSection
            }
            .frame(maxWidth: 480)
            .padding(.vertical, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 36)
    }

    var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 2, dash: isTargeted ? [] : [10, 6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(isTargeted ? Color.accentColor.opacity(0.05) : Color(NSColor.controlBackgroundColor))
                )
                .motionAnimation(.easeInOut(duration: 0.15), value: isTargeted)

            if model.isLoadingWaveform {
                VStack(spacing: 10) {
                    ProgressView().scaleEffect(0.9)
                    Text("Loading…").font(.subheadline).foregroundStyle(.secondary)
                }
            } else if let url = model.inputURL {
                VStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text(url.lastPathComponent)
                        .font(.headline).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 24)
                    Text("Drop a different file to replace")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.7))
                    VStack(spacing: 4) {
                        Text("Drop audio file here")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(isTargeted ? Color.accentColor : Color.primary)
                        Text("WAV · MP3 · M4A · AIFF · FLAC · CAF")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Choose File…") { openFilePicker() }
                        .buttonStyle(.bordered).padding(.top, 4)
                        .disabled(youtube.downloadingVideoID != nil)
                }
            }
        }
        .frame(height: 230)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            guard youtube.downloadingVideoID == nil else { return false }
            return loadDroppedFile(from: providers, advanceStep: true)
        }
        .opacity(youtube.downloadingVideoID != nil ? 0.4 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.inputURL != nil
            ? "Audio loaded: \(model.inputURL!.lastPathComponent)"
            : "Audio file drop zone")
        .accessibilityHint("Activate to choose a file, or drop an audio file here")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if youtube.downloadingVideoID == nil { openFilePicker() } }
    }

    /// Offers to pick up the episode that was being worked on when DeChaff last closed.
    func resumeBanner(_ plan: EpisodePlan) -> some View {
        let name = plan.title.isEmpty ? URL(fileURLWithPath: plan.sourcePath).lastPathComponent : plan.title
        let kept = keptDuration(keptRanges(trimIn: plan.trimIn, trimOut: plan.trimOut,
                                           excluding: plan.excluded.map { ExcludedRange(startSeconds: $0.start, endSeconds: $0.end) }))
        var details = ["\(formatPlaybackTime(kept)) kept"]
        if !plan.chapters.isEmpty { details.append("\(plan.chapters.count) chapter\(plan.chapters.count == 1 ? "" : "s")") }
        if plan.editedBy == .assistant { details.append("prepared by Claude") }
        return HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pick up where you left off").font(.subheadline.weight(.semibold))
                Text(name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resume") {
                model.applyEpisodePlan(plan)
                resumablePlan = nil
                withMotion(.easeInOut(duration: 0.2)) { currentStep = 1 }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            Button {
                withMotion { resumablePlan = nil }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pick up where you left off: \(name)")
    }

    func fileInfoRow(url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.subheadline)
            Text(formatPlaybackTime(model.inputDuration))
                .font(.system(.subheadline, design: .monospaced)).foregroundStyle(.secondary)
            Text("·").foregroundStyle(.quaternary)
            Text(url.pathExtension.uppercased()).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loaded \(url.pathExtension.uppercased()) file, \(formatPlaybackTime(model.inputDuration)) long")
    }

    // MARK: - File loading

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an audio file to process"
        if panel.runModal() == .OK, let url = panel.url {
            DispatchQueue.main.async {
                self.model.loadFile(url: url)
                if self.currentStep == 0 {
                    withMotion(.easeInOut(duration: 0.2)) { self.currentStep = 1 }
                }
            }
        }
    }

    func loadDroppedFile(from providers: [NSItemProvider], advanceStep: Bool = false) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            guard let url else { return }
            DispatchQueue.main.async {
                self.model.loadFile(url: url)
                if advanceStep && self.currentStep == 0 {
                    withMotion(.easeInOut(duration: 0.2)) { self.currentStep = 1 }
                }
            }
        }
        return true
    }
}
