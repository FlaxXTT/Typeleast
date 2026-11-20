TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 普通听写按长度分流。25 字或词以内直接输出，26–100 简要整理，101 起完整整理。简要整理可指定小模型，DeepSeek 的完整整理可选择思考与推理强度。
- 「个性化」可分别编辑、恢复简要整理、完整整理、翻译和提示词模式的提示词。默认完整整理更精简，有并列需求时按意思分点。
- 听写与会议可各自选择本地或联网语音识别。豆包支持语义顺滑开关和自定义热词。使用联网听写时可删除闲置的本地模型权重。
- 已保存的 API Key 在钥匙串锁定时显示为待解锁。调整首页统计、侧栏字标、设置分类和录音波形。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Dictation inserts transcripts of up to 25 characters or words directly, uses brief cleanup for 26–100, and runs full cleanup from 101. Brief cleanup can use a small model. DeepSeek full cleanup has optional thinking and reasoning effort.
- Personalization now lets you edit or restore the prompts for brief cleanup, full cleanup, translation, and prompt mode independently. The default full cleanup prompt is shorter and groups distinct requests into numbered items.
- Choose local or online recognition separately for dictation and meetings. Doubao supports optional speech smoothing and custom hotwords. You can remove unused local model weights while using online dictation.
- Saved API keys show when they are waiting for Keychain unlock. Home statistics, the sidebar wordmark, Settings categories, and the recording waveform have been refined.
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
