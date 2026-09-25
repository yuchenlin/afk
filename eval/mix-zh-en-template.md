# AFK mix-language eval template (50 utterances)

Goal: score **in-utterance** Chinese–English code-switch, not meeting WER.

For each row: record yourself, keep WAV under `eval/recordings/` (gitignored), fill hypotheses, compute CER or mark 1–5 quality.

| id | reference (what you meant) | category | Grok hyp | Fun-ASR hyp | notes |
|---|---|---|---|---|---|
| 01 | 那个那个 Transformer 的 attention 有点怪 | tech-mix | | | |
| 02 | 不对，是 LoRA 不是 LoRA adapter | correction | | | |
| 03 | 把 PR 发到 #eng-rl | proper-noun | | | |
| 04 | 今天 Model Y 要去 DMV | life-mix | | | |
| 05 | um 我们用 Grok Transcribe 2.0 | filler | | | |
| 06 | | | | | |
| … | fill to 50 across: tech / life / names / corrections / lists | | | | |

Categories to cover (~10 each): tech jargon, daily life, proper nouns, self-corrections, punctuation/lists.

Pass bar for default engine: subjective ≥4/5 on ≥80% of mix clips, or CER threshold you pick after a dry run.
