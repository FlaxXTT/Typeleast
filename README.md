<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/readme/hero-dark.svg">
  <img src="docs/media/readme/hero-light.svg" alt="TypeLeast：说话，得到文字。按一下说话，再按一下，文字写到光标处。" width="880">
</picture>
</p>

<p align="center">
  <a href="https://github.com/FlaxXTT/Typeleast/releases/latest"><picture>  <source media="(prefers-color-scheme: dark)" srcset="docs/media/readme/button-download-dark.svg">  <img src="docs/media/readme/button-download-light.svg" alt="下载最新版" width="141"></picture></a>
  &nbsp;
  <a href="#演示"><picture>  <source media="(prefers-color-scheme: dark)" srcset="docs/media/readme/button-more-dark.svg">  <img src="docs/media/readme/button-more-light.svg" alt="看演示" width="127"></picture></a>
</p>

<p align="center"><sub>macOS 13+ &nbsp;·&nbsp; Windows 10 / 11 &nbsp;·&nbsp; 免费</sub></p>

<p align="center"><a href="https://typeleast.promptking.workers.dev">官网 · Website</a> &nbsp;·&nbsp; <a href="https://www.bilibili.com/video/BV1eQnH6zESN/">B 站视频 · Bilibili</a></p>

<p align="center">免费的 Mac 和 Windows 听写软件。<br>按一下，说话。再按一下，文字写到光标处。<br>语音在<b>你的电脑上</b>识别，文字由<b>你选的模型</b>整理。</p>

<br>

## 提示词模式：说出想法，补充完整需求

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/readme/prompt-dark.svg">
  <img src="docs/media/readme/prompt-light.svg" alt="提示词 Beta：你说项目，它问缺少的信息，你回答并核对它的理解，它写出完整提示词，再删除你没说过的内容。" width="880">
</picture>
</p>

- **提问**：每轮最多 4 个问题，只问缺少的信息。
- **核对**：每次回答后显示它的理解。不对就直接说。
- **生成**：你点「生成」，它才写提示词。

<sub>上图为示例画面，对话是虚构的。</sub>

<br>

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/readme/features-dark.svg">
  <img src="docs/media/readme/features-light.svg" alt="功能：自然整理；音频不出电脑；写到任何输入框；AI 整理；四个本机识别模型；你的 Key。" width="880">
</picture>
</p>

## 演示

<p align="center">
  <a href="docs/media/promo.mp4"><img src="docs/media/promo.gif" alt="24 秒演示：听写写入光标处；提示词 Beta；翻译；三种整理模式；本机识别" width="880"></a>
  <br><sub>24 秒演示 · 点击看 MP4 · <a href="docs/media/promo-en.mp4">English</a></sub>
</p>

<p align="center">
  <a href="docs/media/film-long.mp4"><img src="docs/media/film-long-poster.jpg" alt="72 秒完整演示" width="880"></a>
  <br><sub>72 秒完整演示 · 点击观看</sub>
</p>

<p align="center">
  <img src="docs/media/demo.gif" alt="真实录屏：按 fn 说话，文字写到光标处" width="760">
  <br><sub>真实录屏</sub>
</p>

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/readme/free-dark.svg">
  <img src="docs/media/readme/free-light.svg" alt="免费：不订阅，不注册，不限次数。本机识别免费；整理按你的服务商计费；用 Ollama 完全免费。" width="880">
</picture>
</p>

## 界面

<table>
  <tr>
    <td width="50%"><img src="docs/media/home.png" alt="Mac 首页"></td>
    <td width="50%"><img src="docs/media/history.png" alt="Mac 历史"></td>
  </tr>
  <tr>
    <td align="center"><sub>Mac · 首页</sub></td>
    <td align="center"><sub>Mac · 历史</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/media/windows/settings-light.png" alt="Windows 设置"></td>
    <td width="50%"><img src="docs/media/windows/history-light.png" alt="Windows 历史"></td>
  </tr>
  <tr>
    <td align="center"><sub>Windows · 设置</sub></td>
    <td align="center"><sub>Windows · 历史</sub></td>
  </tr>
