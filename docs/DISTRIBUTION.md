# Distribution (Mac)

How AFK reaches other Macs: DMG packaging, Gatekeeper, Developer ID + notarization, and GitHub Releases. Day-to-day local installs stay on `make install` — see [BUILD.md](BUILD.md).

## Channels

| Channel | Who it is for | Gatekeeper |
|---|---|---|
| **Build from source** (`make install`) | Developers / early adopters with Xcode | Uses Apple Development or `make dev-cert` on *that* Mac; grants survive rebuilds |
| **GitHub Releases DMG** (planned) | Everyone else | Needs **Developer ID Application** + **notarization** + staple for a double-click open |
| **Mac App Store** (later) | Store users | Sandboxed build; see [RELEASE_PLAN.md](RELEASE_PLAN.md) |

Recommendation (unchanged from the release plan): ship **direct download first** (GitHub Releases + optional Sparkle), then a sandboxed App Store build.

## PiggyHouse status (checked locally)

On **PiggyHouse** (build Mac for this work), as of the last agent check:

| Item | Value |
|---|---|
| Apple ID (Xcode) | `billyuchenlin@gmail.com` |
| Team | **Yuchen Lin** — Team ID **`6FQUWPKXD8`** |
| Apple Development | Present (`Apple Development: billyuchenlin@gmail.com (2566R646PN)`) |
| **Developer ID Application** | **Missing** |
| notarytool | Present (Xcode) |
| Notary keychain profile `AFK-notary` | Not stored yet |

**Implication:** Paid Apple Developer Program membership + Xcode Accounts login gives **Apple Development** for local builds/TCC. It does **not** create a **Developer ID Application** certificate by itself. Stranger installs still need the one-time steps below.

Re-check anytime (preferred):

```bash
make signing-status
# or:
security find-identity -v -p codesigning
# Look for: Developer ID Application: Yuchen Lin (6FQUWPKXD8)
xcrun notarytool history --keychain-profile AFK-notary   # after you create that profile
```

## Creating Developer ID (one-time on PiggyHouse)

You already pay for the Apple Developer Program. Creating **Developer ID Application** needs the Mac GUI (password / Touch ID / 2FA). An agent with only Shell on PiggyHouse **cannot** click Xcode for you.

### Preferred — Xcode (fewest steps)

1. Open **Xcode** on PiggyHouse.
2. **Xcode → Settings…** (⌘,) → **Accounts**.
3. Select Apple ID **`billyuchenlin@gmail.com`** (add it if missing).
4. Select team **Yuchen Lin (`6FQUWPKXD8`)** → **Manage Certificates…**.
5. Click **+** (bottom left) → **Developer ID Application**.
6. If prompted, enter your **Mac login password** or use **Touch ID**. Wait until a row like `Developer ID Application: Yuchen Lin (6FQUWPKXD8)` appears.
7. Close the sheets. Tell the agent **“done”** (or run yourself):

   ```bash
   make signing-status && make dmg
   ```

   When Developer ID is present, `scripts/make-dmg.sh` **re-signs with Hardened Runtime** automatically. Notarization is still a separate step (next section) — do **not** paste passwords into chat; run `store-credentials` locally.

### Alternate — developer.apple.com + Keychain CSR

