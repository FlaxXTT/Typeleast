TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 个人偏好分为表达示例、个人词汇、排除与高级规则；扩展保持独立管理。
- 所有模式停止自动入词典。旧自动词汇保留但停用，旧替换需逐条启用，当前改口、否定和条件优先。
- “不再参考这个词”覆盖个人与扩展来源；历史可查看参考与实际替换、撤销替换，或仅本次关闭个性化后重试。
- AI 整理解释触发词缩短为“备注／说完了”，仍兼容旧长触发词。
- 个人词汇迁入本机加密存储。旧版本不能读取新增词汇密文，不保证直接降级兼容。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Personal preferences now have wording examples, personal vocabulary, and exclusions with advanced rules. Extensions remain separate.
- All modes stop adding dictionary entries automatically. Old automatic terms are retained but disabled; old replacements require individual approval. Current corrections, negation and conditions take priority.
- Stop referencing a term across personal and extension sources. History distinguishes supplied references from actual local replacements, supports undo, and can retry once without personalization.
- AI cleanup uses shorter explanation markers: side note / back to text. Earlier markers remain compatible.
- Personal vocabulary is encrypted locally. Older versions cannot read the new vocabulary payload; direct downgrade compatibility is not guaranteed.
<!-- /typeleast-update -->

## 个人偏好与扩展

普通词汇只作参考，不强制替换其他合法名称。高级替换逐条开启，仍经过当前口述和事实边界检查。排除某词只暂停资料与规则的影响，不禁止用户当次说出该词；扩展更新不会恢复被排除的影响。

用户修改只产生待确认项。只有确认且启用的相关短示例随自然整理或 AI 整理请求发到用户选择的模型，不集中上传、不自动训练模型。参考记录只说明资料被提供，不能证明模型采用了它。

旧数据保留。读取或加密失败时阻止覆盖。新增词汇密文不向旧版本提供明文副本，因此直接降级不保证兼容。

## 解释触发词

仅 AI 整理使用“备注／说完了”；英文为 side note / back to text。两词之间的说明只提供本次上下文，不写入结果。旧选择迁移一次，原来关闭者保持关闭，旧长词继续识别。缺失结束词先确认。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.23.0-macOS-AppleSilicon.dmg` 或 `.zip` |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.23.0-Windows-x64-Setup.exe` 或 `TypeLeast-1.23.0-Windows-x64-Portable.zip` |

Mac 构建号 32。Intel 不再构建，最后版本保持 1.17.1。安装包不包含语音模型权重，不增加运行时依赖；MLX 官方后端仍为 Coming soon，未开放安装。

## 验证与限制

功能提交三平台 CI 的 9 个任务通过：服务 395 项、Mac 664 项、Windows 原生核心 838 项；本地进程外接口验收 46 项通过。双端编译、Windows 界面渲染、本地化、事实和脱敏检查通过。原有编译提醒保留。

Mac 标准云端机器按既有资源规则跳过 1.7B FP16；Linux 和 Windows 的真实模型检查通过。本轮短标记仅使用三个合成中文音色小样例，不代表真人口音与噪声下的准确率。真实麦克风、目标窗口及外部整理模型没有在本轮手动验收，自动测试与离屏渲染不能替代真机操作。

测试和开发工具不进入安装包，不读取真实 Key、私人历史或录音。

[完整记录](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md) · [个人偏好与扩展](https://github.com/FlaxXTT/Typeleast/blob/main/docs/个人偏好与扩展.md) · [代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)
