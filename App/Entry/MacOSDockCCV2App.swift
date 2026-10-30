import SwiftUI

@main
struct MacOSDockCCV2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        ProcessEnvironmentScrub.apply()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {}
        }
    }
}
