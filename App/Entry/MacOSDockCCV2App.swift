import SwiftUI

@main
struct MacOSDockCCV2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // 越早越好：之后任何被我们启动的应用继承的都是此刻的环境。理由见 `ProcessEnvironmentScrub`。
        ProcessEnvironmentScrub.apply()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.openSettings(nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
