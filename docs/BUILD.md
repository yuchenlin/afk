# Build notes

## Requirement

Full **Xcode.app** on the Mac. Command Line Tools alone (as on Yuchen's Air, 2026-09-25) make `swift build` die with:

`Unknown error parsing property list` / `Could not initialize build system`

## On PiggyHouse

```bash
cd ~/Documents/GitHub
gh repo clone yuchenlin/afk   # or git pull
cd afk
make build
open AFK.app
```

Then: System Settings → Privacy & Security → **Accessibility** → enable AFK.

Hold **Fn** ≥150ms → mock line pastes. Menu → **Paste test string** also works.

## First-run tip

Ad-hoc signed apps (`codesign -s -`) need to be enabled under Accessibility after each rebuild path change; prefer `make install` so the path stays `/Applications/AFK.app`.