1. Confirm membership at [developer.apple.com/account](https://developer.apple.com/account) while signed in as **`billyuchenlin@gmail.com`**.
2. **Certificates, Identifiers & Profiles** → **Certificates** → **+** → **Developer ID Application** → Continue.
3. On PiggyHouse: open **Keychain Access** → **Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority…**
   - User Email: `billyuchenlin@gmail.com`
   - Common Name: e.g. `Yuchen Lin Developer ID`
   - CA Email: leave blank
   - Select **Saved to disk** → Continue → save the `.certSigningRequest`
4. Upload that CSR in the portal → download the `.cer` → double-click to install into the **login** keychain.
5. Verify / package:

   ```bash
   make signing-status && make dmg
   ```

### If “Developer ID Application” is greyed out or missing

- Confirm the paid Program shows **Active** under Membership (Team **`6FQUWPKXD8`**).
- In Xcode Accounts, use the **team** row (not only the personal free team) before Manage Certificates.
- Apple limits how many Developer ID certs a team may hold; revoke an unused one on the portal only if you are sure no other Mac still needs its private key.

## DMG packaging (what we have today)


```bash
make dmg          # make build → scripts/make-dmg.sh → dist/AFK-<version>.dmg
```

The DMG contains `AFK.app` and an `Applications` symlink (drag-to-install). `scripts/make-dmg.sh` **re-signs with Developer ID Application** when that identity exists; otherwise it keeps the signature from `make build` (Apple Development / Local Dev / ad-hoc) and prints a Gatekeeper warning.

### Hardened Runtime + microphone entitlement

Developer ID packaging uses **Hardened Runtime** (`codesign --options runtime`). That requires an explicit entitlement for mic access:

- File: `Supporting/AFK.entitlements` — `com.apple.security.device.audio-input` = true
- `make build` and `scripts/make-dmg.sh` both pass `--entitlements Supporting/AFK.entitlements`
- **Do not** enable App Sandbox in that file for the direct-download build (would break network + Accessibility). Sandbox is only for the App Store path in [RELEASE_PLAN.md](RELEASE_PLAN.md).

Without `device.audio-input`, older macOS versions often **omit AFK from System Settings → Privacy & Security → Microphone** even though `NSMicrophoneUsageDescription` is present. After upgrading a signed build, **reinstall** the new DMG (or re-sign in place with the entitlement); toggling the mic switch alone is not enough if the installed binary still lacks the entitlement.

Verify:

```bash
codesign -d --entitlements - AFK.app | plutil -p -
# expect: com.apple.security.device.audio-input = true
```

### What has / has not been tested

- **Tested:** producing a UDZO DMG with `hdiutil` via `scripts/make-dmg.sh` / `make dmg` on a developer Mac (Apple Development–signed app inside).
- **Not done:** **Developer ID Application** identity is not in the keychain yet; no notary keychain profile; no stapled Release asset. `make dmg` will auto-prefer Developer ID once that cert exists.

### Why Apple Development is not enough for strangers

| Identity | Good for | Other people’s Macs |
|---|---|---|
| Ad-hoc (`codesign -`) | Local smoke tests | Gatekeeper blocks; TCC grants reset every rebuild |
| **AFK Local Dev** (self-signed) | Stable local TCC while developing | Gatekeeper blocks / warns; not trusted elsewhere |
| **Apple Development** | Your Macs signed into that team | **Does not** satisfy Gatekeeper on other users’ Macs |
| **Developer ID Application** + notarize + staple | Direct download | Double-click install (with a brief first-open prompt at most) |
| App Store distribution cert | Mac App Store only | Via the Store |

So a DMG built on a laptop with only Apple Development is still useful as **packaging practice** and for CI artifact checks — it is **not** a shippable download for end users.

## Gatekeeper: opening an unnotarized / unsigned build

If someone downloads a DMG or `.app` that is not Developer ID–notarized, macOS may say the app “can’t be opened because Apple cannot check it for malicious software.” Workarounds (same idea on recent macOS):

1. **Right-click (or Control-click) the app → Open → Open** in the dialog, or
2. **System Settings → Privacy & Security** → scroll to the message about AFK → **Open Anyway**, then confirm.

This is expected for unsigned / unnotarized / Apple Development–signed builds. It is **not** a substitute for proper release signing.

## Checklist: frictionless install for strangers

Do **not** paste Apple ID passwords, app-specific passwords, or `.p8` API keys into chat or commit them. Store them only via `notarytool store-credentials` (Keychain) or CI secrets.

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/) ($99/year) if not already.
2. Create and install a **Developer ID Application** certificate (portal or Xcode Manage Certificates) — see above. Xcode account login alone is not enough.
3. `make dmg` — when Developer ID is present, the script re-signs with Hardened Runtime **and** `Supporting/AFK.entitlements` (`device.audio-input`) and writes `dist/AFK-VERSION.dmg`.
4. **Once**, store notary credentials in the Keychain (pick one method; interactive prompts are fine):

   ```bash
   # Option A — Apple ID + app-specific password (appleid.apple.com → Sign-In and Security
   # → App-Specific Passwords). Team ID is on developer.apple.com → Membership.
   xcrun notarytool store-credentials AFK-notary \
     --apple-id "billyuchenlin@gmail.com" \
     --team-id "6FQUWPKXD8" \
     --password   # omit value to get a secure prompt

   # Option B — App Store Connect API key (.p8 + Key ID + Issuer ID)
   xcrun notarytool store-credentials AFK-notary \
     --key /path/to/AuthKey_XXXXX.p8 \
     --key-id "XXXXXXXXXX" \
     --issuer "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   ```

5. Submit and staple (profile name must match what you stored):

   ```bash
   xcrun notarytool submit dist/AFK-VERSION.dmg --keychain-profile AFK-notary --wait
   xcrun stapler staple dist/AFK-VERSION.dmg
   ```

6. Verify on a clean Mac (not your team): `spctl --assess -vv /path/to/AFK.app`, then open normally.
7. Attach the stapled DMG to a **GitHub Release** and link it from the README.

Optional later: Sparkle for auto-update (direct channel); App Store sandbox + review path in [RELEASE_PLAN.md](RELEASE_PLAN.md).

## GitHub Releases workflow (outline)

1. Bump `CFBundleShortVersionString` / `CFBundleVersion` in `Supporting/Info.plist`.
2. On a machine (or CI runner) with **Developer ID** + notarization credentials: `make dmg`, then notarize + staple.
3. `git tag vX.Y.Z && git push origin vX.Y.Z`.
4. Create a GitHub Release for that tag; upload `dist/AFK-X.Y.Z.dmg`.
5. Point the README “Download” link at the latest Release asset.

Until the first notarized asset exists, the README should say Releases are coming and keep **build from source** as the working install path.

## Related

- [BUILD.md](BUILD.md) — local Xcode build, `make install`, stable signing for TCC
- [RELEASE_PLAN.md](RELEASE_PLAN.md) — open source checklist, App Store vs direct, iOS
- `scripts/make-dmg.sh` — DMG packaging only (no notarization)
- `scripts/check-signing.sh` / `make signing-status` — read-only: Development vs Developer ID vs notary profile
