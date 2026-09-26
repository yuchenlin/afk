# AFK

**English** | [中文](README.zh-CN.md)

**Away From Keyboard** — hold a shortcut (default **⌘G**, or **Fn**), speak, and text lands at the caret. macOS menu-bar app first.

## What AFK does

Hold the shortcut → your Mac’s mic streams to the speech-to-text provider you chose (live text in an on-screen pill) → release → the transcript pastes at the caret. Optional polish strips fillers without rewriting what you said.

> Screenshots / demo GIF welcome — open a PR if you have a clean capture.

## Features

- **Hold-to-talk** (or Hands-Free) from the menu bar — live transcript pill, paste at caret
- **Multi-provider STT & polish** — xAI Grok, OpenRouter, OpenAI, Local Whisper, Ollama, Custom (BYOK)
- **Vocabulary** — custom names and jargon recognized as written
- **History** — local search/copy/paste of past transcripts
- **Privacy paths** — fully local (Whisper + Ollama) or your own cloud keys

## Prior art

See [docs/PRIOR_ART.md](docs/PRIOR_ART.md). Fn + paste adapted from [Scribe](https://github.com/xiangst0816/scribe) (MIT).

## Download & install (Mac)

### 1. Preferred: GitHub Releases DMG *(coming with the first Release)*

When a notarized build is published, download **`AFK-*.dmg`** from [GitHub Releases](https://github.com/yuchenlin/afk/releases), open the disk image, and drag **AFK.app** into **Applications**.

Until that asset exists, use **build from source** below. Packaging a DMG locally is already supported (`make dmg` → `dist/AFK-VERSION.dmg`); shipping it to strangers still needs Apple **Developer ID** + notarization — see [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

#### Gatekeeper (unsigned / unnotarized / Apple Development builds)

macOS may say AFK “can’t be opened because Apple cannot check it for malicious software.” That is expected until a Developer ID–notarized Release exists. To open anyway:

1. **Right-click** (Control-click) **AFK.app** → **Open** → **Open**, or
2. **System Settings → Privacy & Security** → find the AFK message → **Open Anyway**, then confirm.

**Honest note:** a frictionless double-click install for other people’s Macs requires an [Apple Developer Program](https://developer.apple.com/programs/) enrollment, a **Developer ID Application** certificate, `notarytool` notarization, and stapling. Signing into Xcode → Settings → Accounts (Apple Development) is **not** the same as creating a Developer ID cert. Apple Development or the local `make dev-cert` identity only helps *your* Mac keep Accessibility/Microphone grants across rebuilds — it does **not** satisfy Gatekeeper elsewhere. Details and a checklist: [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

### 2. Build from source

Needs **full Xcode.app** on macOS (Command Line Tools alone fails on recent Swift toolchains with a cryptic plist parse error).

```bash
git clone https://github.com/yuchenlin/afk.git
cd afk
make install        # → /Applications/AFK.app (Apple Development or `make dev-cert`)
make api-key        # optional: writes $XAI_API_KEY_VOICE to the key file (or paste in Settings…)
open /Applications/AFK.app
```

Optional packaging (same signing as `make build`; not notarized):

```bash
make dmg            # → dist/AFK-<version>.dmg
```

More build notes: [docs/BUILD.md](docs/BUILD.md).

### Permissions

Do this once on a stably-signed build: menu bar ⚠︎ → **Grant Accessibility…** / **Grant Microphone…**, or System Settings → Privacy & Security → enable **AFK** under Accessibility and Microphone.

`make install` signs with a stable identity (Apple Development if present, else `make dev-cert`) so grants **survive rebuilds**. Ad-hoc signing (`codesign -`) changes the CDHash every build and macOS forgets the grants — `make install` refuses that. After switching from an old ad-hoc install, remove ghost **AFK** rows in Accessibility, then enable the new `/Applications/AFK.app` once.

## API keys tutorial (BYOK)

Keys are **never** compiled into the app. Prefer **Settings…** (⌘,) → paste into the provider’s key field → Save (files are mode `600` under `~/Library/Application Support/AFK/`). If you launch AFK from a shell, an environment variable **overrides** a saved file for that provider.

| Provider | Env var (shell launches) | Key file |
|---|---|---|
| xAI Grok | `XAI_API_KEY_VOICE` (not a generic `XAI_API_KEY`) | `…/AFK/xai-api-key` |
| OpenRouter | `OPENROUTER_API_KEY` | `…/AFK/openrouter-api-key` |
| OpenAI | `OPENAI_API_KEY` | `…/AFK/openai-api-key` |
| Ollama / Local Whisper | none | none |
| Custom | none (optional key only in Settings / `custom-api-key`) | `…/AFK/custom-api-key` |

Helper for xAI only: `make api-key` writes `$XAI_API_KEY_VOICE` to the xAI key file.

### xAI / Grok Voice Transcribe (default)

1. Open the [xAI Console](https://console.x.ai/) and sign in (API billing is separate from the consumer Grok chat product).
2. Go to **API Keys** → create a key → copy it immediately (`xai-…`).
3. In AFK → **Settings…**, choose **xAI Grok** for speech and/or polish, paste the key, Save. Or: `export XAI_API_KEY_VOICE=…` then launch from that shell / `make api-key`.

Docs quickstart: [docs.x.ai](https://docs.x.ai/developers/quickstart).

### OpenAI

1. Open [platform.openai.com](https://platform.openai.com/) (developer platform — not chatgpt.com).
2. **API keys** → **Create new secret key** → copy once.
3. Paste in AFK Settings under **OpenAI**, or set `OPENAI_API_KEY` for shell launches.

### OpenRouter

1. Sign up at [openrouter.ai](https://openrouter.ai/), add credits if needed.
2. Create an API key from the dashboard (“Get your API key”).
3. Paste in AFK Settings under **OpenRouter**, or set `OPENROUTER_API_KEY`.

### Ollama (local polish only)

No API key. Install [Ollama](https://ollama.com/), pull a chat model (AFK’s default is `qwen2.5:0.5b`), leave the base URL at `http://localhost:11434/v1` (or edit in Settings). Speech must use another provider (e.g. Local Whisper or a cloud STT).

### Local Whisper (whisper.cpp, speech only)

No API key. In a terminal:

```bash
scripts/local-whisper.sh [base|small|large-v3-turbo-q5_0]
```

That installs `whisper-cpp` via Homebrew if needed, downloads a model, and serves OpenAI-compatible transcriptions at `http://127.0.0.1:8178/v1`. In Settings, set speech-to-text to **Local Whisper**.

### Custom (OpenAI-compatible)

Point the base URL at LM Studio, a self-hosted Whisper server, etc. A key is **optional** — only if that server requires `Authorization: Bearer …`. Paste in Settings; there is no dedicated env var.

### Provider capabilities

| Provider | Speech-to-text | Polish | Key required? |
|---|---|---|---|
| **xAI Grok** (default) | streaming, live text | ✓ | yes (`XAI_API_KEY_VOICE`) |
| **OpenRouter** | one-shot (`/audio/transcriptions`) | ✓ any chat model | yes |
| **OpenAI** | one-shot (e.g. `gpt-4o-mini-transcribe`) | ✓ | yes |
| **Ollama** (local) | — | ✓ | no |
| **Local Whisper** | one-shot | — | no |
| **Custom** | one-shot | ✓ | optional |

With Local Whisper + Ollama, nothing leaves the Mac; AFK preloads the Ollama model when recording starts. Cloud providers send audio (and polish text) to that provider’s API using **your** key — AFK does not run a proxy.

## Use

1. Menu bar shows the AFK face (filled while recording; ⚠︎ next to it when a permission or the API key is missing)
2. Hold **⌘G** (or your chosen shortcut / **Fn**) and speak — a pill at the bottom of the screen shows the mic level and live transcript
3. Release — the final transcript pastes at the cursor (falls back to the batch API if streaming fails)
4. A quick tap (<150ms) passes ⌘G through to the app, so Find Next still works
5. Menu → **Shortcut** → pick ⌘G (default) or Fn, or **Record New Shortcut…** (Esc cancels). Custom shortcuts need ⌘, ⌃ or ⌥ unless they're F-keys; the choice persists across launches
6. Menu → **Talk Mode**: **Hold to Talk** (default) or **Hands-Free** — tap to start, tap again to finish, Esc cancels; holding still works as push-to-talk. Optional **Auto-Stop After a Pause** finishes once no new words arrive for 2.5 s (gives up after 10 s with no speech; hands-free recordings cap at 5 min)
7. Menu → **Output**: **Polished** (default) sends the transcript through a chat model to remove fillers (um, you know, 嗯, 呃), stutters, and false starts, and to fix punctuation, without rewording. **Original** pastes exactly what was heard. If polishing fails or is too slow (4 s), the original is pasted and the pill says why. History keeps both versions.
8. Menu → **Vocabulary…**: your own words and phrases, one per line (names, product terms, jargon). They're sent as key terms (max 100, each ≤ 50 characters) so they're recognized and spelled as written. Stored in `~/Library/Application Support/AFK/lexicon.txt`
9. Menu → **Microphone**: System Default or a specific input; the choice persists and falls back to the default if that device is unplugged
10. Menu → **History… (N)**: every transcript with time, target app, and length, newest first. Search, **Copy**, **Paste into Previous App**, **Delete**, and **Clear All…**. Saved locally in `~/Library/Application Support/AFK/history.json` (mode 600)
11. Menu → **Settings…** (⌘,): choose a **provider and model** separately for speech-to-text and polish, paste API keys (masked), and **Test** both. The menu shows ⚠️ when a key is missing or rejected
12. Menu → **Copy Last Transcript** if a paste went to the wrong place
13. Menu → **Enabled** toggles the listener

## Privacy

- **Local-only path:** Local Whisper (speech) + Ollama (polish) — audio and text stay on your Mac.
- **Cloud providers:** when you choose xAI, OpenRouter, or OpenAI, audio (and polish text) is sent to that provider’s API. AFK does not operate a proxy; you bring your own key (BYOK).
- **Keys:** never compiled into the binary. Read from the environment or from mode-`600` files under Application Support (or paste in **Settings…**). Production App Store builds should use Keychain + a consent screen (see [docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md)).
- **History / vocabulary:** stored only on disk under Application Support; not uploaded by AFK.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please read [docs/PLAN.md](docs/PLAN.md), [docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md), and [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) before large changes.

## License

[MIT](LICENSE). `KeyMonitor` / `TextInjector` adapt [Scribe](https://github.com/xiangst0816/scribe) (MIT) — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Layout

```
Sources/AFKCore/   Hotkey*, KeyMonitor, TalkSettings, AudioDevices, AudioRecorder, GrokStt, TranscriptAssembler,
                   ApiKeyStore, ListeningOverlay, VocabularyWindow, HistoryStore, HistoryWindow, TextInjector, LexiconStore, AppDelegate
Sources/AFKApp/    main.swift
docs/PLAN.md           product plan
docs/PRIOR_ART.md      reuse notes
docs/BUILD.md          local build & signing
docs/DISTRIBUTION.md   DMG, Gatekeeper, Developer ID, Releases
docs/RELEASE_PLAN.md   open source / App Store / iOS
scripts/make-dmg.sh    package AFK.app into dist/AFK-VERSION.dmg
```

## Icon

The logo is `design/logo/afk-logo-dark.svg` (and `-light`): two eyes above a sound-wave smile. `Sources/AFKCore/LogoMark.swift` holds the same geometry and draws the menu bar icon; `make icons` renders `Resources/AppIcon.icns` (bundled into the app) plus `design/icons/` — the macOS iconset and `ios-AppIcon-1024.png` (square, opaque, for the App Store). Earlier logo explorations are in `design/logo/candidates/`.

## Roadmap

1. ~~Mac shell + hold-to-talk shortcut + paste~~
2. ~~Real mic + Grok Voice Transcribe streaming~~
3. ~~Lexicon + light polish~~
4. zh–en mix eval vs Fun-ASR
5. iOS keyboard relay
6. Notarized GitHub Releases DMG (Developer ID)
