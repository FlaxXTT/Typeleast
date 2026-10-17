# 语音听写润色（dsh-voice-polish + dsh-voice）

把 DSH 里"录音→原文"的语音输入，升级成"**录音 → 结合上下文的纠错/排版/提示词化整理 → 自动插入任意软件的光标处**"。

两部分组成，职责不重叠：

| 组件 | 位置 | 职责 |
|---|---|---|
| **宿主插件**（后台引擎，无界面） | `dsh-voice-polish/` 挂载在 DSH 里 | 本地 SenseVoice 转写 → 大模型整理 → 校验/回落；提供回环 HTTP 接口与历史 |
| **菜单栏小程序** | `dsh-voice/native/macos/` → 已安装到 `~/Applications/TypeLeast.app` | 全局热键、录音、把结果粘贴到前台应用 |

零新增下载：转写复用你已装的 SenseVoice 模型，整理复用你已登录的 `deepseek-account`；小程序只用 macOS 自带框架。

---

## 1. 现在就能用（已部署）

宿主插件已经挂进你的 desktop profile，DSH **无需重启就被热加载**（已实测：`/api/voice-polish/health` 在线返回 `ok:true`）。

打开小程序：

```sh
open ~/Applications/TypeLeast.app
```

第一次要做三件事：

1. **热键**：默认**单按 Fn** 开始/结束，⌥Space 是备用键；可在设置里改成任意组合。
2. **麦克风授权**：第一次录音时 macOS 会弹窗，允许即可。
3. **辅助功能授权**（想自动粘贴才需要）：菜单栏里常驻一行「**需要辅助功能权限（自动粘贴）· 点此申请**」，点它会自动重置权限记录、弹出系统对话框并打开设置页——所以**误点拒绝也能一键回来**。授权后这一行变成「辅助功能已授权 · 打开设置」。

> 权限被拒过一次后是**粘性**的：macOS 不会再自动弹窗，必须靠上面那一行重置 + 手动开开关。这就是我把它做成常驻菜单项的原因。

---

## 2. 用法（2026-10-17 起：Typeless 风格界面）

| 操作 | 效果 |
|---|---|
| 单按 **Fn**（同 Typeless；⌥Space 为备用，可在设置里改） | 开始录音；再按一次结束并整理 |
| 录音中按 Esc，或点语音条上的 ✕ | 取消并丢弃；点 ■ 结束并整理 |
| ⌃⌘V | 粘贴上一条转写（同 Typeless「Paste last transcript」） |
| 录音上限 | 120 秒，最后 15 秒语音条显示倒计时 |
| 整理中 | 语音条三点呼吸动画；超时（默认 12s）、模型出错或输出没通过校验 → 用**去掉口水词的原文**插入并标注（原因见第 6 节） |
| 主窗口 | 首页（字数、节省时间、语速、次数）/ 历史（按天分组、搜索、复制、用同一段录音重试、删除、保留时长）/ 词典（全部·自动添加·手动添加、新词、导入 CSV）/ 设置 |

**插入**：写剪贴板 → 模拟 ⌘V → 0.6s 后还原剪贴板。在备忘录、邮件、Pages、Word、TextEdit、Notion 里，编号列表以 HTML/RTF 粘贴，成为真正的列表；其他 App 拿到纯文本 `1. …`。密码框（安全输入）只放到剪贴板。

**输入框上下文**（对标 Typeless 的 `ax_text`）：开始听写时用辅助功能读取光标前约 600 字、后约 200 字、选中文字和窗口标题，base64(JSON) 放在 `x-voice-context` 头里发给宿主，宿主截断、脱敏后作为 `fieldContext` 交给模型，用来纠正同音字、人名和术语。密码框和密码管理器不读。只有往 DSH 自己里听写时才附带 DSH 聊天记录。

**自动学词**：粘贴后若你在 3 分钟内改了某个词，且改动「听起来像」原词（拼音/字母/声母相似，`明天→后天` 这类内容修改不算），就把改后的词作为「自动添加」放进词典，并 `PUT /dictionary` 同步给宿主。

**语音条**（底部居中的深色胶囊）：空闲时可显示一个常驻小条（悬停显示快捷键，点击开始听写）；录音时 ✕ + 波形 + ■；整理中三点；结束显示对勾和前 40 字后淡出。全部是 `.nonactivatingPanel`，**永不抢焦点**。

---

## 2.5 提示词：只用 erduo「Budget Typeless DIY」

