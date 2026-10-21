TypeLeast：按快捷键说话，本机识别，再用你选择的模型整理文字并插入光标处。

## 1.17.1 的变化

- 修复 Beta 多轮审查误判明确改口和等义改写的问题。用户说“我再纠正一下”等话语时，后面的说法替代前面的说法。
- 审查指出草稿问题时，引用必须确实来自当前草稿。无效证据不会进入反复修补。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.17.1-macOS-AppleSilicon.dmg` 或 `.zip` |
| macOS 13 以上，Intel | `TypeLeast-1.17.1-macOS-Intel.dmg` 或 `.zip` |

Mac 构建号为 10。Windows 1.17.1 安装包将在 Windows 构建环境可用后补充；目前 Windows 用户继续使用 [v1.17.0](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.0)。

## 验证与限制

服务测试 220 项、Mac 测试 406 项通过。托管 CI 没有额度，本次使用本地构建与测试；Windows 1.17.1 尚未打包或真机验证。未用私人录音或 API Key 做测试。Mac 安装包使用本机签名证书，未经过 Apple Developer ID 公证。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。
