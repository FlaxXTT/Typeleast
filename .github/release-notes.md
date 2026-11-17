TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 按新的分级规范调整界面：基础圆角 8、控件 6、列表组 10、卡片 12、首页和侧栏 20、普通面板 16；主侧栏宽 210，页面左右间距 24、顶部留出 44。
- 随包加入 Prompt 标题字体：首页标题 48、其他页面标题 36、区块标题 24；历史正文 14/22、时间列宽 52，分组首尾圆角 10，中间项无分隔线。
- 设置改为 940×652 独立弹窗，包含 202 宽分类栏、独立滚动内容和 24 点关闭按钮；保持设置入口和分类跳转。
- 图标所有使用位置统一为底板宽高各 0.618；应用内和官网去掉画布透明外边距，Dock/Finder 保留系统画布边距。
- 修正主题翻牌的过早退出路径：等待新外观完成显示帧再截帧；遮罩放到原生窗口容器，主窗口与设置弹窗同步执行对角线 3D 瓦片翻转。
- 全部滚动界面统一使用原生滚动容器与原生滚动条；进度、渐隐和位置记忆按显示帧合并，缓存内容高度，空闲时停止回调；普通弹窗不增加滚动观察开销。
- 命令搜索缓存查询结果并按需创建行，鼠标悬停不再触发自动定位；会议实时文字仅在停留底部时跟随新内容，向上阅读时保持当前位置。
- 沿用长期发布签名；本次按要求跳过测试和冒烟测试。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Apply the new geometry: 8pt base corners, 6pt small controls, 10pt list groups, 12pt cards, 20pt Home/sidebar surfaces and 16pt panels. Use a 210pt main sidebar, 24pt horizontal page insets and a 44pt top region.
- Bundle Prompt heading fonts at 48pt on Home, 36pt on other pages and 24pt for sections. History uses 14/22 text, a 52pt time column, 10pt group corners and no middle-row dividers.
- Open Settings as a separate 940×652 dialog with a 202pt category pane, independent content scrolling and a 24pt close button. Keep existing Settings entry points and category navigation.
- Use the same 0.618 waveform ratio for all icon surfaces. Remove transparent canvas margins from in-app and website marks; keep the system canvas margin for Dock/Finder icons.
- Repair early exit in theme flipping. Wait for new-appearance display frames before capture, place covers above the SwiftUI hosting hierarchy, and run the diagonal 3D mosaic on both the main window and Settings dialog.
- Use native scrolling across all pages and panels. Coalesce progress, fade and position updates to display frames, cache content height, and pause callbacks while idle. Plain popups add no scroll-observation work.
- Cache command-search results and create rows as needed. Hover no longer requests scrolling. Live meeting text follows additions only while the reader stays near the bottom.
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
