# TypeLeast

**Press Fn, speak, then press again. Your words appear at the cursor.**

TypeLeast is an open-source dictation app for macOS. Write messages and drafts by voice, translate what you say, or insert a Skill into the app you’re using.

[Download the latest release](https://github.com/FlaxXTT/Typeleast/releases/latest) · [User guide](docs/user-guide.en.md) · [简体中文](README.md)

**Apple silicon · macOS 14 or later**

![Silent demo with synthesized Mandarin. TypeLeast inserts the corrected meeting time into a text editor after dictation.](docs/media/demo.gif)

## Three shortcuts

| Default shortcut | What you do | Where the result goes |
| --- | --- | --- |
| **Fn** | Press to start dictation, then press again when you finish | At the cursor |
| **Fn + Left Shift** | With no selection, press to start and stop speaking. With text selected, press once | Spoken translations go at the cursor. Selected-text translations open in a separate panel |
| **Fn + Space** | Hold both keys to open Harness EQ, hover over an imported item, then release both | The Skill text or invocation instructions go at the cursor |

You can change the dictation and translation shortcuts in their respective Settings pages.

## Your first dictation

1. Download the Apple silicon DMG from the release page and drag TypeLeast into Applications.
2. Open TypeLeast. Try the built-in examples for dictation, translation, and Skills. On the final page, download a local speech model or enter a key for a cloud speech provider.
3. Allow Microphone and Accessibility access. In a blank TextEdit document, press **Fn**, say a sentence, and press it again to see the text appear. You can also open TextEdit from **Try dictation** on Home.

Speech recognition is enough for basic dictation. To use AI cleanup or translation, configure a text model under **Settings → Models**. [Setup and troubleshooting](docs/user-guide.en.md)

## Invoke and archive Skills with Harness EQ

Import Skills and MCP entries under **Settings → Harness EQ**. Standalone Skills insert their full text. Skills with dependencies insert directions for reading the entry file and its supporting files. MCP entries give the target agent instructions for using the tools it has available.

<details>
<summary>Copy the Skill archival prompt for your agent</summary>

```text
Archive the Skill I specify in TypeLeast → Settings → Harness EQ → Skill. If I haven’t provided a name or path, ask me for it. Work only on the item I specify.

1. Choose Save in TypeLeast for a standalone Skill. For a Skill with dependencies, import a .skill or .zip package with SKILL.md and the required files. Preserve their relative paths, the Skill body, and required fields.
2. Verify that Harness EQ can invoke the archived copy. A standalone Skill should return the full text. A Skill with dependencies should point to the archived SKILL.md and allow its supporting files to be read relative to that file. Read the files for verification without running their scripts or instructions.
3. After verifying, move the specified original to Trash if I explicitly asked you to archive and remove it. Otherwise, ask me: “I verified that the archived copy works through Harness EQ. The original agent may stop auto-loading the old entry. Should I move the original to Trash?”
4. Keep the original and explain why if invocation still depends on the original path, another project references it, or you can’t verify the required files. If you can’t operate TypeLeast, tell me which step to do myself.

Report which Skill you archived, what you verified, and whether you moved the original to Trash.
```

</details>

## Where your data goes

With local recognition, audio stays on your Mac. With cloud recognition, audio goes to the provider you choose. Cloud cleanup and translation send the applicable text to your configured model. macOS Keychain stores API keys. [Data flow and retention](docs/user-guide.en.md#privacy-and-local-data)

## Project links

[Changelog](CHANGELOG.md) · [Legacy downloads](docs/user-guide.en.md#legacy-downloads) · [Build from source](apps/macos/README.md#build-test-package) · [Code signing](docs/CODE_SIGNING_POLICY.md) · [Report an issue](https://github.com/FlaxXTT/Typeleast/issues/new) · [MIT license](LICENSE)

### Issue reporters

- Thanks to [pioneerAlone](https://github.com/pioneerAlone) for the MLX shutdown reproduction steps and logs, and for reporting a cold-start issue. [#107](https://github.com/FlaxXTT/Typeleast/issues/107)
- Thanks to [tomcatcoffee](https://github.com/tomcatcoffee) for the recording-window crash trace. [#179](https://github.com/FlaxXTT/Typeleast/issues/179)
