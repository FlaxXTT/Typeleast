TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 应用图标内五根声波柱的整体宽、高均设为内部区域的 61.8%，保留暖白背景、四根暖黑柱、一根品牌蓝柱和 Apple 连续圆角；Dock 与应用内图标同步。
- 首页使用量改为独立累计，不再因“不保留历史”或删除单条记录而归零；只保存字数、时长等统计数字，不保存听写文本。
- 从已有活动日志恢复累计字数。后续听写按实际录音时长统计口述时间，并估算节省时间；旧活动缺失的时长显示为“—”，语速仅按有时长的听写计算。
- 侧栏搜索框恢复为 40 点高度，分享按钮的图标与文字整体居中；主窗口显示后重新定位左上角原生按钮，使其留在 99 点圆角内。
- 沿用固定发布签名。按要求跳过测试和冒烟测试。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Set the five-bar waveform to 61.8% of the app icon's inner width and height. Keep the warm-white background, four warm-black bars, one brand-blue bar and Apple continuous enclosure. Use the same artwork in the Dock and app.
- Keep Home usage totals independent of transcript history. Disabling history retention or deleting one record no longer resets the totals. Store numeric counts and durations only, with no transcript text.
- Recover cumulative words from existing activity data. Record actual speech duration for new dictations and estimate typing time saved. Show a dash for missing older durations; calculate speech speed only from dictations with a recorded duration.
- Restore the sidebar search control to 40pt height. Centre the share icon and title together. Reposition native window buttons after presentation so they stay inside the 99pt corner.
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
