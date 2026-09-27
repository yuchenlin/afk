# iOS vs Mac STT audit (2026-09-26)

Goal: explain why iOS recognition can feel worse than Mac, and what build 12 changed.

## Same today (parity)

| Dimension | Mac | iOS |
|---|---|---|
| Model (default) | `grok-voice-transcribe-2.0` | same (`AppGroupConstants.defaultSpeechModel`) |
| Sample rate / format | 16 kHz mono PCM16 | same (`AudioCapture` / `PCMWav.defaultSampleRate`) |
| API host | `api.x.ai` `/v1/stt` | same batch `POST` |
| Min utterance | ~0.2 s (`sampleRate * 2 / 5` bytes) | same |
| Polish model (default) | `grok-4-1-fast-non-reasoning` | same |
| Polish on by default | Settings output style | `polishEnabled` default true |

## Differences that affect quality

| Dimension | Mac | iOS (before 12) | iOS (build 12) |
|---|---|---|---|
| Transport | **Streaming WebSocket** `wss://…/v1/stt` + batch fallback | Batch only | Still batch only (streaming deferred to AFKKit) |
| Keyterms / vocabulary | Lexicon → up to 100 `keyterm` fields | **Not sent** | **Sent** from App Group vocab (seeded with Mac `lexicon.example.txt`) |
| Polish prompt | Full Mac `Polisher` + vocab rules | Short stub prompt, no vocab | **Aligned** with Mac prompt + vocab |
| Capture | Fresh `AVAudioEngine` per hold, **no** voice processing | Armed muted engine with **Apple voice processing** (required for `isVoiceProcessingInputMuted`) | Unchanged — architectural; enables mute arm without session-long hot mic |
| Tap buffer | 4096 frames | 1024 frames | Unchanged (unlikely to matter vs VP / keyterms) |
| Converter | `downmix = true` | unset | **`downmix = true`** |
| Batch timeout | 20 s | 60 s | unchanged |

## Likely causes of “iOS worse than Mac”

1. **Missing keyterms (fixed in 12)** — Mac boosts names like LoRA / Grok / CUDA; iOS did not.
2. **Weaker polish (fixed in 12)** — Mac polish recovers mishearings via vocabulary; iOS stub did not.
3. **Batch-only vs streaming** — streaming can latch earlier audio and return interim finals; not shipped yet. Same final model, so effect is usually smaller than (1)/(2).
4. **Voice-processing capture** — AEC/NS can attenuate speech or add artifacts vs Mac’s raw input. Cannot drop VP without losing muted session-arm (would reintroduce hot mic or cold background start failures).
5. **Capture / noise / arm mute** — phone mic + room noise; first ~tens of ms after unmute may be soft. Not a model mismatch.

## Explicit non-goals this pass

- Do **not** reintroduce session-long unmuted mic (build 10).
- Do **not** auto-jump to AFK on mic (build 9+ CTA-only).
- Full shared `AFKKit` + streaming STT remains Phase 0.

## What to test on device (build 12)

1. Keyboard mic shows **AFK logo face** (eyes + bars); hold → **orange** pill + white logo; release → white again.
2. Press-hold / tap-to-speak still mute-arm (orange system mic indicator only while holding).
3. Say vocabulary words (LoRA, Grok, CUDA, AFK, 宇辰 if added) and compare to Mac.
4. Chinese–English code-switch sentence with polish on.
