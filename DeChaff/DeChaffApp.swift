import SwiftUI
import AppKit

@main
struct DeChaffApp: App {
    @StateObject var ytManager = YtDlpManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ytManager)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    ytManager.cleanupTempFiles()
                }
                .onAppear {
                    ProcessingModel.requestNotificationPermission()
                }
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    NotificationCenter.default.post(name: .openAudioFile, object: url)
                }
        }
        .windowResizability(.contentSize)
        .commands { DechaffCommands() }

        Settings {
            SettingsView()
                .environmentObject(ytManager)
        }
    }
}

extension Notification.Name {
    static let openAudioFile = Notification.Name("openAudioFile")
}
