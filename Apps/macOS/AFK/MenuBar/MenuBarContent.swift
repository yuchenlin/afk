import AppKit
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var session: DictationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(session.isHolding ? "Recording… release Right Option" : "Hold Right Option to talk")
                .font(.callout)
            Divider()
            Toggle("Start at login", isOn: $session.launchAtLogin)
            Button("Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Divider()
            Button("Quit AFK") {
                NSApp.terminate(nil)
            }
        }
        .padding(4)
    }
}
