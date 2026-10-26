TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 修复 Mac 历史长文本与来源、状态标签重叠。
- AI 整理新增解释触发词：标记内的说明用于理解本次口述，不写入结果；不完整时先确认。
- 新增偏好资料：对照识别原文、AI 输出和用户修改，确认后加密保存；手工词典保留。
- 新用户先配置整理模型、下载识别模型并完成三组真实语音练习，再进入主界面。旧用户不强制。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Fixed overlapping text and metadata in long Mac history entries.
- AI cleanup supports paired explanation markers. Notes help interpret the current speech and stay out of the result. Incomplete markers require confirmation.
- Preference examples compare the transcript, AI output and your revision. They are encrypted locally after confirmation. The manual dictionary remains available.
- New users configure cleanup, download a speech model and complete three real voice exercises before entering the main app. Existing users are not required to repeat setup.
<!-- /typeleast-update -->

## 解释与偏好

仅 AI 整理识别所选的一组开始词、结束词。解释只作为本次上下文，不自动成为永久名称替换规则；自然整理、翻译与提示词 Beta 不处理这些标记。可在偏好资料页关闭或更换触发词。

偏好示例保存“识别原文 → AI 输出 → 用户确认的修改”。待确认内容只在内存中，确认后才在本机加密保存。只有相关、已确认且启用的短示例会随 AI 整理发送给你选择的模型；不集中上传、不自动训练模型。清空历史不会删除独立保存的已确认偏好，可在偏好资料页删除。旧词典保留，不将旧词条伪造成纠错样本。

## 首次使用

新安装须配置有效的整理模型、下载并加载识别模型、授予必要权限，再完成改口、解释和修改确认三组真实语音练习。需要可用的外部整理服务，会产生正常模型用量；失败或回退结果不能完成教程。设置、权限配置和退出始终可用。练习不粘贴、不保存历史或正式偏好。

已有安装不会被强制重新学习，可主动打开教程。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.22.2-macOS-AppleSilicon.dmg` 或 `.zip` |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.22.2-Windows-x64-Setup.exe` 或 `TypeLeast-1.22.2-Windows-x64-Portable.zip` |

Mac 构建号 31。Intel 不再构建，最后版本保持 1.17.1。安装包不包含语音模型权重，不增加运行时依赖；MLX 官方后端仍为 Coming soon，未开放安装。

## 验证与限制

服务 381 项、Mac 638 项、本机 Windows 核心 805 项、进程外接口验收 46 项通过；Windows 云端核心 811 项通过，客户端交叉编译通过。中英本地化、事实和脱敏检查通过。原有编译警告保留。

发布前核对三平台 CI、四个安装包及校验清单。Mac 标准云端机器仍按既有资源规则跳过大型 1.7B FP16 检查，其本地证据沿用此前记录。

Windows 真实麦克风、目标窗口交互及双端真实外部模型完整教程尚未手动验收。自动测试和界面渲染不能替代真机操作，也不能保证模型理解每一次解释。

[完整记录](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md) · [数据与教程说明](https://github.com/FlaxXTT/Typeleast/blob/main/docs/解释上下文与偏好资料.md) · [代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)
