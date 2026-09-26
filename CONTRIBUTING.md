# Contributing to AFK

Thanks for taking an interest. AFK is a macOS menu-bar dictation app (hold a
shortcut → speak → text at the caret). Please read
[docs/PLAN.md](docs/PLAN.md) and [docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md)
before large changes.

## Setup

You need **full Xcode.app** on macOS (Command Line Tools alone is not enough
for the current Swift toolchain).

```bash
git clone https://github.com/yuchenlin/afk.git
cd afk
make build          # or: make install → /Applications/AFK.app
swift test          # live-API tests skip when no keys are set
```

Optional: set `XAI_API_KEY_VOICE` (or paste a key in **Settings…**) for
end-to-end speech/polish tests. Never commit real keys; `.gitignore` already
excludes `*-api-key`, `.env`, and similar.

## Pull requests

1. Keep PRs focused: one fix or feature per PR.
2. Prefer small, tested changes. Run `swift test` (and a manual hold-to-talk
   smoke check if you touch capture, hotkeys, or paste).
3. Do not embed API keys, tokens, or personal absolute paths.
4. Attribute third-party code; Scribe adaptations go in
   [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
5. Match the existing Swift style (no drive-by renames).

## Issues

- Bug reports: macOS version, AFK build (`make install` / commit), provider,
  and steps to reproduce.
- Feature requests: how it fits the MVP / deferred list in `docs/PLAN.md`.

## Code of conduct

Be respectful. Harassment or abuse is not welcome.
