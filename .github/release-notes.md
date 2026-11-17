TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 新应用图标：深色圆角底、清晰声波和蓝色点缀，适合 Dock 与应用程序列表中的小尺寸显示。
- 桌面语音条按参考图调整为纯黑背景、灰色取消圆钮、白色结束圆钮和黑色勾；高度为 34，待机时悬停可展开快捷键提示。
- 首次录音、麦克风变化，或超过 5 分钟未录音后，再次开始时会在语音条上方显示实际打开的麦克风名称，约 3 秒后收起。
- 语音条单独使用固定配色，浅色、深色和跟随系统的外观设置只影响主界面。
- 波形由真实录音的 FFT 人声频段能量驱动，加入自适应底噪、三段响应、平滑，以及从中心向两侧扩散和衰减的动画。
- 首次使用中的语音练习复用桌面语音条；Mac 麦克风在后台打开，取消后不接受迟到的启动结果。
- 处理中加入文字高光；音频帧只更新语音条，跨屏时仅在鼠标所在屏幕变化后移动浮层。
- 首次使用固定发布证书。后续同一签名身份的更新可保留发布签名；从旧签名迁移时仍可能需要一次系统授权。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- A new app icon with a dark rounded tile, clear sound bars and a blue accent, designed for the Dock and Applications list.
- A 34-point black voice capsule with a grey cancel button, a white finish button with a black check, a compact waveform and an idle shortcut hint on hover.
- On the first recording, after a microphone change, or after more than five minutes without recording, the overlay shows the opened microphone name above the bar for about three seconds.
- The voice bar keeps its own fixed colours in light, dark and system appearance; the main window still follows the selected appearance.
- The waveform uses FFT energy from the recorded voice band, with an adaptive noise floor, three response ranges, smoothing, and outward propagation and decay.
- Onboarding practice uses the desktop voice-bar renderer. Mac microphone startup runs in the background, and cancelled startup callbacks are discarded.
- Processing text has a moving highlight. Audio frames redraw the voice bar, and the overlay moves between displays only when the pointer changes displays.
- This is the first release with a persistent publisher certificate. Later updates with the same signing identity can retain that signature; migration from older signing may still require system authorization.
<!-- /typeleast-update -->

## 安装 / Installation

仅支持 macOS 14 及以上的 Apple 芯片 Mac。语音模型单独下载，Windows 与 Intel 版不再更新。

本版采用固定自签发布证书，尚无 Apple 公证。首次切换到新发布身份时，请直接安装本版；旧版更新器可能仍会要求本机签名授权。首次打开、钥匙串锁定或权限变更时，macOS 仍可要求授权。

Requires macOS 14 or later on Apple silicon. Speech models are downloaded separately. Windows and Intel releases remain at their previous versions.

This release uses a persistent self-signed publisher certificate and is not notarized by Apple. Install this first publisher-signed baseline directly; older updaters may still request local signing authorization. macOS can still request authorization on first launch, when the Keychain is locked, or when permissions change.

本次发布跳过测试和运行时冒烟步骤；Mac 界面源码已在本机编译。
Tests and runtime exercises are skipped for this release. The Mac UI sources were compiled locally.

[完整记录](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md) · [代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)
