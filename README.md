# AFK

**Away From Keyboard** — hold **Fn**, speak, text lands at the caret (macOS first).

v0.1 is a **runnable shell**: Fn → mock transcript → paste. Grok STT comes next.

## Prior art

See [docs/PRIOR_ART.md](docs/PRIOR_ART.md). Fn + paste adapted from [Scribe](https://github.com/xiangst0816/scribe) (MIT).

## Build (Mac)

```bash
git clone https://github.com/yuchenlin/afk.git
cd afk
make build          # → AFK.app
open AFK.app
# or: make install  # → /Applications/AFK.app
```

Needs Xcode (or full CLT with macOS SDK). Grant **Accessibility** (Fn + paste). Mic comes when real STT lands.

## Use

1. Menu bar shows **AFK**
2. Hold **Fn**, release (≥150ms)
3. A mock line pastes at the cursor — proves the path
4. Menu → **Paste test string** without Fn
5. Menu → **Enabled** toggles the listener

## Layout

```
Sources/AFKCore/   KeyMonitor, TextInjector, MockStt, AppDelegate
Sources/AFKApp/    main.swift
docs/PLAN.md       product plan
docs/PRIOR_ART.md  reuse notes
```

## Roadmap

1. ~~Mac shell + Fn + paste~~
2. Real mic + Grok Voice Transcribe 2.0 streaming
3. Lexicon + light polish
4. zh–en mix eval vs Fun-ASR
5. iOS keyboard relay
