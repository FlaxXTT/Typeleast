TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 修复「设置 → 通用」滚动时重复查询系统登录项状态的问题：开机启动开关与提示读取缓存，只在进入页面、返回应用或修改开关后刷新。
- 减少无变化的后台健康状态反复触发界面刷新，合并重叠请求；本地化文字与数字格式器复用，减少滚动过程中的重复计算。
- 缓存用于界面显示的钥匙串条目存在状态，减少重复系统查询；保存、删除和返回应用时更新缓存。
- 修复模型连接请求的旧结果回写新配置的问题；关闭引导后停止其权限轮询。
- 保留 2.1.7 的新图标、固定录音条配色、麦克风提示和固定发布签名。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Fix repeated system login-item queries while scrolling Settings > General. The launch-at-login switch and hint use cached state, refreshed on entry, app activation or a switch change.
- Avoid publishing unchanged health data and combine overlapping requests. Reuse localization and number formatters to reduce repeated UI work.
- Cache Keychain item-presence metadata used by the UI, refreshing it after save, deletion and app activation.
- Prevent old model-connection results from updating a changed form. Stop permission polling after onboarding closes.
- Keep the 2.1.7 app icon, fixed voice-bar colours, microphone reminder and persistent publisher signature.
<!-- /typeleast-update -->

## 安装 / Installation

仅支持 macOS 14 及以上的 Apple 芯片 Mac。语音模型单独下载，Windows 与 Intel 版不再更新。

本版继续使用固定自签发布证书，尚无 Apple 公证。若仍在使用 2.1.6 或更早的签名身份，请直接下载安装，建立固定发布签名基线。

Requires macOS 14 or later on Apple silicon. Speech models are downloaded separately. Windows and Intel releases remain at their previous versions.

This release retains the persistent self-signed publisher certificate and is not notarized by Apple. If you still use the signing identity from 2.1.6 or earlier, install directly to establish the publisher-signed baseline.

按用户要求，本次不运行测试和运行时冒烟步骤。
Tests and runtime exercises are skipped for this owner-requested release.

[完整记录](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md) · [代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)
