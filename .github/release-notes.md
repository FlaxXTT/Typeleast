TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 首页新增 Cadence 热力图标题与 Rhythm 活跃天数。时段词随本机时间变化，并与 TypeLeast 字标首字母同色。
- 侧栏字标和波形略微放大，新增粉色、电影灵感等随机配色。首页入场遮罩仅显示波形。
- 整理与提示词模式各自使用扩展后的状态词，避免连续重复。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Home adds the Cadence heatmap heading and Rhythm active-day readout. The time-of-day label follows local time and shares the TypeLeast initial’s color.
- The sidebar wordmark and waveform are slightly larger, with new pink and cinema-inspired palettes. The Home entry mask shows a bare waveform.
- Cleanup and Prompt Mode use expanded, separate sets of status words and avoid consecutive repeats.
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
