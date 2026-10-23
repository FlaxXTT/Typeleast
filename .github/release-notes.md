TypeLeast：按快捷键说话，本机识别，再用你选择的模型整理文字并插入光标处。

## 1.17.4 的变化

- **Windows 粘贴后恢复剪贴板更可靠。** 等目标程序真正读取了听写文字才把原来的剪贴板放回去，慢的程序和远程桌面不会再粘出旧内容。5 秒内没有程序读取时，听写文字留在剪贴板里，可以手动粘贴。
- **Windows 听写不再因为剪贴板卡顿。** 备份剪贴板放到后台进行；文字、HTML、RTF、文件和图片总是保存，其他格式只在很快读完时保存（超大的 Excel 选区恢复后可能没有公式）。一个超大格式不再导致其他格式丢失，写入中途失败也不会清空你的剪贴板。
- **Windows 卸载**会询问是否同时删除设置、听写历史、录音、语音模型和保存的 API Key（默认保留）。
- 新增[代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)。
- Mac 版本没有功能变化，只是版本号跟随更新。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.17.4-macOS-AppleSilicon.dmg` 或 `.zip` |
| macOS 13 以上，Intel | 已停止更新，使用 [v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.17.4-Windows-x64-Setup.exe`（推荐，支持自动更新）或 `TypeLeast-1.17.4-Windows-x64-Portable.zip` |

已装 1.17.2 及以后版本的可以直接在软件里更新：Mac 在菜单栏图标或「设置 → 本地服务」里点「检查更新」；Windows 安装版默认自动更新，也可以在「设置 → 服务与更新」里点「检查更新」。

**Windows 下载时的风险提示**：安装包没有代码签名，每个新版本刚发布时都没有下载信誉。浏览器可能提示「不常下载」，选「保留」；运行时 SmartScreen 可能提示「Windows 已保护你的电脑」，点「更多信息」→「仍要运行」。安装版之后在软件内更新，不经过浏览器，不会再出现这些提示。`SHA256SUMS.txt` 里有每个文件的校验值。

Mac 构建号为 13。

## 验证与限制

安装包由 Release 工作流在 GitHub 托管的 macOS 和 Windows 机器上从 `main` 构建；发布前跑了服务、Mac 和 Windows 核心测试，并由维护者在 Windows 上实际测试了粘贴和剪贴板恢复。未用私人录音或 API Key 做测试。Mac 安装包未经过 Apple Developer ID 公证，Windows 安装包没有代码签名。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。

Code signing policy: [docs/CODE_SIGNING_POLICY.md](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)（Windows 代码签名正在向 SignPath Foundation 申请，尚未通过）。
