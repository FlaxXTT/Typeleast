TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 首页改为参考图的「洞察」布局：点阵背景、大数字统计、活动热力图；每次打开窗口时数字从 0 累加，活跃格子从左向右铺开。引擎移到右上方，最近记录放到页面底部。
- 统一暖灰配色、字体与控件样式；控件、卡片和弹窗采用 99px 圆角。主窗口固定为 1080×750，首次配置窗口为 940×610。
- 日夜主题切换增加带间隙的 3D 瓦片翻牌，从左上向右下依次翻转，横竖轴交替；减少动态效果时改为淡入。
- 录音条按状态变形，免提态使用 116×34 胶囊并保留两侧按钮；固定黑底、灰色取消键与白底黑勾，不随主界面主题变化。
- 降低波形灵敏度，加入语音门限滞回、平滑中心漂移与扩散宽度变化，缓和尾音和录音结束后的过渡。「转录已取消」提示以 1 秒淡出。
- 历史与设置内容区增加滚动位置记忆、进度、底部渐隐和回到顶部；增加 ⌘K 搜索与命令入口、复制成功反馈及单条删除撤销。
- 应用图标改为暖白底、四根暖黑柱和一根品牌蓝柱，使用 Apple 模板的连续圆角；Dock 与应用内共享矢量图形。
- 继续使用固定发布签名。本次按要求不运行测试和冒烟测试。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Redesign Home as Insights with a dotted background, large metrics and an activity grid. On each window opening, metrics count up from zero and active cells appear from left to right. Move Engine to the upper right and Recent to the bottom.
- Use warm neutral colours and consistent typography. Apply 99px corners to controls, cards and panels. Fix the main window at 1080×750 and setup at 940×610.
- Add a spaced 3D tile flip when switching between light and dark themes. Tiles travel diagonally from top left to bottom right, alternating horizontal and vertical axes. Use a fade with Reduce Motion.
- Reshape the voice bar for each state. Hands-free mode uses a 116×34 capsule with cancel and finish buttons. Keep its black background, grey cancel button and white finish button with a black tick in every theme.
- Reduce waveform sensitivity. Add voice-gate hysteresis, smooth centre drift and varying spread, with softer release and transcription transitions. Fade the transcription-cancelled notice out over one second.
- Add scroll-position memory, progress, bottom fades and back-to-top controls for history and settings. Add Command-K search and commands, copy feedback and undo for single-record deletion.
- Replace the app icon with a warm-white tile, four warm-black bars and one brand-blue bar. Use the continuous outline from Apple's icon template and share vector artwork across the Dock and app.
- Retain the persistent publisher signature. Skip tests and runtime exercises as requested.
<!-- /typeleast-update -->

## 安装 / Installation

仅支持 macOS 14 及以上的 Apple 芯片 Mac。语音模型单独下载，Windows 与 Intel 版不再更新。

本版继续使用固定自签发布证书，尚无 Apple 公证。若仍在使用 2.1.6 或更早的签名身份，请直接下载安装，建立固定发布签名基线。

Requires macOS 14 or later on Apple silicon. Speech models are downloaded separately. Windows and Intel releases remain at their previous versions.

This release retains the persistent self-signed publisher certificate and is not notarized by Apple. If you still use the signing identity from 2.1.6 or earlier, install directly to establish the publisher-signed baseline.

按用户要求，本次不运行测试和运行时冒烟步骤。
Tests and runtime exercises are skipped for this owner-requested release.

[完整记录](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md) · [代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)
