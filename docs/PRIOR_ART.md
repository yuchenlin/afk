# Prior art (reuse notes)

We studied these macOS “hold key → speak → insert” apps before scaffolding AFK.

| Project | License | Notes for AFK |
|---|---|---|
| [xiangst0816/scribe](https://github.com/xiangst0816/scribe) | **MIT** | Best fit. Fn via `CGEventTap` + `.maskSecondaryFn`, clipboard/⌘V + CJK IME swap, SPM + Makefile → `.app`. **KeyMonitor / TextInjector adapted with attribution.** |
| [Edamame-Labs/hold-to-talk](https://github.com/Edamame-Labs/hold-to-talk) | Apache-2.0 | Fn default, local Parakeet; study TextInserter strategies. |
| [ZhaoChaoqun/nano-typeless](https://github.com/ZhaoChaoqun/nano-typeless) | (no SPDX) | Closest Typeless UX + local FunASR; product reference, don’t copy without license clarity. |
| [mylxsw/typeflux](https://github.com/mylxsw/typeflux) | **AGPL-3.0** | Strong Swift Fn app — **do not vendor code** into this private repo without AGPL compliance. |
| [AsterZephyr/AsterTypeless](https://github.com/AsterZephyr/AsterTypeless) | (no SPDX) | HotkeyBridge / multi-provider ideas; check license before copying. |
| [zachswift615/speak2](https://github.com/zachswift615/speak2) | (no SPDX) | Fn + WhisperKit patterns. |

## What we reused

- **Build shape**: Scribe-style `Package.swift` library + thin executable + `Makefile` bundling (no XcodeGen required).
- **Fn PTT**: Scribe `KeyMonitor` pattern (MIT), suppress Fn to avoid emoji/globe side effects.
- **Insert**: Scribe `TextInjector` pattern (MIT), including temporary ASCII input-source switch for CJK IMEs.

## What we deliberately deferred

- Overlay waveform / live transcript pill (Scribe) — keep UI minimal for v0.1.
- Local FunASR / Whisper (nano-typeless, typeflux) — cloud Grok first after Fn path is proven.
- AGPL codebases as dependencies.
