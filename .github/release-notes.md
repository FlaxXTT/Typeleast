TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 繁体只用于明确识别出的中文；其他语言和语言未知时保持原文。
- Mac：词典建议和词条可以一起滚动；编辑窗口不再阻止主窗口操作。
- 快捷键冲突、词典本机大小写、镜像清空及扩展失败后的界面状态已修复。
- Mac：改善应用列表登记，更新后刷新登记；设置和词典继续保留。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Traditional Chinese conversion runs only for known Chinese output. Other and unknown languages stay unchanged.
- Mac: suggestions and dictionary entries scroll together. The editor lets you continue using the main window.
- Fixed shortcut conflict notices, local letter case, cleared download mirrors and extension error states.
- Mac: improved app registration and refresh it after updates. Settings and dictionary entries are kept.
<!-- /typeleast-update -->

**繁体转换：** 中文、粤语和成功译成中文的结果可转换。自动识别使用模型返回的语言标记；模型未给出可靠语言时跳过。日文（包括纯汉字日文）、其他语言及失败的翻译不转换。

**Mac：** 词典建议不再挤掉词条滚动区，添加和编辑词条使用非模态窗口。快捷键重复或注册失败会显示原因；应用登记调整后仍按你的设置决定是否显示 Dock 图标。

**双端：** 本机词条可修正英文大小写；清空镜像立即生效；Beta 和翻译的功能范围有说明。Windows 扩展修改失败后恢复实际状态，保留录音标明为 5 分钟。包含 v1.21.1 的全部修复。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.21.2-macOS-AppleSilicon.dmg` 或 `.zip` |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.21.2-Windows-x64-Setup.exe`（安装版，支持软件内更新）或 `TypeLeast-1.21.2-Windows-x64-Portable.zip` |
| Intel Mac | 不再更新。最终版：[v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |

已安装的用户可在软件内更新。Mac 构建号为 27。

## 验证与限制

本地服务 314 项、Mac 581 项测试及接口契约 46 项通过。Mac 词典用隔离示例验证了滚动和非模态编辑。Windows 界面、提示音及快捷键未在真机上人工操作。

Mac 包未经过 Apple Developer ID 公证。Windows 包没有代码签名，浏览器或 SmartScreen 可能提示。请从本仓库下载。校验值在 `SHA256SUMS.txt`。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。[代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)。
