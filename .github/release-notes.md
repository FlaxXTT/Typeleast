TypeLeast：按快捷键说话，本机识别，再用你选择的模型整理文字并插入光标处。

## 1.17.2 的变化

- **Mac 更新不再反复要求输入密码。** 窗口刷新时不再读取钥匙串，每次启动最多读一次；软件内更新时，旧版本把钥匙串条目交接给新版本。从 1.17.1 升级到这一版时仍会询问一次，以后的更新不再询问。
- **软件内更新**优先从公开发布页匿名下载，不再必须安装和登录 GitHub CLI；没有本机签名证书的 Mac 在第一次更新时自动生成。
- **安全**：App 只连接自己启动的本地服务，并先做身份校验，防止其他程序伪造服务截获 API Key；发布版不再包含自检和演示用的环境变量入口。
- **隐私**：「参考输入框里的内容」改为默认关闭，与 Windows 一致。打开后，光标附近的文字和窗口标题才会（脱敏后）随听写发给整理模型。之前没有手动改过这个开关的用户，升级后会变为关闭。
- 修复「历史 → 从不保存」时仍把最后一条记录写入存储的问题。
- **Intel Mac 停止更新**，最终版是 [v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1)。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.17.2-macOS-AppleSilicon.dmg` 或 `.zip` |
| macOS 13 以上，Intel | 已停止更新，使用 [v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |
| Windows | 继续使用 [v1.17.0](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.0) |

Mac 构建号为 11。`SHA256SUMS.txt` 里有每个文件的校验值。

## 验证与限制

托管 CI 没有额度，本次使用本地构建与测试，结果见发布记录。未用私人录音或 API Key 做测试。Mac 安装包未经过 Apple Developer ID 公证。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。
