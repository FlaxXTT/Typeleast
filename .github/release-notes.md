TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 听写使用纯文本粘贴，短暂使用剪贴板后恢复原内容。
- 已打开的窗口重新获得焦点或从 Dock 恢复时跳过首页遮罩。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Dictation uses standard plain-text paste and restores the previous clipboard shortly afterward.
- Refocusing or restoring an open window skips the Home overlay.
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
