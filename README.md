# AFK

**Away From Keyboard** — speak to insert on macOS (iOS later).

Hold a hotkey, talk (Chinese / English / mixed), get clean text at the caret. Differentiator is not the mic: **STT + personal lexicon + light LLM polish**.

## Status

- [x] Private repo + product plan
- [x] Shared core + macOS menu-bar scaffold
- [ ] Wire Grok Voice Transcribe 2.0 streaming
- [ ] 50-phrase zh–en mix eval (Grok vs Fun-ASR)
- [ ] Polish pass + lexicon import
- [ ] iOS keyboard ↔ host app relay

## Layout

```
Apps/macOS/AFK/     Menu bar app (hotkey, permissions, insert)
Sources/AFKCore/    Audio → STT → lexicon → polish → insert
docs/PLAN.md        Product + architecture plan
eval/               Mix-language test set template
Resources/          Example lexicon
```

## Quick start (on a Mac with Xcode)

1. Clone this repo.
2. Copy `.env.example` → keep the key out of the app; prefer a tiny proxy later.
3. Open `AFK.xcodeproj` (or generate with `./Scripts/generate-xcode.sh` if present).
4. Grant **Microphone** + **Accessibility**.
5. Hold **Right Option** (default) to record; release to finalize.

See [docs/PLAN.md](docs/PLAN.md) for architecture, engines, MVP scope, and ship order.

## License

Private — all rights reserved.
