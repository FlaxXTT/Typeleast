TypeLeast：按快捷键说话，本机识别，再用你选择的模型整理文字并插入光标处。

## 1.17.9 的变化

这一版主要做减法，功能不变：

- **词典随每次听写发送**：刚改的词立刻生效，不再出现「词典尚未同步」。
- **本地服务不再记录听写历史**：没有任何地方读取它；历史只在 App 里加密保存。旧版本留下的历史和词典副本会在启动时删除。
- **删除不再使用的接口和兜底**：服务的 `/learn`、`/history`、`/dictionary`，Mac 更新时借用 GitHub 命令行工具的兜底，以及两个旧的本地发版脚本。
- **Windows 更省电**：不再每 3 秒检查一次本地服务，平时每 30 秒，服务启动或模型下载时才频繁检查。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.17.9-macOS-AppleSilicon.dmg` 或 `.zip` |
| macOS 13 以上，Intel | 已停止更新，使用 [v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.17.9-Windows-x64-Setup.exe`（推荐，支持自动更新）或 `TypeLeast-1.17.9-Windows-x64-Portable.zip` |

已装 1.17.2 及以后版本的可以直接在软件里更新：Mac 在菜单栏图标或「设置 → 本地服务」里点「检查更新」；Windows 安装版默认自动更新，也可以在「设置 → 服务与更新」里点「检查更新」。

**Windows 下载时的风险提示**：安装包没有代码签名，每个新版本刚发布时都没有下载信誉。浏览器可能提示「不常下载」，选「保留」；运行时 SmartScreen 可能提示「Windows 已保护你的电脑」，点「更多信息」→「仍要运行」。安装版之后在软件内更新，不经过浏览器，不会再出现这些提示。`SHA256SUMS.txt` 里有每个文件的校验值。

Mac 构建号为 18。

## 验证与限制

安装包由 Release 工作流在 GitHub 托管的 macOS 和 Windows 机器上从 `main` 构建；发布前跑了服务、Mac 和 Windows 核心测试，本地服务和两端的改动都有自动测试。未用私人录音或 API Key 做测试。Mac 安装包未经过 Apple Developer ID 公证，Windows 安装包没有代码签名。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。

Code signing policy: [docs/CODE_SIGNING_POLICY.md](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)（Windows 代码签名正在向 SignPath Foundation 申请，尚未通过）。
