<h1 align="center">TypeLeast</h1>

<p align="center">按一下 Fn，说完再按一下。整理好的文字直接写到光标处。</p>

<p align="center">
  <a href="https://github.com/FlaxXTT/Typeleast/releases/latest"><strong>下载 macOS 版</strong></a> ·
  <a href="https://typeleast.promptking.workers.dev/">官网</a> ·
  <a href="https://www.bilibili.com/video/BV1eQnH6zESN/">B 站视频</a> ·
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <img src="docs/media/readme/typeleast-home.png" width="840" alt="TypeLeast 的 macOS 首页，展示听写统计、使用热力图、快捷键和当前模型">
</p>

<p align="center"><sub>开源 · Apple 芯片 Mac · macOS 14 或更新版本</sub></p>

<p align="center">
  <img src="docs/media/readme/recording-capsule.gif" width="360" alt="TypeLeast 录音条，波形随说话的轻重和停顿起伏">
</p>

### 41 秒看完

<a href="docs/media/readme/typeleast-overview.mp4"><img src="docs/media/readme/typeleast-overview.jpg" width="400" alt="点击观看 TypeLeast 产品短片，封面是一只在敲键盘的黑猫"></a>

[观看或下载 MP4（中文配音）](docs/media/readme/typeleast-overview.mp4)

| 按键 | 你可以做什么 |
| --- | --- |
| **Fn** | 说一段话，把整理好的文字写到光标处。 |
| **Fn + 左 Shift** | 选中文字直接翻译，也可以说中文、贴出英文。 |
| **Fn + 空格** | 按住打开 Harness EQ，选好 Skill 或 MCP，再松手写入。 |

语音识别可用本地模型，也可接自己的 API。启用云端识别、整理或翻译时，相应内容会发送给你选的服务商。[安装与配置](docs/user-guide.md) · [数据与隐私](docs/user-guide.md#隐私与本机数据)

### Harness EQ · Skill 归档

在 **设置 → Harness EQ** 导入 Skill 或 MCP，想用时再从转盘里选。

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

---

[版本历史](CHANGELOG.md) · [旧版下载](docs/user-guide.md#旧版下载) · [从源码构建](apps/macos/README.md#build-test-package) · [签名说明](docs/CODE_SIGNING_POLICY.md) · [报告问题](https://github.com/FlaxXTT/Typeleast/issues/new) · [GPL-3.0 许可](LICENSE)

感谢问题报告贡献者 [pioneerAlone](https://github.com/pioneerAlone)（[#107](https://github.com/FlaxXTT/Typeleast/issues/107)）和 [tomcatcoffee](https://github.com/tomcatcoffee)（[#179](https://github.com/FlaxXTT/Typeleast/issues/179)）。
