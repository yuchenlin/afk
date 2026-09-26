import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: DictationSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = KeychainStore.readAPIKey() ?? ""
    @State private var saveMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("WIP scaffold — defaults match Mac (`grok-voice-transcribe-2.0` / `grok-4-1-fast-non-reasoning`).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Speech") {
                    Toggle("Use mock STT (no network)", isOn: $session.settings.useMockSTT)
                    TextField("Speech model", text: $session.settings.speechModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("xAI API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Polish") {
                    Toggle("Polish after STT", isOn: $session.settings.polishEnabled)
                    TextField("Polish model", text: $session.settings.polishModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Keyboard session") {
                    Stepper(
                        "Session length: \(session.settings.sessionMinutes) min",
                        value: $session.settings.sessionMinutes,
                        in: 5...60,
                        step: 5
                    )
                }

                if let saveMessage {
                    Section { Text(saveMessage).foregroundStyle(.green) }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func save() {
        session.saveSettings()
        do {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                KeychainStore.deleteAPIKey()
            } else {
                try KeychainStore.saveAPIKey(trimmed)
            }
            saveMessage = "Saved"
        } catch {
            saveMessage = error.localizedDescription
        }
    }
}
