# AFK

**Away From Keyboard** — hold **⌘G** (configurable), speak, text lands at the caret (macOS first).

v0.2: hold the shortcut → mic streams to **Grok Voice Transcribe 2.0** (live text in an on-screen pill) → release → text pastes at the caret.

> Screenshots / demo GIF welcome — open a PR if you have a clean capture.

## Prior art

See [docs/PRIOR_ART.md](docs/PRIOR_ART.md). Fn + paste adapted from [Scribe](https://github.com/xiangst0816/scribe) (MIT).

## Build (Mac)

```bash
git clone https://github.com/yuchenlin/afk.git
cd afk
make install        # → /Applications/AFK.app (uses Apple Development or `make dev-cert`)
make api-key        # optional: writes $XAI_API_KEY_VOICE to the key file (or paste it in Settings…)
open /Applications/AFK.app
```

Needs **full Xcode.app** on macOS (Command Line Tools alone fails on recent Swift toolchains with a cryptic plist parse error).

**Permissions (do this once on a stably-signed build):** menu bar ⚠︎ → **Grant Accessibility…** / **Grant Microphone…**, or System Settings → Privacy & Security → enable **AFK** under Accessibility and Microphone. `make install` signs with a stable identity (Apple Development if present, else `make dev-cert`) so grants **survive rebuilds**. Ad-hoc signing (`codesign -`) changes the CDHash every build and macOS forgets the grants — `make install` refuses that. After switching from an old ad-hoc install, remove ghost **AFK** rows in Accessibility, then enable the new `/Applications/AFK.app` once.

The API key is `XAI_API_KEY_VOICE`, read from the environment or `~/Library/Application Support/AFK/xai-api-key`; it is never compiled into the app (local dev only — production needs a proxy, see docs/PLAN.md).

## Use

1. Menu bar shows the AFK face (filled while recording; ⚠︎ next to it when a permission or the API key is missing)
2. Hold **⌘G** and speak — a pill at the bottom of the screen shows the mic level and live transcript
3. Release — the final transcript pastes at the cursor (falls back to the batch API if streaming fails)
4. A quick tap (<150ms) passes ⌘G through to the app, so Find Next still works
5. Menu → **Shortcut** → pick ⌘G (default) or Fn, or **Record New Shortcut…** (Esc cancels). Custom shortcuts need ⌘, ⌃ or ⌥ unless they're F-keys; the choice persists across launches
6. Menu → **Talk Mode**: **Hold to Talk** (default) or **Hands-Free** — tap ⌘G to start, tap again to finish, Esc cancels; holding still works as push-to-talk. Optional **Auto-Stop After a Pause** finishes once no new words arrive for 2.5 s (gives up after 10 s with no speech; hands-free recordings cap at 5 min)
7. Menu → **Output**: **Polished** (default) sends the transcript through Grok chat (`grok-4-1-fast-non-reasoning`; override with `defaults write xyz.yuchenlin.afk polishModel <model>`) to remove fillers (um, you know, 嗯, 呃), stutters ("the, the ... the"), and false starts, and to fix punctuation, without rewording. **Original** pastes exactly what was heard. If polishing fails or is too slow (4 s), the original is pasted and the pill says why. History keeps both versions. Needs chat access on `XAI_API_KEY_VOICE`
8. Menu → **Vocabulary…**: your own words and phrases, one per line (names, product terms, jargon such as GRPO, Hotshot, 宇辰). They're sent to Grok as key terms (max 100, each ≤ 50 characters) so they're recognized and spelled as written; saving applies from the next recording. Stored in `~/Library/Application Support/AFK/lexicon.txt`
9. Menu → **Microphone**: System Default or a specific input; the choice persists and falls back to the default if that device is unplugged
10. Menu → **History… (N)**: every transcript with time, target app, and length, newest first. Search, **Copy** (several at once), **Paste into Previous App**, **Delete** (or ⌫), and **Clear All…** (confirmed). Saved locally in `~/Library/Application Support/AFK/history.json` (mode 600); diagnostic self-tests aren't recorded
11. Menu → **Settings…** (⌘,): choose a **provider and model** separately for speech-to-text and polish, paste API keys (masked, saved to user-only files), and **Test** both. The menu shows ⚠️ when a key is missing or rejected

    | Provider | Speech-to-text | Polish | Key |
    |---|---|---|---|
    | **xAI Grok** (default) | streaming, live text | ✓ | `XAI_API_KEY_VOICE` |
    | **OpenRouter** | one-shot (`/audio/transcriptions`), e.g. `fish-audio/transcribe-1`, `qwen/qwen3-asr-1.7b` | ✓ any chat model | `OPENROUTER_API_KEY` |
    | **OpenAI** | one-shot, e.g. `gpt-4o-mini-transcribe` | ✓ | `OPENAI_API_KEY` |
    | **Ollama** (local) | — | ✓ `http://localhost:11434/v1` | none |
    | **Local Whisper** (whisper.cpp, local) | one-shot, `http://127.0.0.1:8178/v1` — run `scripts/local-whisper.sh [base\|small\|large-v3-turbo-q5_0]` to download a model from Hugging Face and start it | — | none |
    | **Custom** OpenAI-compatible (LM Studio, local Whisper server, …) | one-shot | ✓ | optional |

    Keys come from the environment variable when AFK is launched from a shell, otherwise from `~/Library/Application Support/AFK/<provider>-api-key`. Test reports incorrect keys, missing access, OpenRouter privacy-policy blocks, unknown models, and local servers that aren't running. OpenAI (direct) is implemented but untested here. Whisper output is cleaned (non-speech tags like `[BLANK_AUDIO]` dropped, Traditional Chinese converted to Simplified). With Local Whisper + Ollama, nothing leaves the Mac; AFK preloads the Ollama model when recording starts.
12. Menu → **Copy Last Transcript** if a paste went to the wrong place
13. Menu → **Enabled** toggles the listener

## Privacy

- **Local-only path:** Local Whisper (speech) + Ollama (polish) — audio and text stay on your Mac.
- **Cloud providers:** when you choose xAI, OpenRouter, or OpenAI, audio (and polish text) is sent to that provider’s API. AFK does not operate a proxy; you bring your own key.
- **Keys:** never compiled into the binary. Read from the environment or from mode-`600` files under `~/Library/Application Support/AFK/` (or paste in **Settings…**). Production App Store builds should use Keychain + a consent screen (see [docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md)).
- **History / vocabulary:** stored only on disk under Application Support; not uploaded by AFK.

## License

[MIT](LICENSE). `KeyMonitor` / `TextInjector` adapt [Scribe](https://github.com/xiangst0816/scribe) (MIT) — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Layout

```
Sources/AFKCore/   Hotkey*, KeyMonitor, TalkSettings, AudioDevices, AudioRecorder, GrokStt, TranscriptAssembler,
                   ApiKeyStore, ListeningOverlay, VocabularyWindow, HistoryStore, HistoryWindow, TextInjector, LexiconStore, AppDelegate
Sources/AFKApp/    main.swift
docs/PLAN.md       product plan
docs/PRIOR_ART.md  reuse notes
```

## Icon

The logo is `design/logo/afk-logo-dark.svg` (and `-light`): two eyes above a sound-wave smile. `Sources/AFKCore/LogoMark.swift` holds the same geometry and draws the menu bar icon; `make icons` renders `Resources/AppIcon.icns` (bundled into the app) plus `design/icons/` — the macOS iconset and `ios-AppIcon-1024.png` (square, opaque, for the App Store). Earlier logo explorations are in `design/logo/candidates/`.

## Roadmap

1. ~~Mac shell + hold-to-talk shortcut + paste~~
2. ~~Real mic + Grok Voice Transcribe 2.0 streaming~~
3. ~~Lexicon + light polish~~
4. zh–en mix eval vs Fun-ASR
5. iOS keyboard relay
