import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension ContentView {

    // MARK: - Step 1: Load Audio

    var step1View: some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                dropZone
                if let url = model.inputURL, !model.isLoadingWaveform {
                    fileInfoRow(url: url)
                }
            }
            .frame(maxWidth: 480)
            Spacer()
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
                .animation(.easeInOut(duration: 0.15), value: isTargeted)

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
                }
            }
        }
        .frame(height: 230)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            loadDroppedFile(from: providers, advanceStep: true)
        }
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
                    withAnimation(.easeInOut(duration: 0.2)) { self.currentStep = 1 }
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
                    withAnimation(.easeInOut(duration: 0.2)) { self.currentStep = 1 }
                }
            }
        }
        return true
    }
}
