import Sparkle
import SwiftUI

@main
struct BlitzTreeApp: App {
    /// Sparkle checks the latest GitHub release's appcast once a day,
    /// downloads the EdDSA-signed dmg and installs it when the app quits.
    private let updater: SPUStandardUpdaterController

    init() {
        // Root delete helper: runs and exits before any UI or updater starts.
        AdminTrash.runIfRequested()
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        // `BlitzTree /some/path` is a scan target, not a document to open.
        // Left to AppKit, the path becomes an open-file request and SwiftUI
        // then skips creating the main window entirely.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    }

    var body: some Scene {
        WindowGroup("BlitzTree") {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
            }
        }
    }
}
