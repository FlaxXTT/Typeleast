TypeLeast：按一下快捷键说话，语音在你自己的电脑上识别（SenseVoice），再用你自己的大模型 API Key 整理成通顺的文字，直接出现在光标处。

## 这一版有什么新变化（1.5.0）

- **可选识别模型**：「设置 → 识别模型」里除了默认的 SenseVoice Small，还可以下载并启用三个本机模型，点一下就能用，不用手动解压或填路径：
  - **FireRedASR2 CTC**（约 0.78 GB）：偏向中文和方言，也支持英文；自动检测语言。
  - **Fun-ASR-Nano**（约 1.01 GB）：适合中英混合听写，也支持日语；可以指定中文、英文或日语。
  - **Qwen3-ASR-0.6B**（约 0.99 GB）：多语言识别，可以指定中文、英文、粤语、日语或韩语；对中文可能输出繁体字。
- 下载时继续用当前模型；每个文件都核对 SHA-256，加载成功后才切换，失败会保留当前模型。可以取消下载，已校验的文件下次复用。
- 修复连续切换听写语言时内存持续增长的问题。

候选模型比 SenseVoice 大，识别和切换更慢、占用内存更多（约 2–3 GB）。样例很少，不代表准确率排名，请按自己的语音试用。

验证：服务 173 项、Mac 308 项、Windows 117 项测试；三平台 CI、真实模型加载和识别测试、三种安装包构建通过。四个模型在 Mac 上实测加载、识别和来回切换。Windows 界面未经真机操作验证；没有使用私人听写内容。

完整的版本历史见 [CHANGELOG.md](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。

## 下载哪个

| 系统 | 文件 |
|---|---|
| macOS 13 以上，Apple 芯片（M1 及以后） | `TypeLeast-…-macOS-AppleSilicon.dmg` |
| macOS 13 以上，Intel 芯片 | `TypeLeast-…-macOS-Intel.dmg` |
| Windows 11 / Windows 10（1809 以上），64 位 | `TypeLeast-…-Windows-x64-Setup.exe`（安装版）或 `…-Portable.zip`（解压即用） |

安装包里已经带好 Node.js 和本地识别引擎，不需要另外安装任何东西。第一次打开时，App 会下载一次语音模型（约 241 MB，每个文件都校验 SHA-256）。

## 第一次打开

- **macOS**：把 TypeLeast 拖进「应用程序」。这个版本没有 Apple 开发者签名，第一次打开会被拦下：到「系统设置 → 隐私与安全性」底部点「仍要打开」。也可以在终端运行 `xattr -dr com.apple.quarantine /Applications/TypeLeast.app` 后再打开。然后按提示允许麦克风和辅助功能。
- **Windows**：安装包没有代码签名，SmartScreen 可能提示「Windows 已保护你的电脑」：点「更多信息 → 仍要运行」。安装不需要管理员权限。如果录不到声音：设置 → 隐私和安全性 → 麦克风 → 允许桌面应用访问麦克风。

## 整理模型

在 App 的「设置 → 整理模型」里选服务商（DeepSeek、智谱、Kimi、通义千问、OpenRouter、OpenAI 或本机 Ollama）、填 API Key 和模型，点「测试连接」。Key 只保存在系统的钥匙串 / 凭据管理器里。不填 Key 也能听写，只是不改写。

文件校验值见 `SHA256SUMS.txt`。
