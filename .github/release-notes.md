TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 录音胶囊的中央两根先起，第三根稍低、稍晚跟上，外围随人声音量轻微抖动。处理完成后 Thinking 直接淡出，取消转录提示完整显示。
- 默认 Fn + 左 Shift 根据选区分流。选中文字时在面板显示译文，无选区时把语音译文插入光标处。新翻译不写入历史。
- 改进选词翻译按钮定位和译文排版。选词翻译的目标语言可以单独设置。
- 首页与设置窗口分区切换主题。精简活动统计、就绪状态、联系入口和设置说明。
- 减少整理确认弹窗，仅在有明确证据的内容冲突出现时提示。麦克风提示显示录音实际使用的设备。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Two bars lead the recording waveform, followed by a shorter third bar. The outer bars move subtly with speech. The Thinking animation fades out on completion, and the cancellation toast fits in its window.
- With the default Fn + Left Shift shortcut, selected text opens a translation panel. Without a selection, voice translation inserts at the cursor. New translations are excluded from history.
- The selection translation button and result layout are easier to use, and selection translation has its own target language setting.
- Home and Settings switch appearance section by section. Activity labels, service status, contact, and settings use less text.
- Cleanup asks for confirmation when there is clear evidence of a content conflict. The microphone hint shows the device actually used to record.
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
