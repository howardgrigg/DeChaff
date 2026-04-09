import AppKit
import UniformTypeIdentifiers

class ShareViewController: NSViewController {

    override func loadView() {
        let label = NSTextField(labelWithString: "Opening in DeChaff…")
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        self.view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        extractURLAndOpen()
    }

    private func extractURLAndOpen() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else {
            complete(); return
        }

        let typeID = UTType.url.identifier
        for provider in attachments {
            guard provider.hasItemConformingToTypeIdentifier(typeID) else { continue }
            provider.loadItem(forTypeIdentifier: typeID) { [weak self] item, _ in
                let url: URL?
                if let u = item as? URL {
                    url = u
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }

                DispatchQueue.main.async {
                    if let url {
                        var comps = URLComponents(string: "dechaff://download")!
                        comps.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
                        if let target = comps.url {
                            NSWorkspace.shared.open(target)
                        }
                    }
                    self?.complete()
                }
            }
            return
        }
        complete()
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
