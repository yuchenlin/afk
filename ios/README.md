# AFK iOS

> **Not App Store ready.** Scaffold for Typeless/Wispr-style dictation: the **host app** records + STT; the **keyboard extension** types + inserts via App Group.

Architecture and review constraints: [`docs/PLAN.md`](../docs/PLAN.md), [`docs/RELEASE_PLAN.md`](../docs/RELEASE_PLAN.md) §3.

## Architecture

```
AFK host (SwiftUI)                     AFK Keyboard (UIInputViewController)
  mic (per utterance) + playback keepalive Typeless-like voice-first UI (AFK logo mic)
  Grok batch STT / mock + polish         press-and-hold / tap-to-speak via App Group
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
6. Open the AFK app once: grant mic → the session starts automatically (or tap **Start dictation session**). Go back to any app and switch to AFK Keyboard. Default UI is voice: **hold the mic while you talk, release to send**, or **tap to start and tap again to send**. The orange mic indicator is on only while you hold (input unmuted); between holds the engine stays armed but muted. Use **ABC** / **中文** for typing; **🌐** for the next system keyboard.

**How keyboard dictation works (build 11: press-and-hold with muted session-arm).**

- **Session start (AFK foreground once).** `SessionKeepalive` activates a mixable `.playAndRecord` session and plays a near-silent looping sine (`UIBackgroundModes: audio`). At the same time `AudioCapture.arm()` starts a voice-processing `AVAudioEngine` with `isVoiceProcessingInputMuted = true`. Apple turns the **orange mic indicator off** while input is muted, but the engine keeps running so later unmutes work from the background.
- **Between utterances.** Engine stays armed + muted (no orange). Keepalive playback + 1 Hz heartbeat keep the host alive. Keyboard shows ready / hold-to-talk copy.
- **Per utterance.** Mic touch-down posts `start` (App Group + Darwin). Host calls `open()` → unmute only (nothing *starts* in the background). Release / second tap posts `stop` → `close()` mutes again, STT runs, text is inserted. AFK stays backgrounded.
- **Safety nets.** Keyboard `cancel` on dismiss; App Group ping while open (host closes if ping goes stale); 120 s utterance cap. If iOS stops the armed engine (call / Siri / route change) it cannot be restarted from the background → `host.micBlocked` → in-keyboard **"iOS stopped the AFK mic — open AFK once"** CTA; next foreground visit re-arms.

**Why this middle path (not build 10 hot mic, not cold per-hold start).** iOS refuses to *start* mic input once AFK is backgrounded (`cannotStartRecording` / avfaudio `'what'`, and `!int` on category switches into record). Build 9 failed for that reason. Build 10 kept the engine unmuted for the whole session (always-on orange). Build 11 arms once in the foreground, mutes with `isVoiceProcessingInputMuted` so orange is off between holds, and only unmutes while you talk — same stay-in-app dictation without a session-long hot mic.

**Tests (build 11).** Simulator iPhone 18 Pro: session arm (muted) + Messages keyboard hold/tap/cancel — utterances open/close from background with buffers (`mic armed (muted)` then `utterance open … appActive=false`). Physical Bill18pro was locked during the final device mute probe pass after earlier cold-start probes confirmed background `engine.start` fails; ship relies on the arm/mute design + sim proof. Re-open AFK once after calls/Siri if the CTA appears.

The session ends after N minutes **without dictation** (Settings, default 30; each dictation resets it) or when you tap **End dictation session**. With **Start session when AFK opens** on (default), opening AFK is enough to start it.

**The keyboard never jumps to AFK on its own.** The mic talks to the host through the App Group + Darwin notifications only. When the host cannot take a hold, the keyboard shows an **in-keyboard button**: "Open AFK once to start session" (no session), "Session paused — open AFK once" (host heartbeat gone), or "iOS blocked the mic — open AFK once" (host alive, background mic start refused). Tapping that button is the only path that opens `afk://session`; AFK (re)starts the session and shows a "tap ◀ to go back" hint.

Mock STT is **off by default**. Paste an xAI key in Settings for live `grok-voice-transcribe-2.0` batch STT. With a key saved, the session path always uses Grok (never the Chinese mock string). Enable Mock STT only for offline / no-key smoke tests.

## What works vs stubs

| Piece | Status |
|---|---|
| Xcode project (app + keyboard) | ✅ |
| Onboarding + Settings (models, session length, Keychain) | ✅ |
| Host record → mock / Grok batch STT → App Group | ✅ (streaming STT deferred) |
| Background dictation session | ✅ mixable `.playAndRecord` keepalive + **armed muted** voice-processing engine (orange off between holds) + 1 Hz heartbeat (`UIBackgroundModes: audio`) |
| Keyboard voice-first + ABC/中文 typing + globe | ✅ Typeless-like |
| Mic press-and-hold / tap-to-speak → App Group command + Darwin → unmute/mute armed engine → insertText | ✅ App Group only; never opens `afk://`; muted between holds |
| Host unreachable / armed engine lost → in-keyboard "Open AFK once" CTA | ✅ only deliberate tap opens `afk://session` |
| Full Mac Polisher / lexicon / streaming Grok | ⚠️ polish+keyterms aligned (build 12); streaming still deferred |
| STT Mac↔iOS audit | ✅ [`docs/IOS_STT_AUDIT.md`](../docs/IOS_STT_AUDIT.md) |
| Live Activity / Control Center | ❌ TODO |
| Vocabulary iCloud KVS sync (Mac ↔ iOS) | ✅ build 14 (`afk.vocabularyText`, LWW) |
| App Store assets / consent / privacy policy | ❌ not claimed |

## Regenerate project

After editing `project.yml`:

```bash
cd ios && xcodegen generate
```

`AFK-iOS.xcodeproj` is committed so clones can open without XcodeGen; regenerate when the YAML changes.

## Mac build

This tree does **not** change `Package.swift` / `make build`. Keep Mac green separately.
