import SwiftUI
import AFKCore

@main
struct AFKApp: App {
    @StateObject private var session = DictationSession()

    var body: some Scene {
        MenuBarExtra("AFK", systemImage: session.isHolding ? "mic.fill" : "mic") {
            MenuBarContent(session: session)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(session: session)
        }
    }
}
