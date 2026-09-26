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
6. In the AFK app: grant mic → **Start dictation session** → switch to AFK Keyboard. Default UI is voice (hold mic to talk / release to send, or tap to toggle). Use **ABC** / **中文** for typing; **🌐** for the next system keyboard.

Mock STT is **off by default**. Paste an xAI key in Settings for live `grok-voice-transcribe-2.0` batch STT. With a key saved, the session path always uses Grok (never the Chinese mock string). Enable Mock STT only for offline / no-key smoke tests.

## What works vs stubs

| Piece | Status |
|---|---|
| Xcode project (app + keyboard) | ✅ |
| Onboarding + Settings (models, session length, Keychain) | ✅ |
| Host record → mock / Grok batch STT → App Group | ✅ (streaming STT deferred) |
| Background audio session keepalive | ✅ basic (`UIBackgroundModes: audio`) |
| Keyboard voice-first + ABC/中文 typing + globe | ✅ Typeless-like |
| Mic hold/tap → App Group command + Darwin → insertText | ✅ |
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
