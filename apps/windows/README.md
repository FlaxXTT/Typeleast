# TypeLeast — Windows app

tap Right Alt, speak, tap again, and the cleaned-up text is pasted at the caret.
Recognition and cleanup are done by the TypeLeast local service (`../../service`),
which the app starts, watches and stops by itself.

| Project | What |
|---|---|
| `TypeLeast.Core` | Logic without WPF (the default history protector uses Windows DPAPI): the service client, settings, presets, the single-key tap detector, Node.js discovery. |
| `TypeLeast.Core.Tests` | A console test runner for Core (no test framework to download). |
| `TypeLeast` | The WPF app: tray icon, main window (首页 / 历史 / 词典 / 设置), recording bar, keyboard hook, microphone (NAudio), paste, Credential Manager. |
| `installer/TypeLeast.iss` | Inno Setup script: per-user install, no administrator rights. |
| `package.ps1` | Builds the release: self-contained `TypeLeast.exe` + service + Node.js → `Setup.exe` and a portable `.zip`. |

## Requirements

- To build: [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0), Node.js 22+ (for `npm`).
- To make the installer: [Inno Setup 6](https://jrsoftware.org/isinfo.php).

## Build and test

```powershell
dotnet run --project TypeLeast.Core.Tests -c Release
dotnet build TypeLeast\TypeLeast.csproj -c Release
$env:TYPELEAST_SERVICE_DIR = "<repository>\service"
dotnet run --project TypeLeast
.\package.ps1
```

`package.ps1` downloads the official Node.js zip, checks it against nodejs.org's
SHA-256 list, starts the bundled service once as a smoke test, and writes
`dist\TypeLeast-<version>-Windows-x64-Setup.exe` and `…-Portable.zip`.

## How it works

- **Hotkey**: a low-level keyboard hook recognises a clean single tap of the chosen
  key (Right Alt, Right Ctrl, Caps Lock or F8): down and up within 0.6 s with no
  other key in between. A lone Alt tap would open the focused window's menu bar,
  so an unassigned key (VK 0xE8) is sent in between. Esc is consumed while
  recording and cancels. The hook reads key codes only, never what is typed.
- **Recording**: 16 kHz mono 16-bit through the Windows wave mapper, in memory only.
- **Paste**: clipboard + Ctrl+V into the window that was in front when recording
  started; if another window is in front by then, the text is only copied. The
  previous clipboard text is put back afterwards.
- **Service**: started from `service\` beside `TypeLeast.exe` with the bundled
  `node\node.exe` (or a Node.js 22+ found on the system), with `--parent-pid`.
- **API key**: Windows Credential Manager, generic credential
  `TypeLeast.llm-api-key/<preset>`.

## Files

| Path | What |
|---|---|
| `%APPDATA%\TypeLeast\app-settings.json` | the app's settings (no key) |
| `%APPDATA%\TypeLeast\app-history.json` | current-user DPAPI encrypted dictations (500 at most; legacy JSON is migrated) |
| `%APPDATA%\TypeLeast\typeleast-app.log` | events and error codes only |
| `%APPDATA%\TypeLeast\` | the service's token, runtime file, history, dictionary |
| `%LOCALAPPDATA%\TypeLeast\models\` | speech models (about 241 MB) |

## Storage and service safeguards

History migration replaces the old JSON only after encryption succeeds. If the
history cannot be decrypted or saved, the app preserves the original and reports
a storage error. Back up the user profile before moving encrypted history to a
new computer. Unit tests on other systems use a fake protector; native DPAPI tests
run only on Windows.

The bundled service takes priority over the development directory override.
Node startup and version probes remove code-loading environment variables and
variables that disable TLS verification. Paste to known terminal processes uses
one line with control characters removed. Embedded terminals may not be detected.
