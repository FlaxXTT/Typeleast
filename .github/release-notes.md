TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 推荐使用 AI 整理：重组零散口述，压缩重复，保留用途、条件、数字和否定。
- 自动词条改为写法提示，不再凭旧自动映射强行替换名称。
- 名称不清楚时先确认，可编辑、继续口述、保留原文或取消；确认面板不阻塞其他窗口。
- 旧安装切换到 AI 整理一次，此后保留你的选择。自然整理与提示词 Beta 继续提供。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- AI cleanup is now recommended. It reorganizes speech and removes repetition while preserving purposes, conditions, numbers and negations.
- Automatic vocabulary entries suggest spellings. Old automatic mappings can no longer force name replacements.
- Unclear names are held for confirmation. Edit, add by voice, keep the transcript or cancel in a non-modal panel.
- Existing installations move to AI cleanup once, then keep your choice. Natural cleanup and Prompt Beta remain available.
<!-- /typeleast-update -->

## 名称与词典

旧词条和自动替换记录保留。自动来源只作为相关写法提示，手动编辑的规则继续生效。确认面板只展示本次原话证据；明确补充只授权本次结果，不形成永久替换规则。确认前不粘贴、不自动学习、不记录成功历史。编辑内容会继续交给当前整理模型处理；保留原文则直接使用本次识别文本。

补充口述沿用最初目标与已允许的上下文，不读取后来切换窗口的内容。目标窗口变化时继续执行原有粘贴保护。

通用规则不能保证模型发现所有名称歧义，也不能修复每一种识别错误。遇到简称或专名，可以补一句全称、用途或拼写。

## 模型与资源

安装包不包含语音模型权重。本次不增加依赖或识别模型，不自动下载或切换现有模型。MLX 官方后端插件将在完成独立实现和实测后另行提供，本版没有上架。

自然整理少改写；AI 整理积极重组表达，但不增加事实或删掉条件。Beta 多轮流程及两步翻译保留。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.22.1-macOS-AppleSilicon.dmg` 或 `.zip` |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.22.1-Windows-x64-Setup.exe` 或 `TypeLeast-1.22.1-Windows-x64-Portable.zip` |

Intel 不再构建，最后版本保持 1.17.1。

## 验证与限制

服务 365 项、Mac 611 项、Windows 791 项通过；独立 HTTP 接口验收 46 项通过。脱敏、事实与中英文本地化检查通过。发布前运行三平台 CI，并核对四个安装包及校验清单。

确认面板尚未做双端真机操作，未继续大规模语音准确率或真实整理模型测试。已有识别模型沿用现有 CI 验收；Mac 标准云端机器按既有资源规则跳过 1.7B FP16，不将跳过记作识别通过。

Mac 包未经过 Apple Developer ID 公证，Windows 包没有代码签名。校验值见 `SHA256SUMS.txt`。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。[代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)。
