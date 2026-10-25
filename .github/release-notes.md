TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 选繁体时，日文不再被转换。
- Mac：开启静音时，开始提示音可以听到。
- Mac：可以删除保存的 API Key。
- Windows：长中文输入框的上下文不再丢失；取消预览后悬浮条正常消失；「粘贴上一条」改为 Ctrl+Shift+Alt+V。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- With Traditional Chinese selected, Japanese text is no longer converted.
- Mac: the start sound plays when mute is on.
- Mac: you can delete a saved API key.
- Windows: context from long Chinese fields is kept; cancelling the preview clears the bar; Paste last is now Ctrl+Shift+Alt+V.
<!-- /typeleast-update -->

**繁体转换：** 只转换中文。含假名的文字（日文）和译成其他语言的结果保持原样。

**Mac：** 「听写时静音」在开始提示音播完后才静音。API Key 输入框清空后，按钮变为「删除」，点击删除钥匙串里的 Key。

**Windows：** 光标附近的中文按 UTF-8 发送，长输入框不再超出上限被丢弃。插入方式为「先预览」时，取消后显示「已取消」。「粘贴上一条」默认改为 Ctrl + Shift + Alt + V；原来的默认值自动迁移一次，在设置里仍可选回 Ctrl + Shift + V。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.21.1-macOS-AppleSilicon.dmg` 或 `.zip` |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.21.1-Windows-x64-Setup.exe`（安装版，支持软件内更新）或 `TypeLeast-1.21.1-Windows-x64-Portable.zip` |
| Intel Mac | 不再更新。最终版：[v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |

已安装的用户可在软件内更新。Mac 构建号为 26。

## 验证与限制

服务、Mac 和 Windows 测试通过。提示音、预览取消和快捷键未在真机上人工操作。

Mac 包未经过 Apple Developer ID 公证。Windows 包没有代码签名，浏览器或 SmartScreen 可能提示。请从本仓库下载。校验值在 `SHA256SUMS.txt`。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。[代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)。
