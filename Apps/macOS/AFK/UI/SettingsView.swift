import SwiftUI
import AFKCore

struct SettingsView: View {
    @ObservedObject var session: DictationSession

    var body: some View {
        Form {
            Picker("STT provider", selection: $session.provider) {
                Text("Grok Transcribe 2.0").tag(SttProvider.grok)
                Text("Fun-ASR (backup)").tag(SttProvider.funAsr)
            }
            Text("API keys stay in env / future proxy — not in the binary.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !session.lastTranscript.isEmpty {
                LabeledContent("Last insert", value: session.lastTranscript)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