模型收到的 system prompt 是 <https://erduo.dev/en/blog/diy-typeless-asr-prompt/>（2026-01-16，V2）这篇文章里的提示词**原文**，外加文中两条定义 JSON 输出格式的示例；temperature 0.8。来源和许可见 [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)。原文没有写开源许可，只限个人使用。原来的内置提示词（三档强度、列表检测、按 App 调语气、常见英文词表）已按用户要求删除。

- **用户消息**：只有识别出的原文，和文章的用法一致。
- **补充段**（`=== HARNESS ADDENDUM ===`）：只放词典和光标附近的文字，并且只在有内容时追加；没有内容时，system prompt 与原文逐字一致。
- **输出格式**：模型应返回 `{"status":"ok","text":"…","reason":"…"}`，只插入 `text`。解析依次尝试「严格 JSON → 提取 text 字段 → 当作纯文本」，**绝不会把花括号插进文档**；全部失败时退回原文，并记为 `output-format`。
- **风格**：erduo 的思路是「清理，而不是改写」。说出来的要点会保留成一段话，不会自动编号；中英文之间加空格，发音相近的词改成正确的英文术语。

---

## 3. 整理强度

| 档位 | 行为 |
|---|---|
| `prompt`（默认，App 里叫「Erduo 整理」） | 用 erduo 提示词整理 |
| `off`（App 里叫「原话转写」） | 不调用模型，只在本机去口水词 |
| `conservative` / `maximal` | 仍可通过 API 使用，同样用 erduo 提示词，只改变校验的严格程度；App 里不再提供 |

**安全阀**：
- 严禁新增事实/数字/日期/人名/承诺——提示词写死，并且有**编造事实检测**：新出现的数字、日期词、标识符一律判为编造。列表序号 `1.`、`2）`、`3、`、序数词「第二点」、与条目数一致的「以下三点」、以及「两个 ↔ 2 个」这种数字写法互换都**不算**编造。
- 细粒度 novelty 阈值按档位：conservative 0.45 / prompt 0.7 / maximal 0.8；另有语言被改、截断、过长检查。
- 被**谈论**的口水词（加引号或用顿号列举的「呃、嗯」）会保留，不会删成「、啊、」。
- 回落给的都是经过 tidy 的原文；每次回落都写进历史，带 `reason` 和 `detail`。

---

## 4. 配置

只能改 `~/.dsh/profiles/desktop/cordis.patch.yml`。DSH 设置页里**没有** voice-polish 的表单，这是故意的：插件的 `Config` 不能带 `toJSON()`，否则 DSH 设置服务会把它当 Schemastery 处理并抛 `TypeError`，桌面窗口启动时直接崩溃（「desktop welcome: Web RPC failed」）。

```yaml
- insert:
    - id: voice-polish
      name: /path/to/dsh-voice/dsh-voice-polish/lib/index.js   # 换成你本机的绝对路径
      config:
        provider: deepseek-account   # 模型路由
        model: deepseek-flash        # 模型
        reasoningEffort: "off"       # 加引号：YAML 1.1 会把裸 off 读成 false；off | low | high | max | default；思考 token 计入 maxOutputTokens(800)，default=沿用路由默认（DeepSeek 是 high）
        timeoutMs: 12000             # 整理超时（超时回落原文；代码默认 12000，低于 6000 插件加载失败）
        strength: prompt             # off | conservative | prompt
        language: auto               # auto | zh | en | yue | ja | ko
        contextTurns: 6              # 参考最近几轮对话
        contextChars: 4000           # 上下文长度上限
        historyDays: 14              # 历史保留天数
        dictionary: []               # 强约束拼写，如 ["DSH", "第四批=DSH"]
        redactSecrets: true          # 发模型前抹掉密钥形状的字符串
        logRaw: true                 # false 则历史只存 sha256
```

数据落在 `~/.dsh/voice-polish/`：`api-token`（0600）、`history.jsonl`、`dictionary.json`。
音频不出本机；只把**转写文本**和少量最近上下文发给模型；不采集屏幕、选中文本或剪贴板内容。

---

## 5. 验证

```sh
# 在仓库根目录下运行。
# 单元测试（142 项，零网络）：任意 Node 22+，macOS / Windows 都可以；
# 测试路径加了引号，由 Node 自己展开，不依赖 shell。
cd dsh-voice-polish
node --test --test-reporter=spec "test/*.test.js"
# 没装 Node 时，macOS 上可以用 DSH 自带的：
# "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/primary-runtime/dependencies/node/bin/node" --test "test/*.test.js"

# 原生端测试（224 项，只能在 macOS 上跑）
cd ../dsh-voice/native/macos && ./test.sh

# 端到端：需要先按 scripts/e2e-probe.mjs 顶部注释起一个隔离 harness
```

