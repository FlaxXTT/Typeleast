TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 语音弹窗缩小为原尺寸的 85%，普通录音约 121×34，保留滚动波形。
- 麦克风启动移至后台，先显示打开状态；启动期间可按 Esc 或再次按快捷键取消，减少唤起时的界面停顿。
- 减少波形重复计算、历史列表重复分组和静态提示重绘；Fn 明确设为“无操作”时去掉固定 250 毫秒等待。
- 修复翻译提前超时及错误的“本地服务失败”提示。翻译按钮缩为 48×30，仅确认选中文字后显示。
- 修复重启期间模型加载被误报为缺失，以及服务短暂启动后崩溃导致的无限重试。
- 同一长期签名身份的后续更新保留原签名，避免重复使用本机签名私钥。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- The voice overlay is 15% smaller (about 121×34 for ordinary recording), with the scrolling waveform retained.
- Microphone startup runs in the background. The overlay shows opening status immediately and supports Escape or the shortcut to cancel while opening.
- Less repeated waveform work, history grouping and static-result repainting. Fn skips the fixed 250 ms wait when explicitly configured as Do Nothing.
- Fixed premature translation timeouts and misleading local-service errors. The 48×30 translation button appears only for a confirmed text selection.
- Fixed models being reported missing while loading after restart, and repeated service crashes resetting the retry limit.
- Subsequent updates with the same persistent publisher identity preserve their signature without using a local signing private key.
<!-- /typeleast-update -->

## 安装 / Installation

仅支持 macOS 14 及以上的 Apple 芯片 Mac。语音模型单独下载，Windows 与 Intel 版不再更新。

本版是首个长期发布身份的迁移基线。旧更新器会重新签名，请直接下载安装本版；首次迁移仍可能需要一次 macOS 授权。之后同身份更新保留授权。自签名不提供 Apple 公证，初次打开仍受 Gatekeeper 检查；钥匙串被锁定、重置或撤销授权时仍可能要求系统授权。

Requires macOS 14 or later on Apple silicon. Speech models are downloaded separately. Windows and Intel releases remain at their previous versions.

Install this first persistent-publisher baseline directly: older updaters re-sign downloaded apps. The first migration may still require one macOS authorization. Subsequent matching-identity updates preserve their signature. Self-signing does not provide Apple notarization or bypass Gatekeeper; a locked/reset Keychain or revoked access may still require authorization.

[完整记录](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md) · [代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)
