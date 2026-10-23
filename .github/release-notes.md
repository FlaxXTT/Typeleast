TypeLeast：按快捷键说话，本机识别，再用你选择的模型整理文字并插入光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 整理档位改为标准、精简、提示词 Beta、原话转写四档，放在左侧栏。
- 首页新增「设置在哪」，点一下直达；新手引导也会带你看一遍。
- 语音模型下载失败时给出镜像地址，可复制或一键用镜像重试。
- 界面文字更短；自动学习两端按同一规则判断，中文看读音。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Four cleanup modes, now in the sidebar: Standard, Concise, Prompt Beta and Verbatim.
- “Where things are” on Home takes you to each setting; the setup guide shows it too.
- If the speech model can't download, a mirror is offered to copy or retry with.
- Shorter wording. Learning from your fixes uses one rule on both platforms.
<!-- /typeleast-update -->

提示词模式的两档已删除，精简整理沿用原普通档的规则；选过提示词模式的用户会自动换到精简整理，原来的提示词配置（`promptify.json`）不再使用。提示词 Beta 和原话转写不变。

自动学习更正：粘贴后你改对的词由本地服务判断，两字以上、读音相近才学；只改一个汉字时不学。Mac 从历史里加入已在词典里的词时，不再覆盖原词条。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.19.0-macOS-AppleSilicon.dmg` 或 `.zip` |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.19.0-Windows-x64-Setup.exe`（安装版，支持自动更新）或 `TypeLeast-1.19.0-Windows-x64-Portable.zip` |
| Intel Mac | 已停止更新，最终版为 [v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |

已安装的用户可在软件内检查更新；Windows 安装版保留自动更新行为。Mac 构建号为 22。

## 验证与限制

服务、Mac 和 Windows 核心测试及三平台 CI 通过。Mac 界面用虚构数据离屏渲染检查；Windows 界面只经过编译、单元测试和 CI 渲染，未进行真机人工操作验证。

Mac 包未经过 Apple Developer ID 公证；Windows 包未进行代码签名，浏览器或 SmartScreen 可能提示下载信誉不足。请从本仓库下载。四个安装包的校验值位于 `SHA256SUMS.txt`。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。[代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)。
