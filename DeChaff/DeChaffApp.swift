import SwiftUI
import AppKit

@main
struct DeChaffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    NotificationCenter.default.post(name: .openAudioFile, object: url)
                }
        }
        .handlesExternalEvents(matching: ["*"])
        .windowResizability(.contentSize)
        .commands { DechaffCommands() }

        Settings {
            SettingsView()
                .environmentObject(ytManager)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension Notification.Name {
    static let openAudioFile = Notification.Name("openAudioFile")
}
