# TypeLeast user guide

[Back to the README](../README.en.md) · [简体中文](user-guide.md)

## Install and try dictation

The current release requires macOS 14 or later on an Apple silicon Mac. [Download the latest release](https://github.com/FlaxXTT/Typeleast/releases/latest)

1. Open the DMG and drag TypeLeast into Applications. When upgrading, replace the app and keep its data. The installer includes the runtime. You download speech models as needed.
2. Open TypeLeast and play the built-in examples. On the final page, pick a speech recognition option and allow Microphone and Accessibility access. You can also go to Home and finish setup later.
3. Open TextEdit, press ⌘N for a blank document, and click in it. Press Fn, say a sentence, and press Fn again. Seeing your text in the document completes the first try.

The app uses a persistent publisher certificate and has yet to be notarized by Apple. Use the SHA-256 file on the release page and the signing documentation to verify the download. [Code signing and Keychain migration](CODE_SIGNING_POLICY.md)

## Choose a speech recognizer and a text model

Open **Settings → Models**. Speech recognition and text cleanup are configured separately.

| Purpose | Option | Setup |
| --- | --- | --- |
| Speech recognition | Local MLX | Download and select a local model in the app. It runs on your Mac after setup |
| Speech recognition | Doubao ASR 2.0 or Alibaba Cloud Fun-ASR Realtime | Save a speech API key. For a non-default Alibaba Cloud workspace, also enter its workspace ID |
| Cleanup and translation | An OpenAI-compatible service or local Ollama | Set the provider and model ID, then save a key if required. Remote endpoints use HTTPS. A local Ollama instance can use loopback HTTP |

Presets include DeepSeek, Zhipu GLM, Kimi, Qwen, OpenRouter, OpenAI, and Ollama. You can also configure a custom endpoint. Enter the provider’s base URL. Use the model picker or connection test in Settings to check what is available. Cloud providers may bill you separately.

Basic dictation needs speech recognition and system permissions. You can turn text cleanup off in Dictation settings. With a selection, the translation shortcut opens a separate panel. With no selection, the same shortcut starts or stops recording and inserts the translation at the cursor.

### Vocabulary and conferences

- Use **Vocabulary** for hotwords and replacement rules. Replacements are applied locally to dictation and conference transcripts. Set Doubao console vocabulary table IDs separately in Models.
- **Conference** supports local MOSS and Doubao Recording File Recognition 2.0. Doubao conference recognition requires a speech API key and a private TOS bucket. The app uses that bucket to submit the recording or imported file for recognition.

## Harness EQ

Under **Settings → Harness EQ**, import selected items from local files, scan results, or a public GitHub link. You can store standalone Markdown Skills in the app and import packaged Skills with dependencies. MCP entries provide invocation instructions for the target agent.

Before moving an original file, check that Harness EQ calls the archived copy. For a Skill with dependencies, verify the archived `SKILL.md` and the files it references relative to its directory. **Save source** may still point to the original. The prompt on the README guides an agent through the check and moves the original only when authorized.

## Privacy and local data

| Feature | Where data goes |
| --- | --- |
| Local speech recognition | Audio is processed on your Mac |
| Cloud speech recognition | Audio goes to the selected speech provider. Doubao dictation streams during recording. Alibaba Cloud dictation uploads after recording. Doubao conference audio goes through your configured private TOS bucket |
| Cloud cleanup and translation | Applicable transcripts or selected text go to the configured model. Enabled cursor context, history-derived profiles, and fallback providers follow your settings |
| Model downloads and updates | Downloaded from the listed model source, your selected mirror, or public release hosting as applicable |

macOS Keychain stores API keys. History text is encrypted on your Mac. If **Keep recordings** is enabled, retry audio is encrypted on disk for about five minutes. For clipboard-based insertion, TypeLeast briefly uses plain text and then restores the previous contents. Clipboard managers may keep their own copies. [Privacy and update details](CODE_SIGNING_POLICY.md#privacy-policy)

## Troubleshooting

- **Fn opens emoji or switches keyboards.** In **System Settings → Keyboard**, set the Globe key action to **Do Nothing**, or assign another shortcut for dictation.
- **Recording or text insertion fails.** Check Microphone and Accessibility under **System Settings → Privacy & Security**. Retry in the same blank document. If transcription completed, check History for the result.
- **The local service is unavailable or a model download fails.** Restart the local service from Home or retry the model download in **Settings → Models**. Use the app’s mirror retry option if the model host is difficult to reach.
- **A cloud key is saved but the model doesn’t work.** Test the connection in the relevant model section. For Doubao conference recognition, also verify that the recording file service is enabled and that the private bucket is configured.

## Legacy downloads

| Platform | Last available release |
| --- | --- |
| Intel Mac | [v1.17.1](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.17.1) |
| Windows 10 / 11 (64-bit) | [v1.24.17](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.24.17) · [Windows documentation](../apps/windows/README.md) |
| macOS 13 | [v1.24.19](https://github.com/FlaxXTT/Typeleast/releases/tag/v1.24.19) |

[Changelog](../CHANGELOG.md) · [Build and test on macOS](../apps/macos/README.md#build-test-package) · [Third-party licenses](../THIRD-PARTY-NOTICES.md)

## Demo archive

[24-second historical demo](media/promo-en.mp4) · [Mandarin](media/promo.mp4) · [72-second historical demo](media/film-long.mp4)
