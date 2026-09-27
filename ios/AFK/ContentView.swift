import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: DictationSessionController
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "afk.ios.onboardingDone")
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(session.status)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if session.isSessionActive {
                    Text(session.micBlocked
                         ? "The mic could not start (a call or another app may be using it). AFK retries while it is open."
                         : "Session on — switch to any app and hold the AFK keyboard mic to talk. The mic stays muted, with no orange indicator, except while you hold it. Ends after \(session.settings.sessionMinutes) min without dictation.")
                        .font(.caption)
                        .foregroundStyle(session.micBlocked ? .orange : .green)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if session.openedFromKeyboard, session.isSessionActive {
                    Label("Session started. Tap ◀ at the top-left (or swipe right along the bottom edge) to go back and dictate.", systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }

                sessionButton
                recordButton

                if session.level > 0 {
                    ProgressView(value: Double(session.level))
                        .tint(.orange)
                        .padding(.horizontal, 40)
                }

                if !session.lastTranscript.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Last result")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(session.lastTranscript)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)
                }

                if let err = session.errorMessage {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top, 16)
            .navigationTitle("AFK")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Setup") { showOnboarding = true }
                }
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingView(isPresented: $showOnboarding)
                    .environmentObject(session)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(session)
            }
        }
    }

    private var sessionButton: some View {
        Button {
            session.toggleSession()
        } label: {
            Label(
                session.isSessionActive ? "End dictation session" : "Start dictation session",
                systemImage: session.isSessionActive ? "stop.circle.fill" : "waveform.circle.fill"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(session.isSessionActive ? Color.orange.opacity(0.2) : Color.accentColor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal)
    }

    private var recordButton: some View {
        Button {
            Task { await session.toggleRecordingFromHost() }
        } label: {
            ZStack {
                Circle()
                    .fill(session.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 96, height: 96)
                    .shadow(radius: 6)
                Image(systemName: session.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel(session.isRecording ? "Stop recording" : "Start recording")
        .disabled(!session.micGranted && !session.isRecording)
    }
}
