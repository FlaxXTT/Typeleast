TypeLeast：按快捷键说话，本机识别，再用你选择的模型整理文字并插入光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 提示词模式新增普通档：更短、更直白，保留核心意图和条件；标准格式档保留原有行为。
- 整理和翻译加强本次口述中的连续改口与忘词还原，名称不确定时保留描述。
- 更新时显示简短的版本变化；词典建议由本地服务统一判断，两端一致。
- 两端更新、词典、Beta 会话和听写控制器完成职责拆分，保留现有操作流程。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Prompt mode now has a plain tier for shorter, clearer wording. The standard tier keeps its existing behavior.
- Cleanup and translation handle spoken corrections and term descriptions more clearly. Uncertain names stay as descriptions.
- In-app updates show short release notes. Dictionary suggestions use the same local rules on both platforms.
- Update, dictionary, Beta session and dictation controllers have separate responsibilities. Existing workflows are retained.
<!-- /typeleast-update -->

普通档按需要使用自然段、编号，或用户明确要求的表格，保留否定、例外、数字和约束，不输出角色等固定栏目。标准格式档沿用当前编号与自然段及 `promptify.json` 配置。Beta 和原话转写保持原行为。

“不对”等改口只作用于本次口述，不编辑已经粘贴的上一条文字。术语还原仅使用上下文与模型已有知识；不新增联网检索。具体效果取决于识别结果和用户选择的整理模型，不保证每次都能确定改口范围或专业名称。

客户端升级到本版后，后续更新才能显示新的摘要与圆环进度界面。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.18.0-macOS-AppleSilicon.dmg` 或 `.zip` |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.18.0-Windows-x64-Setup.exe`（安装版，支持自动更新）或 `TypeLeast-1.18.0-Windows-x64-Portable.zip` |
| Intel Mac | 已停止更新，最终版为 [v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |

已安装的用户可在软件内检查更新；Windows 安装版保留自动更新行为。Mac 构建号为 21。

## 验证与限制

服务、Mac 和 Windows 核心测试及三平台 CI 通过；四种识别模型在三平台使用公开短样例完成加载和识别。两端模式选择和更新摘要用虚构数据检查中英文、浅色和深色布局。Windows 未进行真机人工操作验证。

自动回归测试使用虚构口述与假整理服务；发布前另由隔离测试副本在应用内部使用维护者已有模型配置进行虚构文本实测。首轮发现术语还原擅自补充要求，已收紧规则并复测。Key 仅经应用内的内存管道使用，没有导出或记录；未读取私人历史和录音。少量样例不能证明任意模型或任意口述都正确。新增 `pinyin-pro` 为 MIT 许可，随两端安装包交付，无需另外下载，也不增加建议词判断的模型调用。

Mac 包未经过 Apple Developer ID 公证；Windows 包未进行代码签名，浏览器或 SmartScreen 可能提示下载信誉不足。请从本仓库下载。四个安装包的校验值位于 `SHA256SUMS.txt`。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。[代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)。
