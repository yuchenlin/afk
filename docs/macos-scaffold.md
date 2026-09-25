# macOS scaffold notes

- App is a **menu bar** agent (`LSUIElement` / `MenuBarExtra`), not a docked document app.
- Default PTT: **Right Option** (configurable later). Fn is harder to capture reliably on all keyboards.
- Insert path: Accessibility `AXSelectedText` / focused element insert → fallback pasteboard + Cmd+V.
- Streaming UI: tiny edge banner (`StreamingBanner`).
- Core types live in **AFKCore** (SPM); app target depends on it once the Xcode project is generated on a Mac.

Generate / open project on PiggyHouse (or any Mac):

```bash
./Scripts/generate-xcode.sh
open AFK.xcodeproj
```
