import Foundation
import Combine
import AFKCore

@MainActor
final class DictationSession: ObservableObject {
    @Published var isHolding = false
    @Published var statusLine = "Ready — grant Mic + Accessibility"
    @Published var lastTranscript = ""
    @Published var launchAtLogin = false
    @Published var provider: SttProvider = .grok

    private let hotkey = HotkeyMonitor()
    private let permissions = PermissionGate()
    private var pipeline: DictationPipeline?
    private let audio = AudioCapture()

    init() {
        bootstrap()
        hotkey.onHoldChanged = { [weak self] down in
            Task { @MainActor in
                await self?.handleHold(down)
            }
        }
        hotkey.start()
    }

    private func bootstrap() {
        let lexiconURL = Bundle.main.url(forResource: "lexicon.example", withExtension: "txt")
        let lexicon: LexiconStore
        if let lexiconURL, let loaded = try? LexiconStore.load(from: lexiconURL) {
            lexicon = loaded
        } else {
            lexicon = LexiconStore(terms: ["AFK", "LoRA", "Grok", "xAI"])
        }

        let stt: any SttClient = provider == .grok ? GrokSttClient() : FunAsrSttClient()
        pipeline = DictationPipeline(
            audio: audio,
            stt: stt,
            polish: PolishClient(),
            inserter: MacTextInserter(),
            lexicon: lexicon
        )
    }

    private func handleHold(_ down: Bool) async {
        if down {
            let ok = permissions.ensureForDictation()
            guard ok else {
                statusLine = "Need Microphone + Accessibility"
                return
            }
            do {
                try pipeline?.beginHold()
                isHolding = true
                statusLine = "Listening…"
            } catch {
                statusLine = "Capture failed: \(error)"
            }
        } else if isHolding {
            isHolding = false
            statusLine = "Transcribing…"
            guard let stream = pipeline?.endHold() else { return }
            for await event in stream {
                switch event {
                case .partial(let t):
                    statusLine = t
                case .final(let t):
                    lastTranscript = t
                    statusLine = "Inserted"
                case .error(let e):
                    statusLine = e
                }
            }
        }
    }
}
