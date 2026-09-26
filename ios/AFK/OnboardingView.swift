import SwiftUI
import UIKit

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var session: DictationSessionController

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("AFK Keyboard (WIP) needs the host app for microphone access. Custom keyboards cannot open the mic — even with Full Access.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("1. Microphone") {
                    Label(
                        session.micGranted ? "Microphone allowed" : "Microphone needed",
                        systemImage: session.micGranted ? "checkmark.circle.fill" : "mic.slash"
                    )
                    Button("Request microphone") {
                        Task { await session.refreshMicPermission() }
                    }
                }

                Section("2. Enable keyboard") {
                    Text("Settings → General → Keyboard → Keyboards → Add New Keyboard… → AFK")
                        .font(.footnote)
                    Button("Open Keyboard Settings") {
                        openSettings("App-Prefs:root=General&path=Keyboard")
                    }
                }

                Section("3. Full Access") {
                    Text("In Keyboards → AFK → allow Full Access so the extension can use the App Group relay. Typing works without it; dictation does not.")
                        .font(.footnote)
                    Button("Open AFK Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section("4. Start a session") {
                    Text("Before dictating from the keyboard, tap “Start dictation session” in this app (orange mic indicator). Session length is configurable in Settings.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Setup")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        UserDefaults.standard.set(true, forKey: "afk.ios.onboardingDone")
                        isPresented = false
                    }
                }
            }
        }
    }

    private func openSettings(_ deepLink: String) {
        // Deep links into Settings sub-panes are best-effort / often ignored on modern iOS.
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
