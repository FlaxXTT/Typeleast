TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 筛选后的术语自动加入词典，不再需要逐条点击「加入」。
- 删除后的词不会再自动加入；手工保存的写法保留。
- 旧建议在自动学词开启时迁入词典，关闭时不添加。
- 保留 v1.21.2 的中文转换、词典滚动和非模态编辑修复。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Filtered terms are added to the dictionary automatically. No Add confirmation is needed.
- Deleted terms stay removed. Your saved spellings take priority.
- Existing suggestions move to the dictionary when automatic learning is on. Nothing is added when it is off.
- Includes the Chinese conversion, scrolling and modeless editor fixes from v1.21.2.
<!-- /typeleast-update -->

**繁体转换：** 中文、粤语和成功译成中文的结果可转换。自动识别使用模型返回的语言标记；模型未给出可靠语言时跳过。日文（包括纯汉字日文）、其他语言及失败的翻译不转换。

**自动学词：** Mac 和 Windows 直接保存本地服务已筛选的术语，不增加模型请求或费用。用户可在词典查看、编辑和删除；删除后不再自动加入。自动学词的开关和既有忽略记录继续生效。

**双端：** 本机词条可修正英文大小写；清空镜像立即生效；Beta 和翻译的功能范围有说明。Windows 扩展修改失败后恢复实际状态，保留录音标明为 5 分钟。包含 v1.21.1 的全部修复。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.21.3-macOS-AppleSilicon.dmg` 或 `.zip` |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.21.3-Windows-x64-Setup.exe`（安装版，支持软件内更新）或 `TypeLeast-1.21.3-Windows-x64-Portable.zip` |
| Intel Mac | 不再更新。最终版：[v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |

已安装的用户可在软件内更新。Mac 构建号为 28。

## 验证与限制

本地 Mac 596 项测试通过；两端共用自动学词用例。Mac 词典的滚动和非模态编辑已用隔离示例验证。Windows 界面、提示音及快捷键未在真机上人工操作。

Mac 包未经过 Apple Developer ID 公证。Windows 包没有代码签名，浏览器或 SmartScreen 可能提示。请从本仓库下载。校验值在 `SHA256SUMS.txt`。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。[代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)。
