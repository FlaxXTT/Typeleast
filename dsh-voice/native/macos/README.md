# TypeLeast — native macOS dictation app (Typeless-style)

The app was called dsh-voice until 2026-10-17. Only the visible name changed: the
bundle id is still `com.dsh.voice` (settings, history and dictionary carry over) and
the source folders keep their names. `build.sh` removes the old `dsh-voice.app`.

AppKit + SwiftUI app that records the microphone, converts to 16 kHz mono PCM16 WAV,
POSTs it to the DSH voice-polish host on 127.0.0.1 (at the port DSH publishes in
`~/.dsh/voice-polish/runtime.json`) and inserts the returned
text into the frontmost app via clipboard + Cmd+V. System frameworks only — no
third-party dependencies, no downloads.

## Build / install

    ./build.sh              # compile -> bundle -> ad-hoc sign -> install ~/Applications/TypeLeast.app -> relaunch
    ./build.sh --no-install # build only (into build/dist.noindex/)
    ./test.sh               # 223 checks, no host service required
    ./Tools/render.sh [dir] # offscreen PNGs of every page and the voice bar, with sample data

`build.sh` assembles the bundle under `build/dist.noindex/` (Spotlight skips
`*.noindex`), quits the running copy, installs `~/Applications/dsh-voice.app`,
removes and unregisters the staging copy, and relaunches. There is therefore only
ever one "dsh-voice" in Spotlight / the Apps view. (Older versions left
`build/dsh-voice.app` in an indexed folder, which is what produced a second entry.)

## What it looks like (after Typeless)

| Surface | Contents |
|---|---|
| Main window | Sidebar: 首页 · 历史 · 词典, 设置 at the bottom left, service status. Light / dark / system. |
| 首页 | "按 fn 开始听写", setup checklist (microphone, Accessibility, DSH), stats (字数, 节省时间, 字/分钟, 次数), recent dictations, engine summary |
| 历史 | Grouped by day; filters 全部 / 已整理 / 用了原文; search; hover: copy, copy raw, retry with the same audio, delete; "…" → delete all; keep history: 永久 / 1 年 / 1 个月 / 1 周 / 24 小时 / 不保存 |
| 词典 | Filters 全部 / 自动添加 / 手动添加; search; 新词 (word + optional "常被识别成"); 导入 CSV; edit / delete; synced to the host with `PUT /dictionary` |
| 设置 | 快捷键 (dictate: Fn + ⌥Space, paste last ⌃⌘V, recorder), 整理 (four strengths as cards, field context, auto-learn, rich lists), 语言, 音频 (microphone picker + live level bars, sounds, mute other audio), 插入, 通用 (appearance, launch at login, Dock icon, resting voice bar, onboarding), 隐私与数据, 权限, 整理服务 |
| Onboarding | Welcome → microphone → Accessibility → 🌐 key → mic test → try it → done |
| Voice bar | Dark capsule at the bottom centre: ✕ · waveform · ■ while recording, countdown in the last 15 s, three dots while thinking, ✓ + first 40 characters on finish. Optional resting bar (hover shows the shortcut, click starts). Non-activating panels: never steal focus. |
| Menu bar | Status, start/stop, cancel, paste last, Accessibility / DSH shortcuts when needed, open window, history, dictionary, settings, quit |

## Cleanup model and your own API key

Settings › 整理模型 chooses who cleans up dictations:

- **DeepSeek 账号（通过 DSH）**, the default: the account signed in to DSH.
- **自己的 API Key**: any OpenAI-compatible service. Presets are DeepSeek official, Zhipu GLM, Kimi, Qwen, OpenRouter, OpenAI, local Ollama, or a custom base URL. The key is kept in the macOS Keychain (`TypeLeast.llm-api-key`, one item per preset). Each dictation sends it to the local DSH host in `x-voice-llm` (base64 JSON); the host uses it for that call only and never records it. Remote base URLs must be https; plain http is accepted only for this Mac. "获取列表" reads the provider's `GET /models`; "测试连接" goes through DSH's `POST /test-llm`.
- **Prompt**: always Erduo's "Budget Typeless DIY" (personal use only, see THIRD-PARTY-NOTICES.md). 整理 offers two choices: Erduo 整理, or 原话转写 (no model).

