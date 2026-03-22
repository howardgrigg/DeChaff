import SwiftUI

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
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(ytManager)
        }
    }
}
