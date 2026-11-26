# TypeLeast

**按一下 Fn，说完再按一下。文字写到光标处。**

TypeLeast 是一款开源的 macOS 听写工具。用声音写消息、写文档，也可以在输入框里直接写译文或调用 Skill。

[下载最新版](https://github.com/FlaxXTT/Typeleast/releases/latest) · [使用指南](docs/user-guide.md) · [English](README.en.md)

**Apple 芯片 Mac · macOS 14 或更新版本**

![静音演示。TypeLeast 听写一段合成语音，将改口后的会议时间写进文本编辑框。](docs/media/demo.gif)

## 三个快捷键

| 默认按键 | 操作 | 结果 |
| --- | --- | --- |
| **Fn** | 按一下开始听写，说完再按一下 | 文字写到光标处 |
| **Fn + 左 Shift** | 无选区时按一下开始说话，再按一下结束。有选区时按一次 | 语音译文写到光标处。选词译文在独立面板显示 |
| **Fn + 空格** | 按住打开 Harness EQ，把鼠标移到已导入的项目，再松开两键 | Skill 正文或调用提示写到光标处 |

听写与翻译快捷键可在对应的设置页调整。

## 第一次听写

1. 在发布页下载 Apple 芯片版 DMG，把 TypeLeast 拖进「应用程序」。
2. 打开 TypeLeast。先用引导里的固定样例了解听写、翻译和 Skill 调用，最后选择语音识别方式。可以下载本地模型，也可以填入云端语音识别服务的 API Key。
3. 允许麦克风和辅助功能。在「文本编辑」里新建空白文稿，按默认听写键 **Fn** 说一句，再按一次，看看文字是否写入。也可从首页的「试试听写」打开文本编辑。

基本听写只需配置语音识别。需要 AI 整理或翻译时，再在「设置 → 模型」配置整理模型。[配置与排查](docs/user-guide.md)

## 用 Harness EQ 调用和归档 Skill

在「设置 → Harness EQ」导入 Skill 或 MCP。调用时，独立 Skill 会写入正文。有依赖的 Skill 会写入如何读取入口和依赖的提示。MCP 会写入调用提示，由目标 Agent 按其可用能力使用。

<details>
<summary>复制给 Agent 的 Skill 归档提示词</summary>

```text
请将我指定的 Skill 归档到 TypeLeast 的「设置 → Harness EQ → Skill」。如果我还没有指定名称或路径，先问我。只处理我指定的项目。

1. 纯提示词 Skill 选择「存入 TypeLeast」。带依赖的 Skill 请用包含 SKILL.md 和必需文件的 .skill 或 .zip 包导入，保留原有的相对路径、正文和必要字段。
2. 验证 Harness EQ 能从归档副本调用它。纯提示词应返回完整正文。带依赖的 Skill 应指向归档副本里的 SKILL.md，并能以它所在的目录为基准读取所需文件。验证只需读取文件，无需执行其中的指令或脚本。
3. 验证成功后，如果我已明确要求「归档并删除原件」，就将指定原件移到废纸篓。否则请先问我「已确认通过 Harness EQ 调用归档副本不受影响。原 Agent 可能停止自动加载旧入口。要把原件移到废纸篓吗？」
4. 如果调用仍依赖原路径、其他项目还在引用原件，或无法确认依赖已完整迁移，请保留原件并说明原因。如果你不能操作 TypeLeast，请告诉我需要手动完成哪一步。

最后告诉我归档了哪条 Skill、验证了什么，以及原件是否已移到废纸篓。
```

</details>

## 数据去哪里

本地识别的音频留在 Mac 上。选用云端识别时，音频会发给你选择的服务商。开启联网整理或翻译后，相应文字会发给已配置的模型服务。API Key 保存在 macOS 钥匙串。[数据流与保留设置](docs/user-guide.md#隐私与本机数据)

## 项目链接

[版本历史](CHANGELOG.md) · [旧版下载](docs/user-guide.md#旧版下载) · [从源码构建](apps/macos/README.md#build-test-package) · [签名说明](docs/CODE_SIGNING_POLICY.md) · [报告问题](https://github.com/FlaxXTT/Typeleast/issues/new) · [MIT 许可](LICENSE)

### 问题报告贡献者

- 感谢 [pioneerAlone](https://github.com/pioneerAlone) 提供 MLX 退出问题的复现步骤及日志，并报告冷启动问题。[#107](https://github.com/FlaxXTT/Typeleast/issues/107)
- 感谢 [tomcatcoffee](https://github.com/tomcatcoffee) 提供开始录音时浮窗闪退的崩溃堆栈。[#179](https://github.com/FlaxXTT/Typeleast/issues/179)
