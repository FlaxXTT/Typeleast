TypeLeast：按快捷键说话，本机识别，再用你选择的模型整理文字并插入光标处。

## 1.17.8 的变化

- **国内更新不再卡住**（Mac 和 Windows）：GitHub 下载 15 秒没有新数据，自动换到公共 GitHub 加速镜像（ghfast.top、gh-proxy.com、gh-proxy.org、gh.llkk.cc）。校验值始终从 GitHub 官方获取，镜像给的文件对不上就换下一条，被改动的文件不会安装。进度窗口显示正在从哪里下载。
- **设置里新增「更新下载源」**：自动 / 只用 GitHub / 优先镜像。
- 这个功能从 1.17.8 往后的更新才生效。1.17.7 及更早的版本如果在软件内更新时卡住（Windows 显示「正在下载并校验更新」），请手动下载安装一次本版本。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.17.8-macOS-AppleSilicon.dmg` 或 `.zip` |
| macOS 13 以上，Intel | 已停止更新，使用 [v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.17.8-Windows-x64-Setup.exe`（推荐，支持自动更新）或 `TypeLeast-1.17.8-Windows-x64-Portable.zip` |

已装 1.17.2 及以后版本的可以直接在软件里更新：Mac 在菜单栏图标或「设置 → 本地服务」里点「检查更新」；Windows 安装版默认自动更新，也可以在「设置 → 服务与更新」里点「检查更新」。

**Windows 下载时的风险提示**：安装包没有代码签名，每个新版本刚发布时都没有下载信誉。浏览器可能提示「不常下载」，选「保留」；运行时 SmartScreen 可能提示「Windows 已保护你的电脑」，点「更多信息」→「仍要运行」。安装版之后在软件内更新，不经过浏览器，不会再出现这些提示。`SHA256SUMS.txt` 里有每个文件的校验值。

Mac 构建号为 17。

## 验证与限制

安装包由 Release 工作流在 GitHub 托管的 macOS 和 Windows 机器上从 `main` 构建；发布前跑了服务、Mac 和 Windows 核心测试，镜像换线只在本机测过镜像可用性，没有在国内网络上实测。未用私人录音或 API Key 做测试。Mac 安装包未经过 Apple Developer ID 公证，Windows 安装包没有代码签名。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。

Code signing policy: [docs/CODE_SIGNING_POLICY.md](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)（Windows 代码签名正在向 SignPath Foundation 申请，尚未通过）。
