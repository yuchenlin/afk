# Release plan: open source, Mac App Store, iOS

Status: plan (September 2026). Facts checked against Apple docs / DTS answers and current App Review Guidelines; items marked *verify* need a real submission or device test.

## 1. Open source

**Ready with small fixes.** Full history (11 commits) contains no API keys or key-like strings; single author.

To do before flipping the repo public:

1. **License.** Pick one:
   - **MIT** (matches Scribe, simplest; anyone may also ship it, including to the App Store), or
   - **GPL-3.0** (clones must stay open; App Store distribution by *others* becomes impractical, while you, as sole copyright holder, can still ship it). Needs a CLA if you want to keep that right once others contribute.
2. **Third-party notice.** `KeyMonitor` / `TextInjector` adapt Scribe (MIT): add `THIRD_PARTY_NOTICES.md` with Scribe's copyright line and MIT text (a link in a comment isn't enough under MIT).
3. **README for strangers:** what it is, screenshots/GIF, install (download notarized build or build from source), providers table, privacy (what leaves the Mac, to whom), roadmap.
4. **CI:** GitHub Actions on `macos-latest`: `swift build` + `swift test` (live-API tests already skip without keys).
5. `CONTRIBUTING.md`, issue templates; optionally move `design/logo/candidates/` out.
6. Check the name: "AFK" is short and likely taken on the App Store; decide a store name (e.g. "AFK Dictation") early.

## 2. Mac distribution

Two channels, same codebase with a build flag:

| | Direct download (Developer ID, notarized) | Mac App Store |
|---|---|---|
| Sandbox | not required | **required** |
| Fn key as shortcut | yes (event tap suppresses the emoji popup) | combo shortcuts only (see below) |
| Updates | Sparkle | App Store |
| Review risk | none (notarization only) | moderate (Guideline 2.4.5, 5.1.2) |

Recommendation: ship **direct first** (GitHub Releases + Sparkle), then a sandboxed **Mac App Store** build.

### Changes needed for the Mac App Store build

1. **App Sandbox** + entitlements: `com.apple.security.app-sandbox`, `network.client` (APIs, incl. localhost for Ollama/Whisper), `device.audio-input`.
2. **No full Accessibility API.** Sandboxed apps can't use `AXIsProcessTrustedWithOptions`/AX APIs. Replace with the narrower permissions Apple DTS says are sandbox-compatible:
   - **Shortcut:** Carbon `RegisterEventHotKey` for combo shortcuts like ⌘G. It needs no permission, consumes the key, and reports press and release (push-to-talk and hands-free). Esc-to-cancel = register Esc as a temporary hot key while recording.
   - **Fn key:** needs an event tap; in the sandbox only with Input Monitoring (`CGRequestListenEventAccess`) and likely listen-only, so it can't suppress the emoji/input-source popup. Offer Fn only in the direct build (*verify*).
   - **Paste:** `CGEvent.post` of ⌘V (or Unicode typing) with **Post Event** access (`CGRequestPostEventAccess`), shown under Accessibility. Replay of a quick ⌘G tap uses the same.
   - Fallback if review objects: "copy to clipboard, press ⌘V yourself" mode.