DSH binds a new port on every launch. The app reads `~/.dsh/voice-polish/runtime.json`, falls back to DSH's listening port from `lsof`, and re-discovers once when a request cannot connect.

## Troubleshooting "连不上"

- **"model output hit its token limit" on 测试连接** meant the model was thinking: DeepSeek's `deepseek-flash` reasons by default and its thinking tokens count against `max_tokens`. The host now sends the provider's "thinking off" switch (DeepSeek and Zhipu `thinking: {type: "disabled"}`, Qwen `enable_thinking: false`), drops it for a host that answers 400, retries once with 4× the budget when a reply is all thinking, and the test allows 64 tokens and counts a cut-off reply as connected.
- **After each app update** macOS asks once whether TypeLeast may read its Keychain item, because an ad-hoc signed build gets a new code signature. Choose "始终允许"; until then the own-key route is treated as not configured and dictation uses the DSH account.

- The DSH status is re-checked when the window or the menu bar menu opens, and every 15 s while DSH looks down. (Before, one failed check at launch, e.g. while DSH was restarting, left "连不上 DSH" on screen although dictation worked.)
- Failures are logged to `~/Library/Logs/TypeLeast/typeleast.log`: event names, hosts, codes and timings only, never a key or dictated text.
- Self-check of the own-key path inside the real bundle (App Transport Security and Keychain apply there):

      DSH_VOICE_SELFCHECK=1 DSH_VOICE_LLMCHECK_URL=https://api.deepseek.com \
      DSH_VOICE_LLMCHECK_MODEL=deepseek-flash DSH_VOICE_LLMCHECK_KEY=<key> \
      ~/Applications/TypeLeast.app/Contents/MacOS/TypeLeast

  prints `LLMCHECK listModels=…`, `LLMCHECK test=…` and `LLMCHECK keychain.write=… read=…`.

## Keys and permissions

- **Fn single press** (Typeless default) is read by `FnKeyMonitor` from `.flagsChanged`
  events, which need only the Accessibility grant already used for pasting. A key-down
  monitor records a single "another key was pressed while Fn was held" bit so Fn+arrow /
  Fn+F-keys never start a dictation; no key content is read. Set System Settings ›
  Keyboard › "Press 🌐 key to" → "Do Nothing". Carbon `RegisterEventHotKey` handles every
  other binding (⌥Space, ⌃⌘V, Esc while recording).
- Permissions: Microphone, Accessibility. No Input Monitoring, screen recording, camera
  or Bluetooth.

## Accuracy features

- **Field context**: at dictation start, the focused field's text around the cursor,
  the selection and the window title are read (never from secure fields or password
  managers) and sent as base64 JSON in `x-voice-context`.
- **Auto-learn**: after a paste, the same field is re-read (next dictation or 20 s
  later, within 3 minutes). One short substitution that sounds like the original
  (pinyin / letters / initials / consonant skeleton) adds the corrected word as
  "自动添加" vocabulary — never as a hard replacement rule.
- **Rich lists**: numbered output is pasted as HTML/RTF lists in Notes, Mail, Pages,
  Word, TextEdit and Notion; plain text elsewhere.

## Contract with the host

| Item | Detail |
|---|---|
| Token | `~/.dsh/voice-polish/api-token`, read per request, re-read once after 401 |
| `GET /health` | `ok, version, provider, model, speech{providerId,ready,phase}, pid, reasoningEffort, stats, recentFailures` |
| `POST /dictate` | WAV body (16 kHz mono PCM16, 44-byte header, ≤ 4 MiB, ≤ 120 s); headers `x-voice-language`, `x-voice-app`, `x-voice-strength`, optional `x-voice-context` |
| `PUT /dictionary` | `{entries: ["word" or "heard=word", …]}` → `{ok, dictionary}` |
| `GET /history`, `POST /learn`, `POST /polish` | unchanged |

## Known limitations

1. Reading field context depends on the target app exposing its text through
   Accessibility; some Electron and web editors expose little or nothing.
2. Paste delivery cannot be confirmed without Accessibility; it is reported as
   "已粘贴（未验证）" rather than as a failure.
3. Ad-hoc signing changes the code hash on every build, so macOS may ask for
   Accessibility again after a rebuild.
