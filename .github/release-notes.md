TypeLeast：按一下快捷键说话，语音在你自己的电脑上识别（SenseVoice），再用你自己的大模型 API Key 整理成通顺的文字，直接出现在光标处。

## 这一版有什么新变化（1.3.0）

- **新增「提示词模式」**：设置 → 整理强度里的第三档。把你随口说的需求，整理成一段结构清晰的提示词（角色、背景、任务、要求、语气与受众、输出格式），直接粘贴到 ChatGPT、Claude、DeepSeek 等对话框里使用。数字、日期、人名这类事实只用你说过的，不会编造。
- **提示词模式的系统提示词可以自定义**：默认内容锁定不可改，你可以在结尾追加自己的要求。确实要修改默认内容时，需要经过两次风险提醒并输入验证码；改过之后可以一键恢复默认。

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
