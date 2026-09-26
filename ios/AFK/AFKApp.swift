import SwiftUI

@main
struct AFKApp: App {
    @StateObject private var session = DictationSessionController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
        }
    }
}
