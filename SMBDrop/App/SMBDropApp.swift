import SwiftUI

@main
struct SMBDropApp: App {
    init() {
        // Background tasks must be registered before launch finishes, and
        // the backup controller must exist before any queued photo is staged
        // so it can record what it hands to the outbox.
        AutomaticBackupController.registerBackgroundTask()
        _ = AutomaticBackupController.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
