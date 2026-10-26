TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 数量、日期和版本等优先使用阿拉伯数字，概数保留范围。
- 整理遵循改口、混合语言、信息忠实、语义排版和指令转录边界；保护明确的英文名称。
- 模型页提供 Qwen3-ASR-0.6B INT8 和 1.7B FP16，由你选择下载；不自动切换当前模型。
- 其他模型默认收起，支持兼容 ONNX 文件的本地检查与登记。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Quantities, dates and versions use digits where the value is clear. Approximate counts stay as ranges.
- Cleanup preserves corrections, mixed languages, facts and explicit English names. Dictated instructions remain content.
- Choose Qwen3-ASR-0.6B INT8 or 1.7B FP16. The update does not download or switch speech models automatically.
- Other models are collapsed. You can inspect and register compatible local ONNX files.
<!-- /typeleast-update -->

## 模型与资源

安装包不包含语音模型权重。现有可用模型继续使用，不会因更新自动下载大模型。

1.7B FP16 为独立转换包，前端是 FP32，编码器与解码器为 FP16。下载约 4.73 GB；Mac 实测加载峰值约 12.5 GiB，比 0.6B 更慢、内存更多。格式与模型大小不保证每条语音更准确。模型来源与对照结果见[模型说明](https://github.com/FlaxXTT/Typeleast/blob/main/docs/语音模型与精度.md)。

本地导入只支持现有适配器兼容的 ONNX。文件在独立进程中试加载，该进程不是操作系统安全沙箱；请只导入可信来源的模型。移除登记不删除原权重。

Beta 提示词不变。两步翻译保留。本版没有 MLX 后端扩展。

## 下载

| 电脑 | 安装包 |
|---|---|
| macOS 13 以上，Apple 芯片 | `TypeLeast-1.22.0-macOS-AppleSilicon.dmg` 或 `.zip` |
| Windows 10 1809 以上 / Windows 11，64 位 | `TypeLeast-1.22.0-Windows-x64-Setup.exe` 或 `TypeLeast-1.22.0-Windows-x64-Portable.zip` |
| Intel Mac | 不再更新。最终版：[v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |

已安装的用户可在软件内更新。Mac 构建号为 29。

## 验证与限制

功能 PR 的三平台 CI 通过。服务测试 349 通过、0 失败、1 项可选单测跳过；Mac 600 项、Windows 782 项、离线接口验收 46 项通过。脱敏、事实与本地化检查通过。两端中英文模型页已检查渲染结果，Windows 尚未真机操作。

1.7B FP16 在 Mac 本机、Windows CI 和 Linux CI 完成真实加载与识别。Mac 云端标准机器内存不足，本轮按维护者选择采用本机实测验收，云端明确跳过该模型，不记作识别通过。整理回归使用假模型，未调用真实外部整理服务。

Mac 包未经过 Apple Developer ID 公证。Windows 包没有代码签名。校验值在 `SHA256SUMS.txt`。

完整变化见 [CHANGELOG](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md)。[代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)。
