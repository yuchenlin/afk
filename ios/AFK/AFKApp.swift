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
                    // Re-assert keepalive when returning to foreground mid-session.
                    if phase == .active, session.isSessionActive, !session.isRecording {
                        session.beginSession(restartTimerOnly: true)
                    }
                }
        }
    }
}
