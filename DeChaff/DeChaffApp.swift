import SwiftUI

@main
struct DeChaffApp: App {
    @StateObject var ytManager = YtDlpManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ytManager)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(ytManager)
        }
    }
}
