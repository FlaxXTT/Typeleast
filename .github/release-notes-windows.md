TypeLeast：按快捷键说话，本机识别，再用你自己的整理模型处理文字并插入光标处。

## 1.16.2 的变化

- **两端自然整理同步新提示词**，正文按维护者提供的版本保留。数字、百分比、日期和版本号的转换可通过防编造检查；模型返回 `uncertain` 时使用其最佳猜测，结果仍须通过校验。
- Mac 同步 DeepSeek 官方预设修正，模型提示改为 `deepseek-flash`；已保存的地址、模型和 Key 不自动改写。
- Windows 修复部分应用只复制不粘贴、录音开头截断等问题；处理中可取消，整理失败显示分类原因。
- Windows 更新录音条、波形、字体、提示音、圆角和五页设置；首页、设置、托盘及任务栏菜单可切换整理档位。
- Windows 包含翻译、语言变体、活动热力图、历史筛选与同一录音重试、词典来源与 CSV 导入等此前已合并的功能。

## 下载哪个

| 电脑 | 文件 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.16.2-macOS-AppleSilicon.dmg` 或 `.zip` |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.16.2-Windows-x64-Setup.exe` 或 `TypeLeast-1.16.2-Windows-x64-Portable.zip` |

本次共 6 个安装包，全部为 1.16.2。Mac 构建号为 8，不附带旧 Mac 1.16.0 包。文件校验清单随包提供。

## 验证范围

本轮服务 208 项、Mac 392 项、Windows Core 在 Mac 上 525 项测试通过，Windows 应用交叉编译通过（保留既有 WFAC010 警告）。本地化检查通过。Mac 两种架构的打包、版本与签名检查通过；Windows 便携包中的服务代码和新提示词与对应源码一致。

Windows 安装文件由维护者提供，此前交接说明其使用 .NET 8 和 Wine 中的 Inno Setup 构建。本轮没有 Windows 真机安装与界面操作验证，也没有 Intel 或 Rosetta 运行验证。Windows 原生 DPAPI 分支未在本机执行。未读取真实 API Key，未使用真实模型试用新提示词，不将单元测试当作整理效果证明。托管 CI 没有额度，本次沿用维护者已授权的本机验证与手动发布方式，不声称三平台 CI 通过。

## 安装与已知限制

Mac 包没有 Apple Developer ID 公证。已有用户可在 App 内检查更新；这台 Mac 继续使用现有本机证书重签，不导出证书。Windows 安装包没有代码签名；识别引擎需要 Microsoft Visual C++ 运行库（x64）。

连接测试成功只说明短请求可达，不能保证每次整理成功。已保存旧 DeepSeek 模型的用户需自行改为当前有效模型。新提示词真实效果、Windows 真机 UI、长期压力测试仍需继续验证；独立更新签名与本地服务身份认证仍是已知缺口。

完整变化见 [CHANGELOG.md](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)，本轮记录见 [1.16.2 发布交接](https://github.com/FlaxXTT/Typeleast/blob/main/docs/v1.16.2-发布交接.md)。
