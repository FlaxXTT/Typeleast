# TypeLeast 本地服务

macOS 和 Windows 两个 App 共用的后台服务（Node.js，没有界面）：

- **本地识别**：SenseVoice int8，用 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 在本机运行；超过 20 秒的录音先用 Silero VAD 按停顿切分。
- **整理**：用 App 随请求带来的模型和 API Key（任何 OpenAI 兼容接口）调用大模型，提示词见 `lib/prompts/cleanup.md`；没有 Key 时返回去掉口水词的原文。
- **使用场景描述**：App 发来历史里的术语纠正和意图，生成一段不超过 1000 字的描述；之后每次整理附在提示词里。服务不保存。

App 会自己启动和停止这个服务，普通用户不需要单独运行它。

## 运行

需要 Node.js 22 或更新版本。

```bash
npm ci
npm run setup-models
npm start
```

- `npm run setup-models`：下载语音模型（约 241 MB，从 Hugging Face，逐个校验 SHA-256）。已经有这些文件时用 `npm run setup-models -- --from <文件夹>` 导入（会在六层子目录内按文件名查找并校验）。设置环境变量 `HF_ENDPOINT` 可以换成镜像。
- `npm start`：启动服务。成功后标准输出第一行是 `{"event":"ready","port":…,"pid":…,"version":…}`，日志写到标准错误。
- 命令行参数：`--state-dir <目录>`、`--models-dir <目录>`、`--port <端口>`（默认 0，即由系统分配）、`--parent-pid <进程号>`（该进程退出时服务也退出）。

## 文件位置

| | macOS | Windows | Linux |
|---|---|---|---|
| 状态目录 | `~/Library/Application Support/TypeLeast` | `%APPDATA%\TypeLeast` | `~/.config/typeleast` |
| 模型目录 | `~/Library/Application Support/TypeLeast/models` | `%LOCALAPPDATA%\TypeLeast\models` | `~/.local/share/typeleast/models` |

环境变量 `TYPELEAST_HOME` 覆盖状态目录（模型放在它下面的 `models`），`TYPELEAST_MODELS` 单独覆盖模型目录。

状态目录里有：`api-token`（访问令牌）、`runtime.json`（当前端口），以及可选的 `config.json`。服务不保存听写历史和词典：历史在 App 里加密保存，词典随每次请求发送。旧版本留下的 `history.jsonl`、`dictionary.json` 会在启动时删除。

## config.json（可选）

一般不需要。例如：

```json
{ "timeoutMs": 15000, "numThreads": 4 }
```

| 键 | 默认 | 说明 |
|---|---|---|
| `timeoutMs` | 12000 | 整理的时限，超时退回原文 |
| `maxOutputTokens` | 800 | 整理结果的长度上限 |
| `temperature` | 0.8 | 提示词按 0.8 调过 |
| `strength` | `prompt` | `off` 不调模型；`conservative` / `prompt` / `maximal` 只影响校验的严格程度 |
| `language` | `auto` | 识别语言：`auto`、`zh`、`en`、`yue`、`ja`、`ko` |
| `numThreads` | 2 | 识别用的 CPU 线程数 |
| `redactSecrets` | `true` | 发给模型前抹掉看起来像密钥、密码的内容 |

模型、接口地址和 API Key **不在**这里配置：App 每次请求时带过来，服务不保存。

## HTTP 接口

地址 `http://127.0.0.1:<port>/api/voice-polish`，每个请求都要带 `Authorization: Bearer <api-token 文件的内容>`，`Host` 必须是回环地址。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 状态：`ok`（识别就绪）、`service`、`version`、`speech`（`phase`、下载进度）、统计 |
| POST | `/dictate` | 请求体是 JSON 对象 `{profile?}`（字节数见 `x-voice-meta-bytes`，可为 0）加 16 kHz 单声道 16 位 WAV（44 字节头）；请求头 `x-voice-language`、`x-voice-app`、`x-voice-strength`、可选 `x-voice-context`、`x-voice-llm`（base64 JSON：`{baseURL, model, apiKey}`） |
| POST | `/polish` | JSON `{text, strength?, llm?, profile?}`，只整理文字 |
| POST | `/test-llm` | JSON `{llm}`，测试一次模型连接 |
| POST | `/profile` | JSON `{llm, items}`：历史里的术语纠正和意图，返回 `{profile}`；只读取，不保存 |
| POST | `/models/download` | 开始下载语音模型，进度见 `/health` |

## 测试

```bash
npm test
node scripts/check-redaction.mjs
node scripts/tune-novelty.mjs
```

`npm test` 不联网；装好模型后会多跑一项真实识别。`scripts/live-acceptance.mjs` 和 `scripts/cleanup-acceptance.mjs` 对正在运行的服务调用真实模型（会消耗额度），需要先设置 `TYPELEAST_LLM_BASE_URL`、`TYPELEAST_LLM_MODEL`、`TYPELEAST_LLM_KEY`。
