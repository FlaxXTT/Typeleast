TypeLeast：按一下，说话。再按一下，文字写到光标处。

## 本次更新 / What is new

<!-- typeleast-update:zh -->
- 会议录音时显示实时文字，结束后重新整理并区分说话人。
- 模型设置增加文件与未完成下载的清理；加入 Qwen3-ASR 1.7B 8-bit 选项。
- 翻译显示原文字符和词数；需要核对的整理稿可编辑，可疑内容高亮。
- 整理服务支持备用服务商；系统不允许静默读取 Key 时会跳过该服务商。
- 加强本地通信与事实核对，更新图标和交互。
<!-- /typeleast-update -->

<!-- typeleast-update:en -->
- Meeting recordings show a live transcript, followed by a complete speaker-labeled transcript.
- Manage model files and incomplete downloads in Settings; Qwen3-ASR 1.7B 8-bit is available.
- Translation shows source character and word counts. Review and edit flagged cleanup results.
- Cleanup can use backup providers when their saved keys are available without an authentication prompt.
- Improved local communication, fact review, icon, and interface interactions.
<!-- /typeleast-update -->

## 安装 / Installation

仅支持 macOS 14 及以上的 Apple 芯片 Mac。语音模型单独下载；Windows 和 Intel 版不再更新。Qwen3-ASR 1.7B 8-bit 已提供选项，准确率及运行速度尚未完成全面验证。会议实时文字为临时结果，最终说话人标签在录音结束后生成。

Requires macOS 14 or later on Apple silicon. Speech models are downloaded separately. Windows and Intel releases remain at their previous versions. Qwen3-ASR 1.7B 8-bit has not been comprehensively evaluated. Live meeting text is provisional; speaker labels are assigned after recording.

[完整记录](https://github.com/FlaxXTT/Typeleast/blob/main/CHANGELOG.md) · [代码签名政策](https://github.com/FlaxXTT/Typeleast/blob/main/docs/CODE_SIGNING_POLICY.md)
