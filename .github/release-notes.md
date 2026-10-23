TypeLeast：按快捷键说话，本机识别，再用你选择的模型整理文字并插入光标处。

## 1.17.7 的变化

- **更新有进度条了**（Mac 和 Windows）：下载时显示进度和已下载 / 总大小，之后依次显示核对、签名、交接 Key、安装，不会再像卡住了一样。从 1.17.7 往后的更新才会显示这个窗口。
- **Mac 发现新版本会主动提示**：启动后检查到新版本会弹出提示（每个版本只提示一次），开着的 Mac 每 6 小时再检查一次。
- **词典「建议加入」**：整理模型把识别错的专有名词改对时（比如「德普西克」→「DeepSeek」），会出现在词典页的「建议加入」里，点「加入」或「忽略」。浏览器、微信这类读不到输入框的程序也有效。
- **历史里选中文字，右键「加入词典」。**

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.17.7-macOS-AppleSilicon.dmg` 或 `.zip` |
| macOS 13 以上，Intel | 已停止更新，使用 [v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.17.7-Windows-x64-Setup.exe`（推荐，支持自动更新）或 `TypeLeast-1.17.7-Windows-x64-Portable.zip` |

已装 1.17.2 及以后版本的可以直接在软件里更新：Mac 在菜单栏图标或「设置 → 本地服务」里点「检查更新」；Windows 安装版默认自动更新，也可以在「设置 → 服务与更新」里点「检查更新」。

**Windows 下载时的风险提示**：安装包没有代码签名，每个新版本刚发布时都没有下载信誉。浏览器可能提示「不常下载」，选「保留」；运行时 SmartScreen 可能提示「Windows 已保护你的电脑」，点「更多信息」→「仍要运行」。安装版之后在软件内更新，不经过浏览器，不会再出现这些提示。`SHA256SUMS.txt` 里有每个文件的校验值。

Mac 构建号为 16。

## 验证与限制

安装包由 Release 工作流在 GitHub 托管的 macOS 和 Windows 机器上从 `main` 构建；发布前跑了服务、Mac 和 Windows 核心测试，进度窗口、建议加入和历史加词的界面没有在真机上自动测试。未用私人录音或 API Key 做测试。Mac 安装包未经过 Apple Developer ID 公证，Windows 安装包没有代码签名。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。

Code signing policy: [docs/CODE_SIGNING_POLICY.md](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)（Windows 代码签名正在向 SignPath Foundation 申请，尚未通过）。
