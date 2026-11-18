TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 首页统计卡改为等宽布局，调整圆角和热力图间距。打开、恢复或切回首页时，数字用 460ms 从零递增，热力图从左到右按周填色。
- 设置侧栏的「听写」「模型」「通用」整行可点，主题动画期间可继续操作。
- 明暗切换瓦片面积缩到约原来的八分之一，从左上到右下飞散、缩小并淡出。
- 检查、下载进度和重启使用同一个更新弹窗。后台检查只更新菜单。安装前收起设置与其他弹窗，退出等待超时可重试。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Home uses equal-width metric cards with refined corners and grid spacing. Opening, restoring or returning to Home counts up over 460 ms and fills the heatmap by week from left to right.
- Each Settings category is clickable across its full row and responds during theme transitions.
- Light and dark theme tiles are about one eighth of their former area. They scatter, shrink and fade from top left to bottom right.
- One update dialog shows the check, download progress and restart controls. Background checks update the menu. Settings and open sheets close before restart, and a quit timeout lets you retry.
<!-- /typeleast-update -->

## 安装 / Installation

仅支持 macOS 14 及以上的 Apple 芯片 Mac。语音模型单独下载，Windows 与 Intel 版不再更新。

本版继续使用固定自签发布证书，尚无 Apple 公证。若仍在使用 2.1.6 或更早的签名身份，请直接下载安装，建立固定发布签名基线。

Requires macOS 14 or later on Apple silicon. Speech models are downloaded separately. Windows and Intel releases remain at their previous versions.

This release retains the persistent self-signed publisher certificate and is not notarized by Apple. If you still use the signing identity from 2.1.6 or earlier, install directly to establish the publisher-signed baseline.

按用户要求，本次不运行测试和运行时冒烟步骤。
Tests and runtime exercises are skipped for this owner-requested release.

[完整记录](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md) · [代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)
