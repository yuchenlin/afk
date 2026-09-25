# AFK

**Away From Keyboard** — hold **⌘G** (configurable), speak, text lands at the caret (macOS first).

v0.2: hold the shortcut → mic streams to **Grok Voice Transcribe 2.0** (live text in an on-screen pill) → release → text pastes at the caret.

## Prior art

See [docs/PRIOR_ART.md](docs/PRIOR_ART.md). Fn + paste adapted from [Scribe](https://github.com/xiangst0816/scribe) (MIT).

## Build (Mac)

```bash
git clone https://github.com/yuchenlin/afk.git
cd afk
make dev-cert       # once: stable signing so Accessibility survives rebuilds
make install        # → /Applications/AFK.app
make api-key        # optional: writes $XAI_API_KEY_VOICE to the key file (or paste it in Settings…)
open /Applications/AFK.app
```

Needs **full Xcode.app** (CLT alone fails on Swift 6.4 with a cryptic plist parse error). PiggyHouse is the intended build machine. Grant **Accessibility** (shortcut + paste) and **Microphone**. The API key is `XAI_API_KEY_VOICE`, read from the environment or `~/Library/Application Support/AFK/xai-api-key`; it is never compiled into the app (local dev only — production needs a proxy, see docs/PLAN.md).

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
11. Menu → **Settings…** (⌘,): paste your xAI API key (masked; saved to the user-only key file), **Test Key** checks speech-to-text and polish access separately and names the problem (incorrect key, no access, unknown model), and **Models (Advanced)** overrides the speech and polish model names. The menu shows ⚠️ when the key is missing or rejected
12. Menu → **Copy Last Transcript** if a paste went to the wrong place; **Paste test string** checks pasting without the mic
13. Menu → **Enabled** toggles the listener

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
