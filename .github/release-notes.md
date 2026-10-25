TypeLeast：按快捷键说话，本机识别，再用你选择的模型整理文字并插入光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 发现新版本时先问你「立即更新」还是「稍后」，不再自动安装。
- 插件市场在国内网络下改用镜像，也能打开。
- 整理档位改为自然整理、精简整理、提示词 Beta，录音条显示当前档位。
- 翻译先整理原文再翻译，译文更准确。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- When a new version is found, you choose Update now or Later; nothing installs by itself.
- The plugin market uses mirrors when GitHub can't be reached.
- Cleanup modes are now Natural, Concise and Prompt Beta; the recording bar shows the mode.
- Translation cleans up the source first, then translates.
<!-- /typeleast-update -->

**更新由你决定：** 发现新版本时弹窗显示版本和更新内容，选「立即更新」才下载安装；选「稍后」本次运行不再询问，下次启动再问。Windows 设置里的「自动更新」改为「更新提醒」，关掉后只在「设置 → 服务与更新」里显示新版本。

**插件市场镜像：** 官网和 GitHub 连不上时，依次试 jsDelivr 和 ghfast.top 等公共镜像读取官方目录，遵守「更新下载源」设置。经镜像读到的目录会注明「经镜像获取」，安装前照常显示全部内容。

**整理与翻译：** 整理档位改为自然整理、精简整理、提示词 Beta，原话转写的设置自动改为自然整理；每次录音的悬浮条显示当前档位。翻译先在原语言中整理并校验，再译成目标语言；整理没通过时改用一次调用直接翻译。自然整理提示词强调忠实原意和最小修改，逐字母拼读（如「拼法是 R-O-G」）会合成单词。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.20.1-macOS-AppleSilicon.dmg` 或 `.zip` |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.20.1-Windows-x64-Setup.exe`（安装版，支持软件内更新）或 `TypeLeast-1.20.1-Windows-x64-Portable.zip` |
| Intel Mac | 已停止更新，最终版为 [v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |

已安装的用户可在软件内检查更新，发现新版本时会先询问。Mac 构建号为 24。

## 验证与限制

服务、Mac 和 Windows 测试及三平台 CI 通过；镜像地址已实测能读到目录。Windows 更新弹窗只经过编译、单元测试和 CI 渲染，未在真机上人工操作；国内网络下的插件市场未在真机实测。

Mac 包未经过 Apple Developer ID 公证；Windows 包未进行代码签名，浏览器或 SmartScreen 可能提示下载信誉不足。请从本仓库下载。四个安装包的校验值位于 `SHA256SUMS.txt`。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。[代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)。
