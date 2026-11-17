TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 修正 Codex 正常打字时翻译提示闪现和停顿：隐藏时不再操作窗口，选区读取与复核移到后台，按键取消过期提示；被动划词不再强制展开其他应用的辅助功能树。
- 翻译按钮改为 24×24 的透明小图案，仅保留实心手绘圆圈与两条横线；整块可点击，去掉底板、描边卡片和阴影。
- 首页标题改为 Insight；右侧显示实际快捷键键帽、引擎信息和版本检查更新入口，侧栏增加信封“联系我们”、设置齿轮和帮助入口。
- 滚动滑块悬停加亮、略微加宽；保留原生惯性，进度与渐隐使用独立图层，首页点阵仅在尺寸变化时重建，减少重复绘制。
- 设置改为可独立拖动的 940×652 窗口，顶部 44 点拖拽区避开关闭按钮和滚动内容，窗口圆角增至 24；系统状态在后台加载，去掉顶部蓝色进度条。
- 首页统计采用 250ms 从零递增；热力图按周列依次弹入，每列 300ms、间隔 40ms，配合 1→1.2→1 缩放与白色遮罩。
- 设置淡入 225ms、淡出 195ms；统一 wave 骨架屏、双条更新进度和伸缩加载圆环，支持减少动态效果。
- 沿用长期发布签名；本次直接打包发布，跳过测试和冒烟测试。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Fix unwanted translation offers and pauses during typing in Codex. Hidden offers no longer touch windows. Selection reads and rechecks run in the background, typing cancels stale offers, and passive selection no longer forces other apps to expose a full accessibility tree.
- Use a transparent 24×24 translation mark: a filled hand-drawn circle and two lines, with the full area clickable. Remove the plate, card border and shadow.
- Rename the Home heading to Insight. Show configured shortcut keycaps, engine details and version/update controls on the right; add Contact Us, Settings and Help to the sidebar footer.
- Brighten and slightly widen scroll thumbs on hover. Keep native momentum while progress/fade layers and retained Home dots reduce redraw work.
- Make Settings an independently movable 940×652 window with a 44pt drag strip clear of controls and scrolling, 24pt window corners, background status loading and no blue top progress strip.
- Count Home metrics up from zero in 250ms. Reveal heatmap week columns with a 300ms scale pulse and white cover, staggered by 40ms.
- Fade Settings in over 225ms and out over 195ms. Share wave skeletons, dual-bar update progress and stretching circular loaders, with Reduce Motion support.
- Retain the persistent publisher signature. Build and publish directly; skip tests and smoke tests.
<!-- /typeleast-update -->

## 安装 / Installation

仅支持 macOS 14 及以上的 Apple 芯片 Mac。语音模型单独下载，Windows 与 Intel 版不再更新。

本版继续使用固定自签发布证书，尚无 Apple 公证。若仍在使用 2.1.6 或更早的签名身份，请直接下载安装，建立固定发布签名基线。

Requires macOS 14 or later on Apple silicon. Speech models are downloaded separately. Windows and Intel releases remain at their previous versions.

This release retains the persistent self-signed publisher certificate and is not notarized by Apple. If you still use the signing identity from 2.1.6 or earlier, install directly to establish the publisher-signed baseline.

按用户要求，本次不运行测试和运行时冒烟步骤。
Tests and runtime exercises are skipped for this owner-requested release.

[完整记录](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md) · [代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)
