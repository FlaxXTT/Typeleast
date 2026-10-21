TypeLeast：按快捷键说话，本机识别，再用你自己的整理模型处理文字并插入光标处。

这个版本同时提供 **Windows 1.16.2** 和当前的 **Mac 1.16.0** 安装包（Mac 没有变化），按你的电脑选择下载。

## 下载哪个

| 你的电脑 | 文件 |
|---|---|
| Windows 11 / 10（1809 以上），64 位 | `TypeLeast-1.16.2-Windows-x64-Setup.exe`（安装版）或 `…-Portable.zip`（解压即用） |
| Mac · Apple 芯片 | `TypeLeast-1.16.0-macOS-AppleSilicon.dmg` |
| Mac · Intel 芯片 | `TypeLeast-1.16.0-macOS-Intel.dmg` |

## Windows 1.16.2 的变化

**更好用**
- 修复：很多应用里文字只复制、没有粘贴到光标处。
- 修复：说话开头被截掉。现在先打开麦克风；录音条圆点变红后再说话。
- 整理档位一键切换：首页、设置、托盘菜单、任务栏按钮右键菜单都可以切换。
- 提示词在文件中编辑（记事本打开，保存即生效），补充要求仍在设置里填写。

**更好看**
- 重新设计的录音条：更小，波形居中对称、跟着声音实时起伏。
- 内置开源字体（Inter 和思源黑体，SIL OFL），加大字距和行距。
- 设置分为五个标签页；输入框、下拉框和托盘菜单改为圆角，支持浅色和深色。
- 新的提示音：开始清脆，结束柔和，不再使用 Windows 系统声音。

**整理效果**
- 自然整理改用项目自己的提示词：数字和日期写成阿拉伯数字（一百二十三 → 123、三点一二 → 3.12、百分之二十五 → 25%），按上下文纠正同音词（cloud → Claude），更多中英文术语映射。

**其他**
- Windows 与 Mac 界面结构对齐：历史筛选和搜索、同一录音重试、词典来源和 CSV 导入、插入方式（自动粘贴、仅复制、先预览）。
- 处理中可以取消；整理失败时显示分类原因，不记录正文和 Key。
- DeepSeek 官方预设的模型提示改为 `deepseek-flash`；已保存的模型不自动改写。

完整变化见 [CHANGELOG.md](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。

## 安装

- **Windows**：安装包没有代码签名，SmartScreen 可能提示「Windows 已保护你的电脑」：点「更多信息 → 仍要运行」。安装不需要管理员权限。识别引擎需要 Microsoft Visual C++ 运行库；如果识别无法启动，请安装 Visual C++ Redistributable（x64）。
- **Mac**：把 TypeLeast 拖进「应用程序」。第一次打开如被拦下，到「系统设置 → 隐私与安全性」点「仍要打开」。

第一次打开时会下载一次语音模型（约 241 MB）。下载慢可在「设置 → 服务与更新 → 模型下载镜像」填 `https://hf-mirror.com`。

## 验证范围

Windows 安装包在 Linux 上用 Microsoft .NET 8 SDK 和 wine 中的 Inno Setup 构建，没有使用 GitHub Actions。Windows 核心逻辑 525 项、服务 204 项测试通过（1 项因没有识别模型而跳过）；界面在 Windows 真机上由维护者试用确认。文件校验值见 `SHA256SUMS.txt`。
