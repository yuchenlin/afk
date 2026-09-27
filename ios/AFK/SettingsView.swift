import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: DictationSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = KeychainStore.readAPIKey() ?? ""
    @State private var vocabularyText: String = IOSVocabulary.loadText()
    @State private var saveMessage: String?
    @State private var testing = false
    @State private var testSpeech: String?
    @State private var testPolish: String?
    @State private var testKeychain: String?

    private var lexicon: IOSLexicon { IOSLexicon(from: vocabularyText) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Defaults match Mac (`grok-voice-transcribe-2.0` / `grok-4-1-fast-non-reasoning`). Mock STT is off when an xAI key is saved — live Grok is used instead.")
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
                    Button {
                        Task { await runConnectionTest() }
                    } label: {
                        if testing {
                            ProgressView()
                        } else {
                            Text("Test connection")
                        }
                    }
                    .disabled(testing || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if testSpeech != nil || testPolish != nil || testKeychain != nil {
                    Section("Connection test") {
                        if let testKeychain {
                            labeledRow("Keychain", testKeychain)
                        }
                        if let testSpeech {
                            labeledRow("Speech (STT)", testSpeech)
                        }
                        if let testPolish {
                            labeledRow("Polish (chat)", testPolish)
                        }
                    }
                }

                Section("Polish") {
                    Toggle("Polish after STT", isOn: $session.settings.polishEnabled)
                    TextField("Polish model", text: $session.settings.polishModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    TextEditor(text: $vocabularyText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    HStack {
                        Text("\(lexicon.keyTermsForStt.count) / \(IOSLexicon.maxKeyTerms) terms")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to Examples") {
                            vocabularyText = IOSVocabulary.bundledDefaults
                        }
                        .font(.caption)
                    }

                    if !lexicon.tooLongTerms.isEmpty {
                        Text("Over \(IOSLexicon.maxTermLength) characters, not sent: \(lexicon.tooLongTerms.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if lexicon.overLimitCount > 0 {
                        Text("\(lexicon.overLimitCount) term(s) past the first \(IOSLexicon.maxKeyTerms) are not sent")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Vocabulary")
                } footer: {
                    Text("One word or phrase per line (names, jargon, e.g. GRPO, Hotshot). Sent to Grok as STT key terms and polish hints. Lines starting with # are comments. Max \(IOSLexicon.maxKeyTerms) terms, ≤\(IOSLexicon.maxTermLength) characters each.")
                }

                Section {
                    Toggle("Start session when AFK opens", isOn: $session.settings.autoStartSession)
                    Stepper(
                        "End session after \(session.settings.sessionMinutes) min idle",
                        value: $session.settings.sessionMinutes,
                        in: 5...120,
                        step: 5
                    )
                } header: {
                    Text("Keyboard session")
                } footer: {
                    Text("During a session AFK stays running in the background (silent audio playback) with the mic muted, so the AFK Keyboard can dictate in any app. The mic unmutes only while you hold the keyboard mic (or between your two taps) and mutes again when you let go. Each dictation resets the idle timer.")
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
            .onAppear {
                vocabularyText = IOSVocabulary.loadText()
            }
        }
    }

    @ViewBuilder
    private func labeledRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(value.hasPrefix("OK") ? .green : .red)
        }
    }

    private func save() {
        do {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                KeychainStore.deleteAPIKey()
            } else {
                try KeychainStore.saveAPIKey(trimmed)
                // Real key → prefer live STT unless user explicitly wants mock.
                if session.settings.useMockSTT {
                    session.settings.useMockSTT = false
                }
            }
            IOSVocabulary.save(vocabularyText)
            session.saveSettings()
            // Confirm round-trip from Keychain (catches access-group / entitlement issues).
            let readBack = KeychainStore.readAPIKey()
            let vocabCount = IOSLexicon(from: vocabularyText).keyTermsForStt.count
            if trimmed.isEmpty {
                saveMessage = readBack == nil
                    ? "Saved (key cleared, \(vocabCount) vocab terms)"
                    : "Cleared, but Keychain still has a value"
            } else if readBack == trimmed {
                saveMessage = "Saved — Keychain OK · \(vocabCount) vocab terms"
            } else {
                saveMessage = "Saved, but Keychain read-back failed — check keychain-access-groups entitlement"
            }
        } catch {
            saveMessage = error.localizedDescription
        }
    }

    private func runConnectionTest() async {
        testing = true
        defer { testing = false }
        // Persist key first so Keychain probe is meaningful.
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !trimmed.isEmpty { try KeychainStore.saveAPIKey(trimmed) }
        } catch {
            testKeychain = "Keychain save failed: \(error.localizedDescription)"
            testSpeech = nil
            testPolish = nil
            return
        }
        let result = await ApiKeyTester.test(
            key: trimmed,
            speechModel: session.settings.speechModel,
            polishModel: session.settings.polishModel
        )
        testKeychain = result.keychainReadable ? "OK (readable)" : "Not readable after save"
        testSpeech = result.speech.summary
        testPolish = result.polish.summary
        if result.speech.isOK, session.settings.useMockSTT {
            session.settings.useMockSTT = false
            session.saveSettings()
        }
    }
}