已实测结果：单元 115/115 通过、原生 189/189 通过（2026-10-17，Typeless 风格界面、列表/序数/上下文/自动学词之后）；线上（reasoningEffort=off）整理约 0.8–1.2s；端到端 21/21 通过（真实 SenseVoice 转写 + 真实 `deepseek-flash` 整理，整理耗时约 1.9s）。

---

## 6. 排错

| 现象 | 原因 / 处理 |
|---|---|
| 按热键没反应 | Fn 单键不可靠，用 ⌥Space；或在设置里录制别的组合 |
| 提示「已粘贴（未验证）」 | 这是**信息不是错误**：⌘V 已发出但无法确认送达。若文字没出现，按 ⌘V，或在菜单里申请辅助功能权限 |
| 按了申请权限但没弹对话框 | 菜单栏 →「打开辅助功能设置」，手动把 dsh-voice 开关打开 |
| 菜单栏"整理服务未运行" | DSH 没开；点"启动 DSH" |
| 文字是原文、菜单标注"已用原文" | 看 `/health` 的 `recentFailures`，或历史里的 `reason` + `detail`（原因对照见下表） |
| 说中文却提示需重试 | `health` 里 `ready:false` 说明模型在准备，稍等或看设置里的状态面板 |

**回落原因（`fallbackReason` / 历史里的 `reason`）：**

| reason | 含义 |
|---|---|
| `model-timeout` | 超过 `timeoutMs`，由插件自己的截止时间中止（不重试） |
| `model-max-tokens` | 模型输出到了 `maxOutputTokens`（800）上限，被截断。思考 token 也算在这 800 里，所以先确认 `/health` 的 `reasoningEffort` 是 `off` |
| `model-tool-calls` | 模型意外请求调用工具 |
| `model-error:<code>` | provider 或网络报错。`<code>` 依次取错误的 `code`、`cause.code`、`http-<状态码>`、错误名，都没有就是 `unknown`；错误本身的 code 或信息像网络/限流错误时，会等 300 ms 重试一次 |
| `cancelled` | 调用方中途取消 |
| `internal-error` | 插件自己的整理/校验代码抛了异常（不是模型的问题） |
| `invented-fact`、`invented-content`、`output-too-short`、`output-too-long`、`language-changed`、`semantic-drift`、`empty-output` | 模型答了，但没通过校验 |
| `empty-transcript` | 转写为空，没有调模型 |

`detail` 是一行明细：模型出错时是错误信息（带上 cause 链），以及尝试次数和模型调用耗时，例如 `model output hit its token limit (4712 ms)`；校验不通过时只有指标，例如 `ratio=1.42 coverage=0.61 novelty=0.52 inventedFacts=1`，不含任何口述内容。

**`/health` 里的排查字段**（只是新增，原有字段不变；需要重启 DSH 才会加载新代码，用 `pid` 确认）：

- `reasoningEffort`：整理调用用的推理档位配置。配成 `default`，或者路由回落到别的 provider 时，实际不传档位。
- `stats`：`dictations`/`polished`/`fallback`/`lastMs` 只统计 `/dictate`；`modelCalls`/`modelFallbacks` 统计所有调到模型的整理（包括 `/polish`）；`lastError` 是最近一次模型异常的 `reason: detail`。
- `recentFailures`：最近 5 次调到模型后回落的记录，最新的在前，每条是 `{ts, reason, detail, app, strength, ms}`，不含口述文本。

```sh
PORT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.dsh/voice-polish/runtime.json")))["port"])')
curl -s -H "Authorization: Bearer $(cat ~/.dsh/voice-polish/api-token)" \
  http://127.0.0.1:$PORT/api/voice-polish/health | python3 -m json.tool
```

---

## 7. 回滚

- **停用润色**：删掉 `~/.dsh/profiles/desktop/cordis.patch.yml` 里那个 `- insert:` 块（改之前先自己备份一份）。DSH 会热加载，恢复原来只有转写的行为。
- **卸载小程序**：退出菜单栏图标，删掉 `~/Applications/TypeLeast.app`。
- 全程**没有改动** `app.asar`，DSH 升级不受影响。

---

## 8. 已知边界

- 需要 DSH 在运行（转写和模型都在它进程里）；这是换取"零新增模型/零新增凭据"的代价。
- 不做：翻译模式、选中文本问答、生成式写作、跨设备同步、云端转写；不支持 Windows/Linux。
- 首次使用若麦克风权限弹窗被拒绝，需去系统设置里手动允许 `dsh-voice`。
