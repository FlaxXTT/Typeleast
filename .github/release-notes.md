TypeLeast：按快捷键说话，本机识别，再用你选择的模型整理文字并插入光标处。

## 1.17.3 的变化

- **Mac 更新时 API Key 不再落盘。** 软件内更新时，旧版本先核对新版本的代码签名指纹，再经进程间管道把钥匙串条目（API Key 和历史加密密钥）直接交给新版本，不再写临时文件。从 1.17.2 升级到这一版时，交接仍由 1.17.2 用原来的方式完成一次，新版本启动后马上恢复并删除那个文件；有条目恢复失败时保留文件、下次启动重试，不会弄丢 Key 和旧历史。
- **开机自启更可靠。** Mac：在「系统设置 → 通用 → 登录项」里关掉过 TypeLeast 时，打开「开机时启动」会直接带你去那里允许。Windows：「设置 → 通用 → 登录启动」和 Windows 的实际设置一致，在任务管理器里关掉后开关也显示为关，在 TypeLeast 里重新打开会真正生效；便携版换了文件夹后自动指向新位置。
- **隐私与安全**：整理模型返回的异常内容不再写进诊断日志和历史；本地服务重启时不再信任旧端口；Mac「历史 → 不保存」立即清除已有记录，也不再保留录音；本地服务的词典和提示词文件只有当前用户可读。
- **更新更稳**：提示词 Beta 进行中不会被更新打断；Mac 旧版本所在的文件夹没有写权限时，更新失败也不会删掉旧版本；Windows 同一版本自动下载失败后，本次运行不再反复重下。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.17.3-macOS-AppleSilicon.dmg` 或 `.zip` |
| macOS 13 以上，Intel | 已停止更新，使用 [v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.17.3-Windows-x64-Setup.exe`（推荐，支持自动更新）或 `TypeLeast-1.17.3-Windows-x64-Portable.zip` |

已装 1.17.2 的可以直接在软件里更新：Mac 在菜单栏图标或「设置 → 本地服务」里点「检查更新」；Windows 安装版默认自动更新，也可以在「设置 → 服务与更新」里点「检查更新」。从 1.17.1 及更早的 Windows 版本需要手动安装一次。

**Windows 下载时的风险提示**：安装包没有代码签名，每个新版本刚发布时都没有下载信誉。浏览器可能提示「不常下载」，选「保留」；运行时 SmartScreen 可能提示「Windows 已保护你的电脑」，点「更多信息」→「仍要运行」。安装版之后在软件内更新，不经过浏览器，不会再出现这些提示。`SHA256SUMS.txt` 里有每个文件的校验值。

Mac 构建号为 12。

## 验证与限制

安装包由 Release 工作流在 GitHub 托管的 macOS 和 Windows 机器上从 `main` 构建；发布前在本机运行了服务、Mac 和 Windows 核心测试。未用私人录音或 API Key 做测试。Mac 安装包未经过 Apple Developer ID 公证，Windows 安装包没有代码签名。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。

Code signing policy: [docs/CODE_SIGNING_POLICY.md](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)（Windows 代码签名正在向 SignPath Foundation 申请，尚未通过）。
