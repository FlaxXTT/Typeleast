TypeLeast：按快捷键说话，本机识别，再用你选择的模型整理文字并插入光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 新增「扩展」：可安装词库和风格两种插件，插件市场读官方目录。
- 词典只把这次听写提到的词发给模型；词条可标「不发给模型」。
- 保留录音改为约 5 分钟后删除，退出 App 时也会删除。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- New Extensions: install dictionary packs and styles from the official plugin market.
- Only the dictionary words a dictation mentions go to the model; entries can be kept from it entirely.
- Kept recordings are deleted after about 5 minutes, and when you quit.
<!-- /typeleast-update -->

**扩展：** 左侧栏新增「扩展」，第一版只有两种数据插件，不运行代码。词库是一组术语写法，只把某次听写提到的词发给模型；风格是附加在标准、精简整理上的写法说明，在左侧栏切换。安装前会显示内容、来源和数据去向，确认安装的就是所显示的那份内容。插件市场只在打开时读一次官方目录（官网或 GitHub 官方地址），不带任何你的数据。规范见[插件规范](https://github.com/FlaxXTT/Typeleast/blob/main/docs/插件规范.md)。

**词典外发：** 整份词典只交给本机服务，只有这次口述（以及你允许读取的输入框内容）提到的词，按写法相同或读音相近发给模型。读音匹配可能误判；敏感词可以在词典里标「不发给模型」，它就不会出现在任何模型请求里，填了「常被识别成」时由本机替换成正确写法。

**保留录音：** 打开「保留录音」时，录音约 5 分钟后删除；退出 App 时全部删除，电脑唤醒后补删过期的，异常退出则下次启动时删除。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.20.0-macOS-AppleSilicon.dmg` 或 `.zip` |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.20.0-Windows-x64-Setup.exe`（安装版，支持自动更新）或 `TypeLeast-1.20.0-Windows-x64-Portable.zip` |
| Intel Mac | 已停止更新，最终版为 [v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |

已安装的用户可在软件内检查更新；Windows 安装版保留自动更新行为。Mac 构建号为 23。

## 验证与限制

服务、Mac 和 Windows 核心测试及三平台 CI 通过。Mac 扩展页用虚构数据离屏渲染检查；Windows 界面只经过编译、单元测试和 CI 渲染，未进行真机人工操作验证；睡眠唤醒和退出时删除录音未在真机实测。

Mac 包未经过 Apple Developer ID 公证；Windows 包未进行代码签名，浏览器或 SmartScreen 可能提示下载信誉不足。请从本仓库下载。四个安装包的校验值位于 `SHA256SUMS.txt`。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。[代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)。
