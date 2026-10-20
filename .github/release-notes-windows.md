TypeLeast：按快捷键说话，本机识别，再用你自己的整理模型处理文字并插入光标处。

这是 **Windows 单独发布**。Mac 版本仍是 [1.16.0](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.16.0)，本次没有 Mac 安装包。GitHub 的「最新版本」标记留给 Mac；Windows 的「检查版本」只找带 Windows 安装包的发布。

## Windows 1.16.1 的变化

- 界面按 Mac 结构对齐：首页、历史、词典、设置；跟随系统、浅色和深色主题。
- 历史：保留时长、筛选、搜索；可选择加密保留录音 24 小时，用同一录音重试。
- 词典：手动和自动来源、「听成」写法、CSV 导入预览。
- 插入：自动粘贴、仅复制、先预览；修复多数情况下只复制、没有粘贴到光标处的问题。
- 细的圆角滚动条；任务栏右键菜单使用 TypeLeast 配色。
- 处理中可以取消；整理失败时显示分类原因，不记录正文和 Key。
- 麦克风测试、录音时静音其他声音、新手引导、桌面常驻小语音条。
- DeepSeek 官方预设的模型提示改为 `deepseek-flash`。已保存的模型不自动改写。

完整变化见 [CHANGELOG.md](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。

## 下载

| 系统 | 文件 |
|---|---|
| Windows 11 / Windows 10（1809 以上），64 位 | `TypeLeast-1.16.1-Windows-x64-Setup.exe`（安装版）或 `…-Portable.zip`（解压即用） |

安装不需要管理员权限。安装包没有代码签名，SmartScreen 可能提示「Windows 已保护你的电脑」：点「更多信息 → 仍要运行」。安装包中的识别引擎需要 Microsoft Visual C++ 运行库；如果识别无法启动，请安装 Microsoft 的 Visual C++ Redistributable（x64）。

## 验证范围

安装包在 Linux 上用 Microsoft .NET 8 SDK 和 wine 中的 Inno Setup 6.7.3 构建，没有使用 GitHub Actions。Windows Core 509 项、服务 204 项测试通过（1 项因没有识别模型而跳过）。wine 中静默安装和内置本地服务启动通过。Windows 真机安装、界面、麦克风和整理流程在发布前由维护者在 Windows 上验证。

文件校验值见 `SHA256SUMS.txt`。
