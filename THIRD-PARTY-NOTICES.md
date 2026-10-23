# Third-party notices

TypeLeast uses or downloads the following work. Each keeps its own licence.

## Shipped inside the release packages

| Component | Where | Licence |
|---|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (`sherpa-onnx-node` and its per-platform packages, including ONNX Runtime) | `service/node_modules/`, inside both apps | Apache-2.0 |
| [Node.js](https://nodejs.org) (official release binary, checked against nodejs.org's SHA-256 list) | macOS: `TypeLeast.app/Contents/Resources/node/`; Windows: `node\` | MIT (its `LICENSE` is shipped beside the binary) |
| [opencc-js](https://github.com/nk2028/opencc-js) with the [OpenCC](https://github.com/BYVoid/OpenCC) dictionaries (Simplified to Traditional Chinese, 语言变体) | `service/node_modules/opencc-js/`, inside both apps | MIT (opencc-js) and Apache-2.0 (OpenCC dictionaries); both licence files ship with the package |
| [pinyin-pro](https://github.com/zh-lx/pinyin-pro) 3.29.5 (local pronunciation checks for dictionary suggestions) | `service/node_modules/pinyin-pro/`, inside both apps | MIT (`LICENSE` ships with the package) |
| [NAudio](https://github.com/naudio/NAudio) (`NAudio.WinMM`, `NAudio.Core`) | Windows app, microphone capture | MIT |
| .NET runtime (self-contained Windows build) | Windows app | MIT |
| [Inter](https://github.com/rsms/inter) 4.1 (Regular, Medium, SemiBold, Bold) and Inter Display (Regular, SemiBold, Bold) | Windows app, interface font (embedded in `TypeLeast.exe`) | SIL Open Font License 1.1 (`licenses\Inter-OFL.txt`) |
| [Noto Sans SC](https://github.com/notofonts/noto-cjk) (Regular, Medium, Bold), subset to GB2312 plus punctuation and the app's own text | Windows app, Chinese interface font (embedded in `TypeLeast.exe`); other characters use Microsoft YaHei UI. Both fonts are modified: wider character spacing (+0.03 em Inter, +0.01 em Inter Display, +0.06 em Noto Sans SC) and renamed "TypeLeast Inter", "TypeLeast Inter Display" and "TypeLeast Noto Sans SC" | SIL Open Font License 1.1 (`licenses\NotoSansSC-OFL.txt`) |
| Microsoft Visual C++ runtime (`vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140.dll`) | Windows: next to the sherpa-onnx DLLs | Microsoft Visual C++ Redistributable licence |

## Downloaded by the app on request (not part of this repository or the packages)

| Model | Source | Notes |
|---|---|---|
| SenseVoice Small, int8 ONNX export | [FunAudioLLM/SenseVoice](https://github.com/FunAudioLLM/SenseVoice), converted by the sherpa-onnx project ([Hugging Face](https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17)) | Use is subject to the model publisher's licence. |
| Silero VAD | [snakers4/silero-vad](https://github.com/snakers4/silero-vad) ([Hugging Face mirror](https://huggingface.co/csukuangfj/vad)) | MIT |
| FireRedASR2 CTC, int8 ONNX export | [FireRedTeam/FireRedASR2-AED](https://huggingface.co/FireRedTeam/FireRedASR2-AED), [sherpa-onnx export](https://huggingface.co/csukuangfj2/sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25) | Optional; Apache-2.0 according to the upstream model card. Only the CTC branch is used. |
| Fun-ASR-Nano, int8 ONNX export | [FunAudioLLM/Fun-ASR-Nano-2512](https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512), [sherpa-onnx export](https://huggingface.co/csukuangfj/sherpa-onnx-funasr-nano-int8-2025-12-30) | Optional; Apache-2.0 according to the upstream model card. |
| Qwen3-ASR-0.6B, int8 ONNX export | [Qwen/Qwen3-ASR-0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B), [sherpa-onnx export](https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25) | Optional; Apache-2.0 according to the upstream model card. |

Downloads and model activation verify file sizes and SHA-256. Fixed revisions,
checksums, upstream licence links and export links are listed in
`service/lib/models.js` and `service/lib/asr-catalog.json`. The smoke test uses a
short public `test_wavs/1.wav` example from the pinned FireRed export; test audio
is downloaded only for validation and is not shipped in the apps.
