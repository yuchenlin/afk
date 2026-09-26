# TODO

Follow-ups from the release plan. Background, reasoning and sources: [docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md).

## Decisions

- [x] License: **MIT** (matches Scribe; flip to GPL only if you knowingly want copyleft)
- [ ] Store name ("AFK" alone is likely taken)
- [ ] Business model: bring-your-own-key only, or hosted transcription (subscription via In-App Purchase + proxy backend)
- [ ] Enroll in the Apple Developer Program ($99/year; needed for notarization, TestFlight, both stores)

## 1. Open source

- [x] Add `LICENSE`
- [x] Add `THIRD_PARTY_NOTICES.md` with Scribe's MIT copyright notice (KeyMonitor / TextInjector are adapted from it)
- [x] Rewrite README for new users: what it is, install, providers, privacy (screenshot/GIF still welcome)
- [x] GitHub Actions: `swift build` + `swift test` on macOS (live-API tests skip without keys)
- [x] `CONTRIBUTING.md` and issue templates
- [ ] Decide whether to keep `design/logo/candidates/` in the repo
- [ ] Make the repo public (history already checked: no keys, single author)

## 2. Mac: direct download

- [ ] Sign with Developer ID and notarize (replace the self-signed "AFK Local Dev" identity for releases)
- [ ] Auto-update with Sparkle
- [ ] Publish builds on GitHub Releases

## 3. Mac App Store build (sandboxed)

- [ ] Build flag / target with App Sandbox and entitlements: `app-sandbox`, `network.client`, `device.audio-input`
- [ ] Shortcut via Carbon `RegisterEventHotKey` for combo shortcuts (no permission needed); Esc-to-cancel as a temporary hot key
- [ ] Verify whether Fn can work in the sandbox; if not, offer Fn only in the direct build
- [ ] Paste via Post Event access (`CGRequestPostEventAccess`) instead of full Accessibility
- [ ] Fallback mode: copy to clipboard only, user presses ⌘V
- [ ] Move API keys to the Keychain; migrate settings/history into the sandbox container
- [ ] Consent screen before first use of a cloud provider, naming xAI / OpenRouter / OpenAI (Guideline 5.1.2(i)); none needed for Local Whisper / Ollama
- [ ] Privacy policy URL and App Privacy labels (Audio Data, User Content)
- [ ] Review access: demo key in review notes, or a first run that works without a key (Local Whisper)
- [ ] Review notes explaining the hot key and Post Event usage
- [ ] Store listing: screenshots, description, support URL (1024 icon done: `design/icons/`)

## 4. iOS

Constraint: custom keyboards can't use the microphone, so the main app records and hands text to the keyboard.

- [ ] **Phase 0** — extract a shared Swift package (`AFKKit`: providers, Grok streaming, batch speech, polish, vocabulary, history, audio recording); keep the macOS app and its tests green
- [ ] **Phase 1** — iOS app: record → transcribe → polish → copy/share; settings, vocabulary, history; TestFlight
- [ ] **Phase 2** — App Intents: Action Button, Shortcuts, Control Center control, Live Activity / Dynamic Island; result copied to clipboard
- [ ] **Phase 3** — keyboard extension:
  - [ ] Basic typing layout + globe (next keyboard) key (Guideline 4.4.1)
  - [ ] Works without Full Access for typing; explains dictation needs the app + Full Access
  - [ ] Background "session" in the main app (5 / 15 / 60 min setting, mic indicator visible)
  - [ ] Start/stop via Darwin notifications, text hand-off via App Group, insert with `textDocumentProxy`
  - [ ] Verify how the keyboard can start a session (opening the app from a keyboard is a review gray area)
- [ ] **Phase 4** — optional iCloud (CloudKit) sync of vocabulary and history between Mac and iPhone
- [ ] **Phase 5** — App Store submission: consent flow, privacy policy, screenshots
- [ ] Consider an on-device option (WhisperKit / whisper.cpp) for privacy and offline use

## Other open items (from earlier reviews)

- [ ] Fn mode: holding Fn with another key (Fn+arrows, Fn+Delete) still triggers dictation; cancel the hold when another key is pressed
- [ ] Clipboard restore after paste keeps only plain text (images/files/rich text on the clipboard are lost) and restores on a fixed timer; snapshot all types and skip restore if the clipboard changed
- [ ] Chinese–English accuracy comparison across speech providers (Grok, OpenRouter models, local Whisper) on real recordings
