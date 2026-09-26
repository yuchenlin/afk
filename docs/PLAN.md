# AFK — Product & Architecture Plan

> Last updated: 2026-09-25  
> Platform focus: **macOS first**, then iOS  
> Working title: AFK (Away From Keyboard)

## One-line pitch

Typeless-style **speak → text at caret**, tuned for **Chinese–English code-switch** plus personal proper nouns — via cloud STT, a lexicon, and a cheap polish LLM.

## What Typeless actually sells

Not “voice to text” alone:

- Hold-to-talk in any app; text appears at the cursor
- Strip fillers / repeats; honor self-corrections (“不对，是…”)
- Auto punctuation & lists
- Mixed languages in one utterance
- Personal dictionary (names, product terms)
- Later: translate / Help me write / voice-edit selection

Open reference: **nano-typeless** (Mac Fn-hold → local FunASR → inject). AFK is that shape with **cloud engines** and a **“sounds typed”** polish layer.

## Architecture (two-stage, not one giant model)

```
Mic PCM
  → VAD / push-to-talk
  → STT (default: Grok Voice Transcribe 2.0, ≤100 key terms)
  → Light LLM polish (fillers, corrections, zh–en spacing, lexicon)
  → Insert at caret (macOS Accessibility; iOS insertText)
```

| Capability | STT alone | + short polish |
|---|---|---|
| “那个那个 transformer 的 attention” | Chatty oral dump | “Transformer 的 attention” |
| “不对，是 LoRA 不是 LoRA adapter” | Keeps both clauses | Keeps final intent |
| “把 PR 发到 #eng-rl” | Channel names drift | Lexicon + context |
| zh–en spaces / punctuation | Model-dependent | Rules + LLM unify |

Do **not** use a large LLM as ASR — latency and cost collapse.

## Engines

### Default: Grok Voice Transcribe 2.0

- Batch **$0.10/h**, streaming **$0.20/h** (diarization / timestamps / key terms included)
- Streaming + interim results + Smart Turn
- Up to **100** key terms per request
- Filler removal available
- Docs emphasize multilingual + mid-recording language switch; **no published in-utterance zh–en code-switch CER** — must self-eval
- Pin model id: `grok-voice-transcribe-2.0`
- Batch: `POST https://api.x.ai/v1/stt`
- Stream: `wss://api.x.ai/v1/stt`

Rough personal cost @ 20 min/day streaming ≈ **$2/user/month** STT.

**Security:** never embed `XAI_API_KEY_VOICE` in the shipping Mac/iOS binary; use a small authenticated proxy (e.g. Worker) for production.

### Backup: Fun-ASR / Qwen3-ASR (Alibaba)

Strong on zh–en mix, dialects, hotwords. DashScope `fun-asr-realtime`; local path via sherpa-onnx (nano-typeless-like). Implement **pluggable providers**; Grok default, Fun-ASR if mix fails eval.

### Others (not v1)

AssemblyAI Universal-3.5, Speechmatics Melia, Soniox, Groq Whisper — only if mix eval fails and Fun-ASR also insufficient.

## Platform shape

Shared: audio pipeline + STT clients + lexicon + polish. **Not** one UI.

### macOS (MVP)

Default hotkey is **⌘G**, configurable from the menu (Fn, or any recorded combo). Fn stays available for Typeless / Scribe muscle memory. A quick ⌘G tap is replayed to the app so Find Next keeps working.

1. Menu bar app (`LSUIElement`)
2. Hold the shortcut (default **⌘G**) → record; release → finalize
3. Thin streaming strip on screen edge
4. Insert via Accessibility; fallback Cmd+V
5. Permissions: Microphone + Accessibility

### iOS (later)

> **WIP:** host + keyboard scaffold lives in [`ios/`](../ios/) (branch work may land on `wip/ios`). Still not App Store ready.

Hard limits: keyboard extension **cannot** open the mic; ~30–60MB memory; Full Access required for App Group.

Pattern: Keyboard UI → App Group start/stop → **Host app** records + STT → result → `insertText`. Set `hasDictationKey = true`. Floating overlay / Share Sheet are weaker UX for chat boxes.

## Code split

```
Shared (AFKCore)     AudioCapture, SttClient, Lexicon, Polish, InsertText
macOS                MenuBar + Hotkey + AX
iOS (later)          KeyboardExtension + HostApp + App Group
```

Swift on both ends. No Electron / cross-platform keyboard framework for v1.

## MVP (only these six)

1. Hold-to-talk / release-to-send
2. Streaming interim + final replace
3. Personal lexicon (import txt)
4. `language=auto` (no forced mono language)
5. Strip 嗯 / 那个 / um
6. Caret insert; else clipboard + toast

**Defer:** translate, Help me write, selection rewrite, multi-device sync.

Lexicon layers:

1. STT key terms (phonetically fragile): Grok, LoRA, CUDA
2. Rule replace: `low ra` → `LoRA`
3. LLM polish with recent terms for “heard right, spelled wrong”

## Latency targets

- First partial: **400–800 ms**
- Release → final: **1–2 s**
- Above **~2.5 s** feels worse than system dictation

UX: show streaming raw text; when polish returns, **one full replace** (avoid dancing glyphs).

## Ship order

1. Mac menu bar MVP + Grok streaming + ~20 hotwords
2. Record **50** real mix utterances; score Grok vs Fun-ASR (CER / subjective)
3. ~10-line polish prompt (punct, correction, lexicon)
4. iOS host recording, then keyboard relay
5. Lexicon sync (iCloud / file) across devices

## Eval note

Public STT boards ≠ in-sentence CN–EN code-switch. Own set of 50–100 clips before locking the default engine. Template: `eval/mix-zh-en-template.md`.
