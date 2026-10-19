# TypeLeast — macOS app

press Fn (or ⌥Space), speak, press again, and the cleaned-up text is pasted at the
caret. Recognition and cleanup are done by the TypeLeast local service
(`../../service`), which this app starts, watches and stops by itself.

The bundle id is `com.dsh.voice` for continuity with earlier builds (settings,
history and the dictionary carry over).

## Requirements

- macOS 13 or later, Apple silicon or Intel.
- To build: Xcode command line tools (`xcode-select --install`) and Node.js 22+
  (`npm` installs the service's dependencies; a build from source also runs the
  service with this Node.js).

## Build, test, package

    ./test.sh                # unit and contract checks, no running service needed
    ./make-signing-cert.sh   # once per Mac: a local signing certificate, so rebuilds keep their permissions
    ./build.sh               # compile, bundle the service, sign, install ~/Applications/TypeLeast.app, relaunch
    ./build.sh --no-install  # build only (build/dist.noindex/TypeLeast.app)
    ./package.sh arm64       # self-contained release for Apple silicon (.dmg + .zip, with Node.js inside)
    ./package.sh x86_64      # the same for Intel (cross-compiled)
    ./Tools/render.sh [dir]  # offscreen PNGs of every page, with sample data
    ./Tools/demo/record-demo.sh <dir>  # the README demo GIF (synthetic voice, no microphone; see the script)

`TYPELEAST_ARCH=x86_64 ./build.sh` cross-builds for the other architecture.

## How it finds the local service

- The service is copied into `TypeLeast.app/Contents/Resources/service`
  (with `node_modules`, i.e. sherpa-onnx for the target architecture).
- Node.js: a release package carries its own at `Contents/Resources/node/bin/node`.
  Otherwise the app looks for Homebrew, the nodejs.org installer, Volta, nvm, fnm,
  mise, asdf and finally the login shell's `PATH`, and uses the first Node.js 22+.
  "设置 → 本地服务 → 选择 Node.js…" picks one by hand.
- The service is started with `--parent-pid`, so it exits when the app does. Its
  first stdout line carries the port; `~/Library/Application Support/TypeLeast/runtime.json`
  has it too. It is restarted with a back-off if it stops.
- `TYPELEAST_SERVICE_DIR=<repo>/service` makes a development build use the
  service from the repository, but only when the app carries no service of its
  own: an installed app never runs code an environment variable points to.
  `build.sh` bundles the service, so rebuild to pick up service changes.

## Files

| Path | What |
|---|---|
| `~/Library/Application Support/TypeLeast/` | the service's token, runtime file, history, dictionary, `config.json` |
| `~/Library/Application Support/TypeLeast/models/` | speech models (about 241 MB) |
| `~/Library/Preferences/com.dsh.voice.plist` | the app's settings and AES-GCM encrypted history |
| `~/Library/Logs/TypeLeast/typeleast.log` | events, error codes and timings only (never keys or dictated text) |
| Keychain, service `TypeLeast.llm-api-key` | the API key per preset and a separate history encryption key |

## Diagnostics

    TYPELEAST_SELFCHECK=1 ~/Applications/TypeLeast.app/Contents/MacOS/TypeLeast

prints which Node.js was found, whether the service is bundled and running, and
its health, then quits. `TYPELEAST_LLMCHECK_URL`, `TYPELEAST_LLMCHECK_MODEL` and
`TYPELEAST_LLMCHECK_KEY` (`@keychain` uses the saved key without printing it) add
a model check.

## Permissions

- Microphone: required.
- Accessibility: for pasting at the caret and for the Fn key. Every rebuild
  changes the ad-hoc signature, so macOS may ask again.
- Nothing else: no screen recording, camera or input monitoring.

## Demo mode

`TYPELEAST_DEMO_WAV=<16 kHz mono PCM16 WAV>` (with `TYPELEAST_DEMO_DELAY`, seconds,
default 4) makes the app feed that file in at real-time pace instead of opening
the microphone, start one dictation by itself into the app in front, and show no
window of its own. `Tools/demo/record-demo.sh` uses it with macOS's synthetic
voice, so the README demo involves nobody's real voice.

## Storage and process safeguards

Builds enable Hardened Runtime with only the microphone entitlement. Before the
local service starts, the app checks its signature and sealed resources. Local
update signing preserves the runtime flags and entitlements. This does not add an
independent update signature or Apple notarization.

A process-owned file lock prevents simultaneous normal instances. An isolated
`TYPELEAST_HOME` test run does not register global hotkeys. Node startup and
version probes filter code-loading and TLS-disable environment variables.

History and retained recordings use AES-GCM with a separate Keychain key. Old
history and retained app temporary WAVs migrate on load. Migration failure keeps
the original data and reports an error; new writes never fall back to plaintext.
A missing key does not cause encrypted history to be overwritten. Resetting the
Keychain can make that history unreadable. Recordings are still plaintext while
recording and during the active request. Known terminal apps receive a single
line without control characters; embedded terminals may not be detected.

For local release builds, `TYPELEAST_BUILD_DIR` selects a separate staging folder
and `TYPELEAST_PACKAGE_CACHE` reuses fixed-version package downloads. The default
paths stay unchanged. Existing validation builds can therefore be kept for review.
