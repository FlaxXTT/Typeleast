# Third-party notices

TypeLeast uses or downloads the following work. Each keeps its own licence.

## Shipped inside the release packages

| Component | Where | Licence |
|---|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (`sherpa-onnx-node` and its per-platform packages, including ONNX Runtime) | `service/node_modules/`, inside both apps | Apache-2.0 |
| [Node.js](https://nodejs.org) (official release binary, checked against nodejs.org's SHA-256 list) | macOS: `TypeLeast.app/Contents/Resources/node/`; Windows: `node\` | MIT (its `LICENSE` is shipped beside the binary) |
| [NAudio](https://github.com/naudio/NAudio) (`NAudio.WinMM`, `NAudio.Core`) | Windows app, microphone capture | MIT |
| .NET runtime (self-contained Windows build) | Windows app | MIT |
| Microsoft Visual C++ runtime (`vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140.dll`) | Windows: next to the sherpa-onnx DLLs | Microsoft Visual C++ Redistributable licence |

## Downloaded by the app on first use (not part of this repository or the packages)

| Model | Source | Notes |
|---|---|---|
| SenseVoice Small, int8 ONNX export | [FunAudioLLM/SenseVoice](https://github.com/FunAudioLLM/SenseVoice), converted by the sherpa-onnx project ([Hugging Face](https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17)) | Use is subject to the model publisher's licence. |
| Silero VAD | [snakers4/silero-vad](https://github.com/snakers4/silero-vad) ([Hugging Face mirror](https://huggingface.co/csukuangfj/vad)) | MIT |

The files are verified by size and SHA-256 before use (`service/lib/models.js`).

## Budget Typeless DIY prompt

The cleanup system prompt in `service/lib/prompts/erduo-budget-typeless.js`
is reproduced verbatim from the following article:

- Title: *Budget Typeless DIY: 1/10 the Cost, 85% the Effect*
- Author: Erduo
- URL: <https://erduo.dev/en/blog/diy-typeless-asr-prompt/>
- Published: 2026-01-16 (V2; the article targets GLM-4.7 at temperature 0.8)

The article does not state an open-source licence. The text is included here at
the request of this project's owner, with attribution, for personal use.
**Redistribution requires permission from the author**: before this repository
or its release packages are made public, obtain that permission or replace the
prompt.

No code was copied from the article; only the prompt text, and the two
demonstrations it publishes, which define the `{status, text, reason}` output
schema.
