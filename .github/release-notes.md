TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 语音弹窗缩小为原尺寸的 85%，普通录音约 121×34，保留滚动波形。
- 麦克风启动移至后台，先显示打开状态；启动期间可按 Esc 或再次按快捷键取消，减少唤起时的界面停顿。
- 减少波形重复计算、历史列表重复分组和静态提示重绘；Fn 明确设为“无操作”时去掉固定 250 毫秒等待。
- 修复翻译提前超时及错误的“本地服务失败”提示。翻译按钮缩为 48×30，仅确认选中文字后显示。
- 修复重启期间模型加载被误报为缺失，以及服务短暂启动后崩溃导致的无限重试。
- 本版沿用临时签名，长期发布签名配置留到后续版本；安装或更新时 macOS 仍可能要求授权。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- The voice overlay is 15% smaller (about 121×34 for ordinary recording), with the scrolling waveform retained.
- Microphone startup runs in the background. The overlay shows opening status immediately and supports Escape or the shortcut to cancel while opening.
- Less repeated waveform work, history grouping and static-result repainting. Fn skips the fixed 250 ms wait when explicitly configured as Do Nothing.
- Fixed premature translation timeouts and misleading local-service errors. The 48×30 translation button appears only for a confirmed text selection.
- Fixed models being reported missing while loading after restart, and repeated service crashes resetting the retry limit.
- This release retains temporary signing. Persistent publisher signing is deferred; macOS may still request authorization during installation or updates.
<!-- /typeleast-update -->

## 安装 / Installation

仅支持 macOS 14 及以上的 Apple 芯片 Mac。语音模型单独下载，Windows 与 Intel 版不再更新。

本版尚未启用长期发布身份，也没有 Apple 公证。安装、更新或访问钥匙串时仍可能出现 macOS 授权弹窗；固定签名配置将在后续版本完成。本版不承诺免密码更新。

Requires macOS 14 or later on Apple silicon. Speech models are downloaded separately. Windows and Intel releases remain at their previous versions.

This release has not enabled persistent publisher signing or Apple notarization. macOS authorization prompts may still appear during installation, updates or Keychain access. Persistent signing will be configured for a later version; this release does not promise password-free updates.

[完整记录](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md) · [代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)
