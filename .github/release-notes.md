TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 首页开屏采用「声纹」。五柱从左到右依次伸展并轻弹，随后淡出到首页。
- 长口述自动理清目标、限制和交付事项。普通 Fn 听写整理完成后直接粘贴到光标处。
- 明确口述的符号可转为 #、@、! 等字符，并保留普通语句中的词义。
- 听写遇到临时识别错误时，用同一模型和原录音重试一次。仍失败时，可按现有设置在 History 找回录音或已识别的文字。
- 带依赖的 Skill 调用会附上名称、用途、用法和本机 SKILL.md 路径。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- The Home logo reveals its five bars from left to right with a subtle bounce before the overlay fades.
- Long dictation organizes goals, constraints, and deliverables. The standard Fn shortcut pastes the result at the cursor.
- Explicitly dictated symbols can appear as #, @, or !, while ordinary references keep their meaning.
- Temporary recognition failures retry once with the same model and recording. History can preserve the audio or recovered text according to your settings.
- Linked Skills include their name, purpose, usage, and local SKILL.md path when invoked.
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
