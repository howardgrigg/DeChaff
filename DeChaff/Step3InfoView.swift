import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension ContentView {

    // MARK: - Step 3: Info

    var step3View: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 36) {
                artworkDropZone
                    .frame(width: 172, height: 172)

                VStack(alignment: .leading, spacing: 16) {
                    tagField("Sermon Title",  placeholder: "e.g. The Good Shepherd",  binding: $model.tagSermonTitle)
                    tagField("Bible Reading", placeholder: "e.g. John 10:1–18",        binding: $model.tagBibleReading)
                    tagField("Preacher",      placeholder: "Speaker's name",            binding: $model.tagPreacher)
                    tagField("Series",        placeholder: "Sermon series name",        binding: $model.tagSeries)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Date").font(.caption).foregroundStyle(.secondary)
                        DatePicker("", selection: $model.tagDate, displayedComponents: .date)
                            .datePickerStyle(.compact).labelsHidden().frame(alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(36)
        }
    }

    // MARK: - Artwork drop zone

    var artworkDropZone: some View {
        ZStack {
            if model.tagArtwork != nil, let nsImg = model.cachedArtworkImage {
                Image(nsImage: nsImg)
                    .resizable().aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack {
                    HStack {
                        Spacer()
                        Button { model.tagArtwork = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white).shadow(radius: 2)
                        }
                        .buttonStyle(.borderless).padding(6)
                    }
                    Spacer()
                }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isArtworkTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                        style: StrokeStyle(lineWidth: isArtworkTargeted ? 2 : 1.5,
                                           dash: isArtworkTargeted ? [] : [7, 4])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isArtworkTargeted ? Color.accentColor.opacity(0.05) : Color.secondary.opacity(0.04))
                    )
                    .animation(.easeInOut(duration: 0.15), value: isArtworkTargeted)
                VStack(spacing: 8) {
                    Image(systemName: isArtworkTargeted ? "photo.fill" : "photo.badge.plus")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(isArtworkTargeted ? Color.accentColor : Color.secondary)
                    Text("Drop artwork\nor click to browse")
                        .font(.caption)
                        .foregroundStyle(isArtworkTargeted ? Color.accentColor : Color.secondary)
                        .multilineTextAlignment(.center)
                }
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if model.tagArtwork == nil { openArtworkPicker() } }
        .onDrop(of: [UTType.fileURL], isTargeted: $isArtworkTargeted) { providers in
            loadArtwork(from: providers)
        }
    }

    // MARK: - Tag field

    func tagField(_ label: String, placeholder: String, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: binding).textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Artwork loading

    func openArtworkPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose album artwork"
        if panel.runModal() == .OK, let url = panel.url {
            DispatchQueue.main.async { self.loadArtworkFromURL(url) }
        }
    }

    func loadArtwork(from providers: [NSItemProvider]) -> Bool {
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

    func loadArtworkFromURL(_ url: URL) {
        guard let nsImage = NSImage(contentsOf: url),
              let tiff   = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg   = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return }
        model.tagArtwork = jpeg
    }
}
