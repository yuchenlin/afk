import SwiftUI

@main
struct AFKApp: App {
    @StateObject private var session = DictationSessionController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .onOpenURL { url in
                    session.handleOpenURL(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    // Foreground is the only time iOS lets AFK (re)start the session mic.
                    if phase == .active {
                        session.noteBecameActive()
                    }
                }
        }
    }
}
