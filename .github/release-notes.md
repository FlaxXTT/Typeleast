TypeLeast：按快捷键说话，本机识别，再用你自己的整理模型处理文字并插入光标处。

## 1.17.0 的变化

- **普通提示词模式一次生成**：理解核心意图，用编号穿插自然段表达，不再套角色等固定模板，不扩展你没提出的要求。名称只根据上下文和模型知识还原；没有把握时保留描述，不新增联网检索。
- **多轮 Beta**：每次补充都会重新检查遗漏、矛盾和新歧义，显示当前理解。可以继续补充、纠正，直到主动点击“结束补充并生成”。失败保留已接受信息，不粘贴半成品；修补后再次审查。
- **设置更清楚，模式随时可切换**：设置按五类分组，四种整理模式固定在主窗口顶部；Mac 菜单栏、Windows 托盘和任务栏菜单也可选择。录音和整理期间暂不可切换，离开未完成的 Beta 前会提醒。
- **提示词移到配置文件**：设置不显示正文；通过警告、再次确认及验证码后，可在外部编辑器打开配置文件。已有自定义内容保留，可恢复新默认。
- 修复英文最小窗口的分类栏裁切。自然整理继续使用维护者提供的原创提示词，正文未改。
- 采用 GPL-3.0 许可；两端安装包都附带许可文件。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.17.0-macOS-AppleSilicon.dmg` 或 `.zip` |
| macOS 13 以上，Intel | `TypeLeast-1.17.0-macOS-Intel.dmg` 或 `.zip` |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.17.0-Windows-x64-Setup.exe`（安装版）或 `…-Portable.zip`（免安装） |

Mac 构建号为 9。共六个安装包；统一校验清单为 `SHA256SUMS.txt`，另保留 Windows 提供方的 `SHA256SUMS-Windows.txt`。

## 验证与限制

Mac 本地服务 219 项通过、0 跳过，Mac 406 项、Windows Core 539 项通过。Windows 打包端另报告服务 218 项通过、1 项跳过，核心 539 项通过。Mac 两种架构的打包和签名检查通过，Apple 芯片包内服务与默认识别模型启动通过。按 Windows 打包端交接记录，Windows 安装包在 Linux 上用 Microsoft .NET 8 SDK 和 wine 中的 Inno Setup 构建：wine 中静默安装、内置服务启动通过，Windows 界面用离屏渲染检查了浅色和深色。

托管 CI 没有额度，本次使用维护者已授权的本地验证与手动发布。未完成 Windows 真机 UI、Intel/Rosetta 运行、真实外部模型效果或长期压力测试；没有读取真实 Key 或私人听写记录。独立更新签名与本地服务身份认证仍是已知缺口。

Mac 包没有 Apple Developer ID 公证；Windows 安装包没有代码签名，SmartScreen 提示时点“更多信息 → 仍要运行”，识别引擎需要 Microsoft Visual C++ 运行库（x64）。Beta 会话只在内存中，空闲十五分钟过期；服务重启会丢失未生成的对话，多轮补充会增加模型用量。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)，验证范围见 [设置与提示词模式验证记录](https://github.com/FlaxXTT/Typeleast/blob/main/docs/设置与提示词模式-验证记录.md)。
