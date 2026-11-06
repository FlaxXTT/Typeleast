TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 提示词模式在可核实的情况下，推荐目标应用的思考模式和推理强度；未能确认时提示以目标应用和账户权限为准。
- Mac 听写改用 Apple 芯片上的 MLX，并提供 Fun-ASR-Nano、Qwen3-ASR 0.6B 和 1.7B 模型选择。
- 扩大稳定底噪检测；当整理可能改变数量单位时，保留识别原文和整理结果供核对。
- 新手听写练习使用选定麦克风，并分别显示原始识别和整理结果。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Prompt mode can suggest a thinking mode and reasoning effort when supported settings can be verified. Availability depends on the target app and account.
- Mac dictation now uses MLX on Apple silicon, with Fun-ASR-Nano and Qwen3-ASR 0.6B and 1.7B model choices.
- Improved detection of steady background noise; review is offered when cleanup may have changed a quantity's unit.
- Dictation practice uses the selected microphone and shows both the original transcript and the cleaned result.
<!-- /typeleast-update -->

## 安装 / Installation

本版仅支持 **macOS 14 及以上、Apple 芯片**。从 1.24.19 或更早版本升级时，请先手动下载 DMG 并安装一次；旧版软件内更新可能提示下载失败。安装后，后续更新可由新版应用检查。macOS 13 用户请继续使用 [1.24.19](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.24.19)。

MLX 听写模型需要单独下载；已有 ONNX 模型权重不能直接使用。Fun-ASR-Nano 约 1.68 GB，Qwen3-ASR 0.6B 约 1.58 GB，1.7B 约 4.09 GB。旧模型文件不会被自动删除。Windows 版不再更新，最终版是 [1.24.17](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.24.17)。

This release requires macOS 14 or later and Apple silicon. Users of 1.24.19 or earlier must install the DMG manually once; in-app updating from the old version may fail. MLX speech models are downloaded separately and cannot reuse ONNX weights. Windows and Intel releases remain available at their previous versions.

[完整记录](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md) · [代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)
