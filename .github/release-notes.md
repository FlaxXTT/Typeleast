TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 界面文字更短、更直接，删除了说明性文字。
- 扩展页：词库标蓝色，风格标紫色。
- 「三四个」不再被写成「34 个」。
- 扩展出错时，听写和整理照常工作。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Shorter, clearer interface text. Explanations are removed.
- Extensions: dictionary packs are blue, styles are purple.
- “三四个” (three or four) is no longer written as “34”.
- If an extension fails, dictation and cleanup continue to work.
<!-- /typeleast-update -->

**界面文字：** 英文按 ASD-STE100 改写，中文按英文翻译。设置、整理模式和识别模型下面的说明行已删除。

**数字：** 相邻两个数连说是概数（三四个、十七八个），保留汉字，不合并成一个数。逐位读出的编号（一二三四五六）写成 123456。

**扩展：** 插件逻辑移到独立模块。停用或卸载一个词库后，后续请求不再使用它。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.21.0-macOS-AppleSilicon.dmg` 或 `.zip` |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.21.0-Windows-x64-Setup.exe`（安装版，支持软件内更新）或 `TypeLeast-1.21.0-Windows-x64-Portable.zip` |
| Intel Mac | 不再更新。最终版：[v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |

已安装的用户可在软件内更新。Mac 构建号为 25。

## 验证与限制

服务、Mac 和 Windows 测试，以及跨语言验收契约，都已通过。新界面文字未在 Mac 和 Windows 真机上人工逐页查看。

Mac 包未经过 Apple Developer ID 公证。Windows 包没有代码签名，浏览器或 SmartScreen 可能提示。请从本仓库下载。校验值在 `SHA256SUMS.txt`。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。[代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)。
