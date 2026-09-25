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

Hold **⌘G** ≥150ms → mock line pastes (shortcut is configurable from the menu). Menu → **Paste test string** also works.

## Stable signing (do this once)

```bash
make dev-cert   # creates a self-signed "AFK Local Dev" identity in the login keychain
```

`make build` signs with it automatically when present. Ad-hoc signing (`-`) pins the Accessibility grant to one build's hash, so every rebuild silently loses the permission; the dev identity keeps it across rebuilds. If AFK can't listen, the menu bar shows **AFK ⚠︎** and it starts listening within ~2s of the permission being granted.

## API key (local dev)

```bash
make api-key   # writes $XAI_API_KEY_VOICE to ~/Library/Application Support/AFK/xai-api-key (mode 600)
```

AFK only uses `XAI_API_KEY_VOICE`: from its environment when launched from a shell, otherwise from the key file (apps opened from Finder don't see `~/.zshrc`). A generic `XAI_API_KEY` is ignored. The Keychain isn't used because self-signed rebuilds re-trigger its access prompt, which blocks the app. Key terms come from the menu's **Vocabulary…** editor, saved to `~/Library/Application Support/AFK/lexicon.txt`; until that file exists the bundled `Resources/lexicon.example.txt` is used. `--open-vocabulary` / `--open-history` open those windows at launch.

## Diagnostics

`log stream --predicate 'subsystem == "xyz.yuchenlin.afk"'` shows each step (device, stream ready, bytes sent, result). Launch options run the talk flow without pasting or sending key presses: `open /Applications/AFK.app --args --self-test` (3 s test), `--self-test-hold`, `--self-test-handsfree`, `--self-test-cancel`, `--self-test-autostop`. Real shortcut presses during a self-test still paste normally.

## First-run tip

Ad-hoc signed apps (`codesign -s -`) need to be enabled under Accessibility after each rebuild path change; prefer `make install` so the path stays `/Applications/AFK.app`.
