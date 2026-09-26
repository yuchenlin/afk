# AFK

[English](README.md) | **中文**

**Away From Keyboard（暂时离开键盘）** — 按住快捷键（默认 **⌘G**，也可选 **Fn**），说话，文字就会出现在光标处。优先支持 macOS 菜单栏应用。

## AFK 是做什么的

按住快捷键 → 麦克风音频流式发送到你选择的语音转写（STT）服务（屏幕上的胶囊实时显示文字）→ 松开 → 转写粘贴到光标位置。可选润色会去掉语气词等，但不改写你说的内容。

> 欢迎贡献截图 / 演示 GIF — 有干净素材欢迎提 PR。

## 功能特点

- **按住说话**（或免提模式）— 菜单栏启动，实时转写胶囊，粘贴到光标处
- **多服务商 STT 与润色** — xAI Grok、OpenRouter、OpenAI、本地 Whisper、Ollama、自定义（自带密钥 BYOK）
- **词汇表** — 自定义人名与术语，按你写的方式识别
- **历史记录** — 本地搜索 / 复制 / 粘贴过往转写
- **隐私路径** — 可完全本地（Whisper + Ollama），或使用你自己的云端密钥

## 先前工作

见 [docs/PRIOR_ART.md](docs/PRIOR_ART.md)。Fn + 粘贴改编自 [Scribe](https://github.com/xiangst0816/scribe)（MIT）。

## 下载与安装（Mac）

### 1. 推荐：GitHub Releases DMG

从 [GitHub Releases](https://github.com/yuchenlin/afk/releases/tag/v0.1.0) 下载 **[AFK-0.1.0.dmg](https://github.com/yuchenlin/afk/releases/download/v0.1.0/AFK-0.1.0.dmg)**（Developer ID 签名、Apple 公证并已装订）。打开磁盘映像，将 **AFK.app** 拖入 **应用程序**。

后续版本见 [全部 Releases](https://github.com/yuchenlin/afk/releases)。自行打包：`make dmg` → `dist/AFK-VERSION.dmg` — 详见 [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)（英文）。

#### Gatekeeper（源码 / Apple Development / 未公证构建）

**Release DMG** 一般可直接打开。若从源码构建或仅用 Apple Development / 临时签名，macOS 可能提示无法打开（无法检查是否包含恶意软件）。可以这样打开：

1. **右键**（或 Control-单击）**AFK.app** → **打开** → 再点 **打开**，或
2. **系统设置 → 隐私与安全性** → 找到有关 AFK 的提示 → **仍要打开**，然后确认。

**说明：** 要让其他人的 Mac 双击即可安装，需要 [Apple Developer Program](https://developer.apple.com/programs/)、**Developer ID Application** 证书、`notarytool` 公证并装订。Apple Development 或 `make dev-cert` 只适合在*你自己的* Mac 上保持辅助功能/麦克风授权。清单见 [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)。

### 2. 从源码构建

需要 macOS 上的 **完整 Xcode.app**（仅安装 Command Line Tools 时，近期 Swift 工具链会因隐晦的 plist 解析错误而失败）。

```bash
git clone https://github.com/yuchenlin/afk.git
cd afk
make install        # → /Applications/AFK.app（Apple Development 或 `make dev-cert`）
make api-key        # 可选：将 $XAI_API_KEY_VOICE 写入密钥文件（也可在「设置…」中粘贴）
open /Applications/AFK.app
```

可选打包（签名与 `make build` 相同；未公证）：

```bash
make dmg            # → dist/AFK-<version>.dmg
```

更多构建说明：[docs/BUILD.md](docs/BUILD.md)。

### 权限

请在**签名稳定**的构建上做一次：菜单栏 ⚠︎ → **授予辅助功能…** / **授予麦克风…**，或到「系统设置 → 隐私与安全性」中，在「辅助功能」和「麦克风」下启用 **AFK**。

`make install` 使用稳定身份签名（若有 Apple Development 则用之，否则 `make dev-cert`），使授权在**重建后仍然保留**。临时签名（`codesign -`）每次构建都会改变 CDHash，macOS 会忘记授权 — `make install` 会拒绝这种签名。若曾从临时签名安装切换过来，请先在「辅助功能」中删除幽灵 **AFK** 条目，再为新的 `/Applications/AFK.app` 启用一次。

## API 密钥教程（自带密钥 BYOK）

密钥**不会**编译进应用。推荐在 **设置…**（⌘,）中粘贴到对应服务商的密钥框并保存（文件权限为 `600`，位于 `~/Library/Application Support/AFK/`）。若从 shell 启动 AFK，环境变量会**覆盖**已保存的文件。

| 服务商 | 环境变量（shell 启动） | 密钥文件 |
|---|---|---|
| xAI Grok | `XAI_API_KEY_VOICE`（不是通用的 `XAI_API_KEY`） | `…/AFK/xai-api-key` |
| OpenRouter | `OPENROUTER_API_KEY` | `…/AFK/openrouter-api-key` |
| OpenAI | `OPENAI_API_KEY` | `…/AFK/openai-api-key` |
| Ollama / 本地 Whisper | 无需 | 无 |
| 自定义 | 无专用环境变量（可选密钥仅在设置 / `custom-api-key`） | `…/AFK/custom-api-key` |

仅 xAI 的辅助命令：`make api-key` 会把 `$XAI_API_KEY_VOICE` 写入 xAI 密钥文件。

### xAI / Grok Voice Transcribe（默认）

1. 打开 [xAI Console](https://console.x.ai/) 并登录（API 计费与消费级 Grok 聊天产品分开）。
2. 进入 **API Keys** → 创建密钥 → 立即复制（`xai-…`）。
3. 在 AFK → **设置…** 中为语音转写和/或润色选择 **xAI Grok**，粘贴密钥并保存。或：`export XAI_API_KEY_VOICE=…` 后从该 shell 启动 / 运行 `make api-key`。

文档快速入门：[docs.x.ai](https://docs.x.ai/developers/quickstart)。

### OpenAI

1. 打开 [platform.openai.com](https://platform.openai.com/)（开发者平台 — 不是 chatgpt.com）。
2. **API keys** → **Create new secret key** → 只显示一次，请立刻复制。
3. 在 AFK 设置的 **OpenAI** 下粘贴，或设置 `OPENAI_API_KEY`（shell 启动）。

### OpenRouter

1. 在 [openrouter.ai](https://openrouter.ai/) 注册，按需充值。
2. 在控制台创建 API 密钥（“Get your API key”）。
3. 在 AFK 设置的 **OpenRouter** 下粘贴，或设置 `OPENROUTER_API_KEY`。

### Ollama（仅本地润色）

无需 API 密钥。安装 [Ollama](https://ollama.com/)，拉取聊天模型（AFK 默认 `qwen2.5:0.5b`），基址保持 `http://localhost:11434/v1`（也可在设置中修改）。语音转写需另选服务商（如本地 Whisper 或云端 STT）。

### 本地 Whisper（whisper.cpp，仅语音转写）

无需 API 密钥。在终端运行：

```bash
scripts/local-whisper.sh [base|small|large-v3-turbo-q5_0]
```

必要时会通过 Homebrew 安装 `whisper-cpp`，下载模型，并在 `http://127.0.0.1:8178/v1` 提供 OpenAI 兼容的转写接口。在设置中将语音转写设为 **本地 Whisper**。

### 自定义（OpenAI 兼容）

将基址指向 LM Studio、自建 Whisper 服务等。密钥**可选** — 仅当该服务需要 `Authorization: Bearer …` 时。在设置中粘贴；没有专用环境变量。

### 服务商能力一览

| 服务商 | 语音转写 | 润色 | 需要密钥？ |
|---|---|---|---|
| **xAI Grok**（默认） | 流式，实时文字 | ✓ | 是（`XAI_API_KEY_VOICE`） |
| **OpenRouter** | 一次性（`/audio/transcriptions`） | ✓ 任意聊天模型 | 是 |
| **OpenAI** | 一次性（如 `gpt-4o-mini-transcribe`） | ✓ | 是 |
| **Ollama**（本地） | — | ✓ | 否 |
| **本地 Whisper** | 一次性 | — | 否 |
| **自定义** | 一次性 | ✓ | 可选 |

使用本地 Whisper + Ollama 时，数据不会离开本机；开始录音时 AFK 会预加载 Ollama 模型。云端服务商会用**你的**密钥把音频（及润色文本）发到对应 API — AFK 不运营代理。

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
12. 菜单 → **复制上次转写** — 若粘贴到了错误位置
13. 菜单 → **已启用** — 开关监听

## 隐私

- **纯本地路径：** 本地 Whisper（语音）+ Ollama（润色）— 音频与文字留在本机。
- **云端服务商：** 选择 xAI、OpenRouter 或 OpenAI 时，音频（及润色文本）会发送到该服务商的 API。AFK 不运营代理；你自带密钥（BYOK）。
- **密钥：** 永不编入二进制。从环境变量或 Application Support 下权限为 `600` 的文件读取（或在 **设置…** 中粘贴）。正式 App Store 构建应使用钥匙串 + 同意界面（见 [docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md)）。
- **历史 / 词汇表：** 仅保存在 Application Support 本地磁盘；AFK 不会上传。

## 贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。大规模改动前请阅读 [docs/PLAN.md](docs/PLAN.md)、[docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md) 与 [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)。

## 许可证

[MIT](LICENSE)。`KeyMonitor` / `TextInjector` 改编自 [Scribe](https://github.com/xiangst0816/scribe)（MIT）— 见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 目录结构

```
Sources/AFKCore/   Hotkey*、KeyMonitor、TalkSettings、AudioDevices、AudioRecorder、GrokStt、TranscriptAssembler、
                   ApiKeyStore、ListeningOverlay、VocabularyWindow、HistoryStore、HistoryWindow、TextInjector、LexiconStore、AppDelegate
Sources/AFKApp/    main.swift
docs/PLAN.md           产品计划
docs/PRIOR_ART.md      复用说明
docs/BUILD.md          本地构建与签名
docs/DISTRIBUTION.md   DMG、Gatekeeper、Developer ID、Releases（英文）
docs/RELEASE_PLAN.md   开源 / App Store / iOS
scripts/make-dmg.sh    将 AFK.app 打成 dist/AFK-VERSION.dmg
```

## 图标

Logo 为 `design/logo/afk-logo-dark.svg`（及 `-light`）：两只眼睛上方是声波微笑。`Sources/AFKCore/LogoMark.swift` 使用相同几何绘制菜单栏图标；`make icons` 生成 `Resources/AppIcon.icns`（打进应用包）以及 `design/icons/` — macOS iconset 与 `ios-AppIcon-1024.png`（正方形、不透明，供 App Store）。早期 Logo 探索在 `design/logo/candidates/`。

## 路线图

1. ~~Mac 壳 + 按住说话快捷键 + 粘贴~~
2. ~~真实麦克风 + Grok Voice Transcribe 流式~~
3. ~~词汇表 + 轻度润色~~
4. 中英混合评测 vs Fun-ASR
5. iOS 键盘中继
6. ~~经公证的 GitHub Releases DMG（Developer ID）~~
