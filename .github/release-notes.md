TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 长按录音，松键转写；点按进入免提。胶囊波形跟随音量，转写真正完成后才显示 100%。单独使用 Fn 长按时，需将 macOS 的 Fn 键动作设为「不执行操作」。
- 新增独立的首次就绪提示和键入提醒。提醒仅在本机统计按键次数。
- 打开或回到首页时，Instinct 字数和时长从 0 开始增长。活动图按周入场并保留频率色阶。
- 切到云端 ASR 时释放本机模型，切回本机时再加载。文字整理继续可用。
- 可将已有凭据迁移到 Touch ID 钥匙串。旧钥匙串授权只在显式迁移时请求。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Hold the shortcut to record and release to transcribe, or tap for hands-free recording. The live waveform follows the microphone level, and progress reaches 100% when transcription completes. Holding Fn by itself requires the macOS Fn key action to be set to Do Nothing.
- Separate onboarding and typing reminders help you discover the shortcut. Typing reminders count key events locally.
- Instinct counts up from zero when you open or return to Home, and the activity heatmap animates by week with frequency-based colors.
- Switching to cloud ASR unloads the local model while keeping text cleanup available. The local model loads again when selected.
- Existing credentials can be migrated to a Touch ID Keychain. The legacy Keychain asks for access only during explicit migration.
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
