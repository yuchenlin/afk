import SwiftUI
import UIKit

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var session: DictationSessionController
    @Environment(\.scenePhase) private var scenePhase
    @State private var fullAccessStatus: FullAccessProbe.HostStatus = FullAccessProbe.hostStatus()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("AFK Keyboard needs the host app for microphone access. Custom keyboards cannot open the mic — even with Full Access.")
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
                        openSettings()
                    }
                }

                Section("3. Full Access") {
                    Label {
                        Text(fullAccessStatus.label)
                    } icon: {
                        Image(systemName: fullAccessStatus.isOK ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(fullAccessStatus.isOK ? .green : .orange)
                    }
                    Text("In Keyboards → AFK → allow Full Access so the extension can use the App Group relay. Typing works without it; dictation does not. After enabling or changing Full Access, switch to the AFK Keyboard once so Setup can confirm — Recheck alone cannot see the toggle until the keyboard runs.")
                        .font(.footnote)
                    Button("Open AFK Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    Button("Recheck Full Access") {
                        recheckFullAccess()
                    }
                }

                Section("4. Start a session") {
                    Text("Open AFK once (or tap “Open AFK once” in the keyboard). AFK starts a session and keeps the mic ready — the orange indicator stays on — so you can go back to any app and dictate from the AFK Keyboard without switching again. The session ends after the idle time set in Settings.")
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
            .onAppear {
                // Only publish a challenge when not yet OK — rotating the challenge
                // while already configured used to force a false "waiting" state.
                if !FullAccessProbe.hostStatus().isOK {
                    FullAccessProbe.publishHostChallenge()
                }
                refreshFullAccess()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    refreshFullAccess()
                }
            }
            // Pick up keyboard reports while Setup stays open (Darwin → SwiftUI @State is awkward).
            .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
                refreshFullAccess()
            }
        }
    }

    private func recheckFullAccess() {
        // Publish a challenge for the keyboard to echo on next appear when we still
        // need confirmation. Do not rotate the challenge when already configured —
        // that previously made Recheck always look failed until the keyboard reopened.
        if !FullAccessProbe.hostStatus().isOK {
            FullAccessProbe.publishHostChallenge()
        }
        SessionRelay.shared.defaults.synchronize()
        refreshFullAccess()
    }

    private func refreshFullAccess() {
        fullAccessStatus = FullAccessProbe.hostStatus()
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
