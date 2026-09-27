# AFK iOS

> **Not App Store ready.** Scaffold for Typeless/Wispr-style dictation: the **host app** records + STT; the **keyboard extension** types + inserts via App Group.

Architecture and review constraints: [`docs/PLAN.md`](../docs/PLAN.md), [`docs/RELEASE_PLAN.md`](../docs/RELEASE_PLAN.md) §3.

## Architecture

```
AFK host (SwiftUI)                     AFK Keyboard (UIInputViewController)
  mic + background audio session         Typeless-like voice-first UI (big mic)
  Grok batch STT / mock + polish         hold-to-talk / tap toggle via App Group
  settings (Keychain API key)            ABC / 中文 typing + 🌐; insertText on result
        └──── App Group `group.xyz.yuchenlin.afk` ────┘
```

**Hard constraint:** keyboard extensions cannot access the microphone (even with Full Access).

Shared Mac `Sources/AFKCore` is still macOS-only (AppKit / Carbon / Core Audio). This WIP ships a thin `ios/Shared` kit (App Group relay, mock STT, Grok batch client). Full `AFKKit` extraction remains TODO (Phase 0 in `TODO.md`).

## Open in Xcode

```bash
cd ios
xcodegen generate          # regenerates AFK-iOS.xcodeproj from project.yml
open AFK-iOS.xcodeproj
```

Or open `AFK-iOS.xcodeproj` directly if already generated.

### First-run setup (device or simulator)

1. **Signing:** select the **AFK** and **AFKKeyboard** targets → Signing & Capabilities → choose your **Team**.
2. **App Group:** capability is already declared as `group.xyz.yuchenlin.afk`. Create/enable that App Group for your Team in the developer portal (or change the id in entitlements + `AppGroupConstants.swift` consistently).
3. Bundle IDs (placeholders matching Mac reverse-DNS):
   - Host: `xyz.yuchenlin.afk.ios`
   - Keyboard: `xyz.yuchenlin.afk.ios.keyboard`
4. Run the **AFK** scheme on a simulator or device.
5. On device: Settings → General → Keyboard → Keyboards → Add **AFK** → enable **Allow Full Access**.
6. Open the AFK app once: grant mic → the session starts automatically (or tap **Start dictation session**). The orange mic indicator stays on while the session is ready. Go back to any app and switch to AFK Keyboard. Default UI is voice (hold mic to talk / release to send, or tap to toggle). Use **ABC** / **中文** for typing; **🌐** for the next system keyboard.

**How keyboard dictation stays in the current app (build 10, Wispr Flow / Typeless model).** iOS keeps a recording app running in the background under `UIBackgroundModes: audio`, but it refuses to *start* a mixable recording from the background (`AVAudioSession.ErrorCode.cannotStartRecording`, OSStatus 561145187 `!rec`). Builds ≤ 9 started `AVAudioEngine` on each keyboard tap — after the user left AFK that start failed on device (the simulator does not enforce the rule), so every dictation needed a trip back to AFK. Build 10 starts the mic engine **once, while AFK is foreground**, and keeps it running for the whole session ("hot mic"). Keyboard start/stop only arm/disarm which buffers are kept (0.4 s pre-roll), so no audio start ever happens in the background. A near-silent mixable loop runs beside it as a backup assertion.

The session ends after N minutes **without dictation** (Settings, default 30; each dictation resets it) or when you tap **End dictation session**. With **Start session when AFK opens** on (default), opening AFK is enough to start it.

**The keyboard never jumps to AFK on its own.** The mic talks to the host through the App Group + Darwin notifications only. The host heartbeat (1 Hz, background queue) also publishes `host.micLive`. The keyboard disables the mic and shows an **in-keyboard button** when it cannot work: "Open AFK once to start session" (no session), "Session paused — open AFK once" (host heartbeat gone), or "Mic paused by iOS — open AFK once" (host alive but iOS stopped the mic — phone call, Siri, audio route change; restarting needs the foreground). Tapping that button is the only path that opens `afk://session`; AFK restarts the mic and shows a "tap ◀ to go back" hint.

Mock STT is **off by default**. Paste an xAI key in Settings for live `grok-voice-transcribe-2.0` batch STT. With a key saved, the session path always uses Grok (never the Chinese mock string). Enable Mock STT only for offline / no-key smoke tests.

## What works vs stubs

| Piece | Status |
|---|---|
| Xcode project (app + keyboard) | ✅ |
| Onboarding + Settings (models, session length, Keychain) | ✅ |
| Host record → mock / Grok batch STT → App Group | ✅ (streaming STT deferred) |
| Background dictation session | ✅ session-long mic engine started in foreground (hot mic) + backup near-silent loop + 1 Hz heartbeat with `micLive` (`UIBackgroundModes: audio`) |
| Keyboard voice-first + ABC/中文 typing + globe | ✅ Typeless-like |
| Mic hold/tap → App Group command + Darwin → insertText | ✅ App Group only; never opens `afk://` |
| Host unreachable / mic paused → in-keyboard "Open AFK once" CTA | ✅ only deliberate tap opens `afk://session` |
| Full Mac Polisher / lexicon / streaming Grok | ❌ stub / simplified |
| Live Activity / Control Center / iCloud | ❌ TODO |
| App Store assets / consent / privacy policy | ❌ not claimed |

## Regenerate project

After editing `project.yml`:

```bash
cd ios && xcodegen generate
```

`AFK-iOS.xcodeproj` is committed so clones can open without XcodeGen; regenerate when the YAML changes.

## Mac build

This tree does **not** change `Package.swift` / `make build`. Keep Mac green separately.
