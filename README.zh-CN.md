# AFK

[English](README.md) | **中文**

**Away From Keyboard（暂时离开键盘）** — 按住快捷键（默认 **⌘G**，也可选 **Fn**），说话，文字就会出现在光标处。优先支持 macOS 菜单栏应用。

按住快捷键 → 麦克风音频流式发送到你选择的语音转写（STT）服务（屏幕上的胶囊实时显示文字）→ 松开 → 文字粘贴到光标位置。

> 欢迎贡献截图 / 演示 GIF — 有干净素材欢迎提 PR。

## 功能特点

- **按住说话**（或免提模式）— 菜单栏启动，实时转写胶囊，粘贴到光标处
- **多服务商 STT 与润色** — xAI Grok、OpenRouter、OpenAI、本地 Whisper、Ollama、自定义（自带密钥 BYOK）
- **词汇表** — 自定义人名与术语，按你写的方式识别
- **历史记录** — 本地搜索 / 复制 / 粘贴过往转写
- **隐私路径** — 可完全本地（Whisper + Ollama），或使用你自己的云端密钥

## 先前工作

见 [docs/PRIOR_ART.md](docs/PRIOR_ART.md)。Fn + 粘贴改编自 [Scribe](https://github.com/xiangst0816/scribe)（MIT）。

## 安装（Mac）

```bash
git clone https://github.com/yuchenlin/afk.git
cd afk
make install        # → /Applications/AFK.app（使用 Apple Development 或 `make dev-cert`）
make api-key        # 可选：将 $XAI_API_KEY_VOICE 写入密钥文件（也可在「设置…」中粘贴）
open /Applications/AFK.app
```

需要 macOS 上的 **完整 Xcode.app**（仅安装 Command Line Tools 时，近期 Swift 工具链会因隐晦的 plist 解析错误而失败）。

### 权限

请在**签名稳定**的构建上做一次：菜单栏 ⚠︎ → **授予辅助功能…** / **授予麦克风…**，或到「系统设置 → 隐私与安全性」中，在「辅助功能」和「麦克风」下启用 **AFK**。

`make install` 使用稳定身份签名（若有 Apple Development 则用之，否则 `make dev-cert`），使授权在**重建后仍然保留**。临时签名（`codesign -`）每次构建都会改变 CDHash，macOS 会忘记授权 — `make install` 会拒绝这种签名。若曾从临时签名安装切换过来，请先在「辅助功能」中删除幽灵 **AFK** 条目，再为新的 `/Applications/AFK.app` 启用一次。

### API 密钥（自带密钥 BYOK）

密钥**不会**编译进应用。从 shell 启动时可设环境变量，或在 **设置…** 中粘贴（保存到 `~/Library/Application Support/AFK/` 下权限为 `600` 的文件）。见下方服务商表格。

## 使用

1. 菜单栏显示 AFK 图标（录音时填充；缺少权限或 API 密钥时旁有 ⚠︎）
2. 按住 **⌘G**（或你选择的快捷键 / **Fn**）说话 — 屏幕底部的胶囊显示麦克风电平和实时转写
3. 松开 — 最终转写粘贴到光标处（流式失败时回退到批量 API）
4. 短按（<150ms）会把 ⌘G 传给当前应用，因此「查找下一个」等功能仍可用
5. 菜单 → **快捷键** → 选择 ⌘G（默认）或 Fn，或 **录制新快捷键…**（Esc 取消）。自定义快捷键需含 ⌘、⌃ 或 ⌥，除非是 F 键；选择会跨启动持久保存
6. 菜单 → **说话模式**：**按住说话**（默认）或 **免提** — 轻点开始，再点结束，Esc 取消；按住仍可作为按住说话。可选 **停顿后自动停止**：约 2.5 秒无新词则结束（10 秒无语音则放弃；免提最长 5 分钟）
7. 菜单 → **输出**：**润色**（默认）将转写送入聊天模型，去掉语气词（um、you know、嗯、呃）、口吃与假起头，并修正标点，但不改写内容。**原文**则粘贴听到的内容。若润色失败或过慢（4 秒），会粘贴原文并由胶囊说明原因。历史会保留两个版本。
8. 菜单 → **词汇表…**：自有词与短语，每行一个（人名、产品名、术语）。作为关键词发送（最多 100 条，每条 ≤ 50 字符），以便按你写的方式识别与拼写。保存在 `~/Library/Application Support/AFK/lexicon.txt`
9. 菜单 → **麦克风**：系统默认或指定输入；选择会持久保存，设备拔出时回退到默认
10. 菜单 → **历史… (N)**：每条转写含时间、目标应用与长度，最新在前。可搜索、**复制**、**粘贴到上一应用**、**删除**、**全部清除…**。仅保存在本地 `~/Library/Application Support/AFK/history.json`（权限 600）
11. 菜单 → **设置…**（⌘,）：分别为语音转写与润色选择**服务商与模型**，粘贴 API 密钥（掩码显示），并**测试**两者。密钥缺失或被拒时菜单显示 ⚠️

    | 服务商 | 语音转写 | 润色 | 密钥 |
    |---|---|---|---|
    | **xAI Grok**（默认） | 流式，实时文字 | ✓ | `XAI_API_KEY_VOICE` |
    | **OpenRouter** | 一次性（`/audio/transcriptions`），如 `fish-audio/transcribe-1`、`qwen/qwen3-asr-1.7b` | ✓ 任意聊天模型 | `OPENROUTER_API_KEY` |
    | **OpenAI** | 一次性，如 `gpt-4o-mini-transcribe` | ✓ | `OPENAI_API_KEY` |
    | **Ollama**（本地） | — | ✓ `http://localhost:11434/v1` | 无需 |
    | **本地 Whisper**（whisper.cpp，本地） | 一次性，`http://127.0.0.1:8178/v1` — 运行 `scripts/local-whisper.sh [base\|small\|large-v3-turbo-q5_0]` 下载模型并启动 | — | 无需 |
    | **自定义** OpenAI 兼容（LM Studio、本地 Whisper 服务等） | 一次性 | ✓ | 可选 |

    从 shell 启动时密钥来自环境变量，否则来自 `~/Library/Application Support/AFK/<provider>-api-key`。使用本地 Whisper + Ollama 时，数据不会离开本机；开始录音时 AFK 会预加载 Ollama 模型。
12. 菜单 → **复制上次转写** — 若粘贴到了错误位置
13. 菜单 → **已启用** — 开关监听

## 隐私

- **纯本地路径：** 本地 Whisper（语音）+ Ollama（润色）— 音频与文字留在本机。
- **云端服务商：** 选择 xAI、OpenRouter 或 OpenAI 时，音频（及润色文本）会发送到该服务商的 API。AFK 不运营代理；你自带密钥（BYOK）。
- **密钥：** 永不编入二进制。从环境变量或 Application Support 下权限为 `600` 的文件读取（或在 **设置…** 中粘贴）。正式 App Store 构建应使用钥匙串 + 同意界面（见 [docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md)）。
- **历史 / 词汇表：** 仅保存在 Application Support 本地磁盘；AFK 不会上传。

## 贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。大规模改动前请阅读 [docs/PLAN.md](docs/PLAN.md) 与 [docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md)。

## 许可证

[MIT](LICENSE)。`KeyMonitor` / `TextInjector` 改编自 [Scribe](https://github.com/xiangst0816/scribe)（MIT）— 见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 目录结构

```
Sources/AFKCore/   Hotkey*、KeyMonitor、TalkSettings、AudioDevices、AudioRecorder、GrokStt、TranscriptAssembler、
                   ApiKeyStore、ListeningOverlay、VocabularyWindow、HistoryStore、HistoryWindow、TextInjector、LexiconStore、AppDelegate
Sources/AFKApp/    main.swift
docs/PLAN.md       产品计划
docs/PRIOR_ART.md  复用说明
```

## 图标

Logo 为 `design/logo/afk-logo-dark.svg`（及 `-light`）：两只眼睛上方是声波微笑。`Sources/AFKCore/LogoMark.swift` 使用相同几何绘制菜单栏图标；`make icons` 生成 `Resources/AppIcon.icns`（打进应用包）以及 `design/icons/` — macOS iconset 与 `ios-AppIcon-1024.png`（正方形、不透明，供 App Store）。早期 Logo 探索在 `design/logo/candidates/`。

## 路线图

1. ~~Mac 壳 + 按住说话快捷键 + 粘贴~~
2. ~~真实麦克风 + Grok Voice Transcribe 流式~~
3. ~~词汇表 + 轻度润色~~
4. 中英混合评测 vs Fun-ASR
5. iOS 键盘中继
