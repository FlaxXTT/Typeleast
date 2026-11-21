TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 听写胶囊先居中显示 Futura 的 Thinking。整理模型接手后，标题轻微上移，底部淡入一条衬线状态词。11 个词随机轮换，连续两次整理使用不同词。
- 豆包听写在录音时流式传输，停录后只交付最终转写。联网语音识别可测试连接并查看延迟。
- 听写整理可单独关闭。启用后，短句做基础纠错，中等长度轻度整理，长段落按意思组织。支持思考开关的模型会显示相应选项。
- 设置重新打开时回到顶部。减少同一麦克风的重复提示，调慢首页统计和活动热力图的动效。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- The dictation capsule starts with a centered Thinking label in Futura. When cleanup starts, the title lifts slightly and a serif status word fades in beneath it. The app rotates through eleven words and avoids consecutive repeats.
- Doubao streams audio during dictation and delivers the final transcript after recording stops. Online recognition settings can test the connection and show its latency.
- Dictation cleanup is optional. When enabled, short transcripts get basic corrections, medium transcripts get light editing, and long transcripts get structured cleanup. Settings show a thinking switch for models that support it.
- Settings returns to the top when reopened. Microphone reminders appear less often, and Home statistics and activity animate more slowly.
<!-- /typeleast-update -->

## 安装 / Installation

仅支持 macOS 14 及以上的 Apple 芯片 Mac。语音模型单独下载，Windows 与 Intel 版不再更新。

本版继续使用固定自签发布证书，尚无 Apple 公证。若仍在使用 2.1.6 或更早的签名身份，请直接下载安装，建立固定发布签名基线。

Requires macOS 14 or later on Apple silicon. Speech models are downloaded separately. Windows and Intel releases remain at their previous versions.

This release retains the persistent self-signed publisher certificate and is not notarized by Apple. If you still use the signing identity from 2.1.6 or earlier, install directly to establish the publisher-signed baseline.

## Touch ID 迁移 / Touch ID migration

如需迁移旧钥匙串凭据，先退出 TypeLeast，再在终端运行下方命令（默认安装路径）。如果 macOS 要求旧授权，请在系统窗口逐项确认，最后用 Touch ID 验证新钥匙串。成功后重新打开应用，按指纹解锁即可读取原有加密历史和 API Key。

To migrate existing credentials, quit TypeLeast and run this command from Terminal (for the default install path). Approve any legacy requests in the macOS dialogs, then use Touch ID to verify the new Keychain. Reopen the app and use Touch ID to unlock your encrypted history and saved API keys.

```sh
/Applications/TypeLeast.app/Contents/MacOS/TypeLeast --migrate-keychain-to-touch-id --allow-each-legacy-authorization
```

[完整记录](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md) · [代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)
