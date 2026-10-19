TypeLeast：按快捷键说话，本机识别，再用你自己的整理模型处理文字并插入光标处。

## 1.16.0 的变化

- 新增独立翻译快捷键，支持 10 种目标语言。
- 新增中文简体、台湾繁体、香港繁体，以及美式、英式英文拼写选项。
- 首页新增活动热力图、活跃天数和连续使用天数，只保存日期和计数。
- 新增「提示词 Beta」：先澄清需求，再起草并审查提示词；比普通整理更慢，模型调用次数更多。
- Mac 加入菜单栏与常用编辑快捷键修复。
- 安全加固：Mac Hardened Runtime、资源完整性检查和单实例锁；两端本地服务启动过滤危险环境变量，向已识别终端粘贴时压平换行。
- Mac 历史及保留录音加密，Windows 历史实现当前用户 DPAPI；旧数据迁移失败保留原数据并提示，不回退为明文。服务历史默认只存文字摘要。

## 本次安装包与验证范围

本次提供 Mac 安装包；Windows 用户继续使用 [v1.5.0](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.5.0)，本次没有 Windows 1.16.0 安装包。

| 系统 | 文件 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.16.0-macOS-AppleSilicon.dmg` 或 `.zip` |
| macOS 13 以上，Intel | `TypeLeast-1.16.0-macOS-Intel.dmg` 或 `.zip` |

服务 199 项、Mac 392 项、Windows 核心逻辑在 Mac 上 164 项测试通过。四个识别模型完成 28 次公开样例识别。Mac 两种架构完成编译、打包及签名验证，Apple 芯片包内 Node、本地服务及默认模型启动通过；Intel 包没有在 Intel 或 Rosetta 环境运行。本次没有使用已无额度的托管 CI。

Windows 原生加密、Windows 真机 UI、Linux 原生执行和长期压力测试尚未完成。独立更新签名与本地服务身份认证仍是已知缺口，不能视为已解决。

## 安装与更新

Mac 安装包包含 Node.js 和识别引擎，模型沿用现有下载方式。发布包没有 Apple Developer ID 公证。已有用户可在 App 内检查更新；这台 Mac 的更新会继续使用已有的本机签名证书，不导出证书。

首次启动新版会迁移旧历史与保留录音。重置系统凭据可能使加密历史无法解密；迁移或保存失败会保留原数据并提示。终端保护仅覆盖已识别终端。

完整变化见 [CHANGELOG.md](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)，验证边界见 [1.16.0 验证记录](https://github.com/FlaxXTT/Typeleast/blob/main/docs/v1.16.0-验证记录.md)。文件校验记录随安装包提供。