</table>

<p align="center">
  <img src="docs/media/windows/recording-bar.gif" alt="录音条" width="540">
  <br><sub>录音条</sub>
</p>

<p align="center"><sub>截图为示例数据。</sub></p>

## 下载

最新版：[**v1.24.7**](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.24.7)

| 电脑 | 文件 |
|---|---|
| Mac · Apple 芯片 | `TypeLeast-<版本>-macOS-AppleSilicon.dmg` |
| Mac · Intel | 不再更新。最终版：[v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |
| Windows 10 / 11（64 位） | `…-Windows-x64-Setup.exe` 或免安装的 `…-Portable.zip` |

<sub>查看芯片： →「关于本机」。安装包已含运行环境。校验值在 `SHA256SUMS.txt`。</sub>

<details>
<summary><b>要求</b></summary>

| | macOS | Windows |
|---|---|---|
| 系统 | macOS 13+ | Windows 11，或 Windows 10 1809+（64 位） |
| 磁盘 | 应用约 450 MB，模型另计 | 同左 |
| 网络 | 首次自行选择模型：0.6B INT8 约 0.99 GB；1.7B FP16 约 4.73 GB。之后识别不联网。 | 同左 |
| 权限 | 麦克风、辅助功能 | 麦克风 |
| 整理模型 | 首次使用须配置可用的 OpenAI 兼容整理模型 | 同左 |

1.7B FP16 在 Mac 上实测加载峰值约 12.5 GiB；不同环境会变化。更新不会自动下载或切换模型。

</details>

<details>
<summary><b>macOS 安装</b></summary>

1. 打开 `.dmg`，把 **TypeLeast** 拖进「应用程序」。
2. 系统拦截时：打开「系统设置 → 隐私与安全性」，点 **「仍要打开」**。或在「终端」运行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/TypeLeast.app
   ```

3. 在新手引导中打开设置，配置整理模型和 API Key，下载并加载识别模型，允许麦克风和辅助功能。
4. 「系统设置 → 键盘 → 按下 🌐 键时」设为「无操作」。
5. 完成三组真实语音练习后进入主界面。仅新用户强制，旧用户可重新学习。

</details>

<details>
<summary><b>Windows 安装</b></summary>

1. 运行 `…-Setup.exe`。浏览器提示时选「保留」。SmartScreen 提示时点 **「更多信息」→「仍要运行」**。
2. 按向导安装。不需要管理员权限。免安装版：解压后运行 `TypeLeast.exe`。
3. 在新手引导中配置整理模型和 API Key，下载并加载识别模型。录不到声音：「设置 → 隐私和安全性 → 麦克风」允许桌面应用。
4. 完成三组真实语音练习后进入主界面。仅新用户强制，旧用户可重新学习。

**卸载**：「设置 → 应用 → 已安装的应用」→ TypeLeast →「卸载」。卸载时可选是否删除数据。免安装版：删除文件夹。

</details>

## Code signing policy

See our [Code signing policy](docs/CODE_SIGNING_POLICY.md).

Windows code signing via SignPath Foundation is currently pending approval.

## 更多

<details>
<summary><b>使用</b></summary>

| | macOS | Windows |
|---|---|---|
| 开始 / 结束 | **Fn（🌐）** 或 ⌥Space | **右 Alt**（可换右 Ctrl、Caps Lock、F8） |
| 取消 | Esc | Esc |
| 粘贴上一条 | ⌃⌘V | Ctrl + Shift + Alt + V |
| 翻译 | ⇧⌥Space | 在设置里选一个键 |
| 提示词模式 | 侧栏按钮或自设快捷键 | 侧栏按钮或自设快捷键 |

- **听写**：结合整段理解，按需要重排和去重复，完整保留事实、用途、条件、数字和否定。无需选择整理档位；单次最长 10 分钟。
- **提示词模式**：通过独立快捷键或按钮进入，多轮补充后主动生成完整需求，不执行口述任务。默认不绑定快捷键。
- **翻译**：一次模型调用完成整理和翻译，支持 10 种目标语言。
- **失败恢复**：不自动插入半截正文或识别原文；可重试、查看修改、使用识别原文或取消，无需重新录音。
- **术语纠正**：听错的专有名称、缩写和术语按全文语境改对；识别结果本身合理时照写。每次纠正的术语和你的意图记入历史，App 每次启动时据此写一段你的使用场景描述，帮助之后的整理。清空历史时一起清除。
- **语言**：简体、台湾繁体、香港繁体。界面语言在设置里改，重启后生效。
- **历史**：加密存在本机。

</details>

<details>
<summary><b>识别模型</b></summary>

在「设置 → 服务与更新」下载并使用。下载时可以继续听写。

| 模型 | 适合 | 大小 |
|---|---|---|
| **SenseVoice Small**（默认） | 中、英、粤、日、韩。小而快。 | 0.24 GB |
| **FireRedASR2 CTC** | 中文和方言，也支持英文 | 0.78 GB |
| **Fun-ASR-Nano** | 中英混说，也支持日语 | 1.01 GB |
| **Qwen3-ASR-0.6B** | 多语言。中文可能输出繁体。 | 0.99 GB |

<sub>大模型更慢，占用 2–3 GB 内存。来源和许可：[第三方说明](THIRD-PARTY-NOTICES.md)。</sub>

</details>

<details>
<summary><b>整理模型和 API Key</b></summary>

| 服务商 | 接口地址 | Key |
|---|---|---|
| DeepSeek | `https://api.deepseek.com` | platform.deepseek.com |
| 智谱 GLM | `https://open.bigmodel.cn/api/paas/v4` | open.bigmodel.cn |
| Kimi | `https://api.moonshot.cn/v1` | platform.moonshot.cn |
| 通义千问 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | dashscope.console.aliyun.com |
| OpenRouter | `https://openrouter.ai/api/v1` | openrouter.ai |
| OpenAI | `https://api.openai.com/v1` | platform.openai.com |
| 本机 Ollama | `http://127.0.0.1:11434/v1` | 不需要 |
| 自定义 | 任何 OpenAI 兼容地址 | — |

- DeepSeek 模型 ID：`deepseek-flash`。`deepseek-chat` 和 `deepseek-reasoner` 已停用。
- 接口地址不要写 `/chat/completions`。
- 远程地址必须用 https。http 只用于本机。
- Key 存在钥匙串（Mac）或凭据管理器（Windows），不写入文件或日志。
- 费用由你的服务商收取。

</details>

<details>
<summary><b>隐私</b></summary>

- **音频不上传。** 识别后删除。开启「保留录音」时，加密保存约 5 分钟，用于重试。
- **发给模型的内容**：识别出的文字，以及从历史学到的使用场景描述（不超过 1000 字）。每次启动生成描述时，发送历史里的术语纠正和意图，不发送正文。开启「参考光标附近的文字」时，加上光标附近的文字和窗口标题。像密钥和密码的内容先删除。
- **剪贴板**：粘贴时使用剪贴板，之后恢复。剪贴板工具可能会记录文字。
- **本机服务**：只监听 `127.0.0.1`，每个请求要带本机令牌。

| | macOS | Windows |
|---|---|---|
| 设置、历史、日志 | `~/Library/Application Support/TypeLeast/`、`~/Library/Logs/TypeLeast/` | `%APPDATA%\TypeLeast\` |
| 语音模型 | `~/Library/Application Support/TypeLeast/models/` | `%LOCALAPPDATA%\TypeLeast\models\` |
| API Key | 钥匙串：`TypeLeast.llm-api-key` | 凭据管理器：`TypeLeast.llm-api-key/…` |

</details>

<details>
<summary><b>常见问题</b></summary>

**本地服务未就绪**：「设置 → 本地服务」→「重新启动」。源码构建需要 Node.js 22+。

**模型下载失败**：使用镜像 `https://hf-mirror.com`（点「用镜像重试」）。或手动下载以下文件，放进模型文件夹：

| 文件 | 位置 | 大小（字节） |
|---|---|---|
| `https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx` | `models/sensevoice/model.int8.onnx` | 239,233,841 |
| `https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt` | `models/sensevoice/tokens.txt` | 315,894 |
| `https://huggingface.co/csukuangfj/vad/resolve/main/silero_vad.onnx` | `models/vad/silero_vad.onnx` | 1,807,522 |

**Mac 没有粘贴**：「系统设置 → 隐私与安全性 → 辅助功能」打开 TypeLeast。更新后可能要重新打开。

**Mac 按 Fn 切换了输入法**：「按下 🌐 键时」设为「无操作」。

**Windows 录不到声音**：允许桌面应用使用麦克风，并在 TypeLeast 里选对设备。

**Windows 右 Alt 没反应**：可能是 AltGr 或被占用。换一个键。

**Windows 粘贴失败**：管理员窗口不接受模拟按键。按 Ctrl+V。

**杀毒软件提示风险**：TypeLeast 用键盘钩子检测快捷键，且没有签名。它只检测快捷键和 Esc，不记录输入。

</details>

<details>
<summary><b>从源码构建</b></summary>

| | macOS | Windows |
|---|---|---|
| 通用 | Git、Node.js 22+ | 同左 |
| 编译 | `xcode-select --install` | [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) |
| 打包 | 系统自带 | [Inno Setup 6](https://jrsoftware.org/isinfo.php) |

本地服务：

```bash
cd service
npm ci
npm test
npm run setup-models
npm start
```

镜像：`HF_ENDPOINT=https://hf-mirror.com npm run setup-models`。

验收测试：[跨语言验收契约](tests/conformance/README.md)。只连本机假模型，不下载语音模型。

macOS：

```bash
cd apps/macos
./make-signing-cert.sh   # 只需一次
./test.sh
./build.sh
./package.sh arm64
```

Windows：

```powershell
cd apps\windows
dotnet run --project TypeLeast.Core.Tests -c Release
dotnet build TypeLeast\TypeLeast.csproj -c Release
.\package.ps1
```

开发时使用仓库里的服务：`$env:TYPELEAST_SERVICE_DIR="<仓库路径>\service"`。

媒体文件：

- README 动图：`python3 docs/media/readme/make_readme_art.py`
- Windows 截图：`apps/windows/Tools/MediaRenderer/make-media.sh`
- Mac 截图：`apps/macos/Tools/render.sh`
- 演示影片：`node site/record-film.mjs`（需要 Playwright 和 ffmpeg）
- 真实录屏：`apps/macos/Tools/demo/record-demo.sh <输出目录>`

发布：手动运行 Release 工作流，指定标签，先建草稿，核对后发布。

| 目录 | 内容 |
|---|---|
| [`service/`](service/) | 本地服务（Node.js）：识别、整理、翻译、使用场景描述 |
| [`apps/macos/`](apps/macos/) | macOS App（Swift） |
| [`apps/windows/`](apps/windows/) | Windows App（C# / WPF） |
| [`site/`](site/) | 官网 |
| [`docs/`](docs/) | 开发和发布记录 |

</details>

<details>
<summary><b>许可</b></summary>

[GNU GPL v3.0](LICENSE)。可以使用、修改和再分发。修改后发布的版本也必须用 GPL-3.0。

按 GPL-3.0 第 15、16 条，TypeLeast 按「现状」提供，不附带任何担保。模型生成的结果可能出错，使用前请核对。

第三方组件见 [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。

</details>
