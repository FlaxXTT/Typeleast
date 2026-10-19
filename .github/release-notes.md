TypeLeast：按一下快捷键说话，语音在你自己的电脑上识别（SenseVoice），再用你自己的大模型 API Key 整理成通顺的文字，直接出现在光标处。

## 这一版有什么新变化（1.4.0）

- **中英文界面**：Mac 和 Windows 在「设置 → 语言」中选择跟随系统、简体中文或 English，重启生效。界面语言与听写语言、输出语言独立。
- **听写语言修复**：所选语言会传到识别器；Windows 补齐听写语言选项，并防止并发识别的语言相互干扰。
- **隐私修复**：补齐中文显式密码、密钥、令牌及词典脱敏，损坏请求不回显输入片段，诊断日志减少敏感信息，敏感请求不自动跟随重定向。
- **界面与粘贴修复**：英文设置和统计在小窗口中保持可读；Windows 粘贴前再次确认目标窗口。
- **Mac 软件内更新**：菜单「检查更新…」或「设置 → 版本与更新」。私有仓库下载需要本机 gh 登录，保留权限需要既有本机签名证书；其他用户的发布包仍为 ad-hoc 签名。
- Mac 开始提示音更清脆，设置开关开绿关灰；`promptify.json` 手动修改后下次整理即生效；测试使用假钥匙串。

验证：服务 160 项、Mac 293 项、Windows 102 项测试；三平台 CI 和三种安装包构建通过。Windows 界面未经真机操作验证，未使用私人听写内容调用外部模型。

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