3. **API keys → Keychain.** App Store builds have a stable signing identity, so Keychain prompts aren't an issue; also moves keys out of files. Sandbox container paths change (`~/Library/Containers/…`): migrate settings/history.
4. **Guideline 5.1.2(i) (third-party AI):** before the first request, show a consent screen naming where audio/text goes (xAI, OpenRouter + chosen model's provider, OpenAI) and why; local providers (Whisper/Ollama) need no consent. Privacy policy URL; App Privacy labels (Audio Data, User Content).
5. **Review access (Guideline 2.1):** reviewers must be able to use it. Either a working demo key in review notes, or a first-run path that works without a key (e.g. Local Whisper) — plus review notes explaining the hot key + Post Event usage.
6. **Business model:** bring-your-own-key (free) needs no In-App Purchase. Selling hosted transcription/credits = Guideline 3.1.1 → IAP, plus the proxy backend from `docs/PLAN.md` (never ship a shared key in the app).
7. Store assets: 1024 icon (done: `design/icons/`), screenshots, description, support URL. Apple Developer Program ($99/year).

## 3. iOS version

### Constraint that shapes everything

**Custom keyboard extensions have no microphone access**, even with Full Access (Apple docs). Voice keyboards (Wispr Flow, Gboard) therefore record in the **containing app** and relay text to the keyboard.

### Architecture

```
AFKKit (Swift package, shared with macOS)
  Providers, GrokStt (streaming WebSocket), BatchSpeechSession, Polisher,
  LexiconStore, HistoryStore, TranscriptAssembler, AudioRecorder (AVAudioEngine)

AFK iOS app (SwiftUI)            ── App Group + Keychain access group ──   AFK Keyboard (extension)
  records audio (background audio)   shared settings, vocabulary, history     mic button + basic typing
  transcribes + polishes             result hand-off                          inserts via textDocumentProxy
  settings, vocabulary, history      Darwin notifications (start/stop/done)   globe key (next keyboard)
  App Intents, Live Activity
```

Mac-only pieces stay out of `AFKKit`: `KeyMonitor`, `TextInjector`, AppKit windows, `AudioDevices` (Core Audio device list).

### Dictation flows

1. **In the app:** big record button → text → copy/share. Simplest; ship first.
2. **Action Button / Shortcuts / Control Center control / Lock Screen** (App Intents, iOS 18 Controls): start → Live Activity/Dynamic Island shows "listening" → stop → result copied to clipboard (and saved to history). No keyboard needed.
3. **Keyboard (Wispr-style "session"):**
   - Keyboard mic tap with no active session → hand off to the app to start one (keyboards can't open URLs through a public API; the common workaround is a gray area → *verify* in review, or ask users to start a session from the app / Action Button / Control Center).
   - The app keeps an audio session alive in the background for N minutes (setting: 5/15/60 min), with the orange mic indicator visible.
   - Keyboard mic taps then signal start/stop via Darwin notification; the app records, transcribes, polishes, writes the text to the App Group; the keyboard inserts it.

### App Review specifics

- **Guideline 4.4.1 (keyboards):** must provide real keyboard input (include a basic typing layout, not only a mic button), a next-keyboard (globe) key, and keep working without Full Access (typing works; dictation explains it needs the app + Full Access). No typing collection beyond the feature.
- **5.1.2(i)** consent for third-party AI, same as macOS; **Full Access** explanation screen.
- Background audio (`UIBackgroundModes: audio`) must be justified by active recording; don't keep the mic on silently beyond the user-chosen session.

### Phases

| Phase | Scope | Notes |
|---|---|---|
| 0 | Extract `AFKKit`; keep macOS app green | pure refactor, tests move with code |
| 1 | iOS app: record → Grok/other providers → polish → copy; settings, vocabulary, history | TestFlight — **WIP scaffold in `ios/`** |
| 2 | App Intents: Action Button, Shortcuts, Control Center control, Live Activity | biggest UX win per effort |
| 3 | Keyboard extension + session relay + basic typing layout | most review risk — **WIP scaffold in `ios/`** |
| 4 | Optional iCloud sync of vocabulary/history between Mac and iPhone | CloudKit |
| 5 | App Store submission | consent flow, privacy policy, screenshots |

On-device alternative for privacy/offline: WhisperKit / whisper.cpp in the iOS app (no third-party AI consent needed), at the cost of app size and battery.

## Decisions needed

1. License: MIT or GPL-3.0.
2. Store name.
3. Business model: bring-your-own-key only, or hosted transcription via subscription (IAP + proxy backend).
4. Apple Developer Program enrollment (individual or organization) — required for notarization, TestFlight, both stores.
