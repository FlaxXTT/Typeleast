# TypeLeast — macOS app

A menu-bar app (AppKit + SwiftUI, system frameworks only):
press Fn (or ⌥Space), speak, press again, and the cleaned-up text is pasted at the
caret. Recognition and cleanup are done by the TypeLeast local service
(`../../service`), which this app starts, watches and stops by itself.

The bundle id is `com.dsh.voice` for continuity with earlier builds (settings,
and history carry over).

## Requirements

- macOS 14 or later on Apple silicon. Intel Macs are no longer built; the last
  Intel release is 1.17.1.
- To build: Xcode with its Metal Toolchain component and Node.js 22+
  (`npm` installs the service's dependencies; a build from source also runs the
  service with this Node.js). Install the Apple component with
  `xcodebuild -downloadComponent MetalToolchain`. If `xcrun metal --version`
  cannot find it, obtain the toolchain identifier from
  `xcodebuild -showComponent MetalToolchain` and set `TOOLCHAINS` to that
  identifier for the build command.

## Build, test, package

    ./test.sh                # unit and contract checks, no running service needed
    ./make-signing-cert.sh   # once per Mac: a local signing certificate, so rebuilds keep their permissions
    ./build.sh               # compile, bundle the service, sign, install ~/Applications/TypeLeast.app, relaunch
    ./build.sh --no-install  # build only (build/dist.noindex/TypeLeast.app)
    ./package.sh arm64       # self-contained release for Apple silicon (.dmg + .zip, with Node.js inside)
    ./Tools/render.sh [dir]  # offscreen PNGs of every page, with sample data
    ./Tools/demo/record-demo.sh <dir>  # the README demo GIF (synthetic voice, no microphone; see the script)


## Meetings

The Meetings page records the microphone or imports a file (anything AVFoundation opens), uploads
it to the service as a WAV and polls one background job (`POST /meetings`, `GET /meetings/status`,
`POST /meetings/cancel`). The job runs MOSS-Transcribe-Diarize in one pass and returns turns with
speaker labels and times.

The limit is 10 minutes (`MAX_MEETING_SECONDS`, `MeetingLimits.maxSeconds`), the longest length
measured to finish. On an M5 Pro with made-up four-voice audio: 5 min took 47 s (RTF 0.16), 10 min
took 271 s (RTF 0.45), and 20 min had not finished when stopped at 45 min. Longer meetings need
windows and speaker linking across them, which do not exist yet, because labels only hold within
one engine run. A 90-minute recording is refused.

`./Tools/meeting-check.sh` runs this flow on a file through a built app's service and engine,
without clicks and without touching the installed app.

## How it finds the local service

- The service and its non-ONNX Node dependencies are copied into
  `TypeLeast.app/Contents/Resources/service`. The MLX speech worker and its
  Metal resources are bundled separately under `service/native/`.
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
| `~/Library/Application Support/TypeLeast/` | the service's token, runtime file, history, `config.json` |
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

### Update identity and Keychain prompts

`package.sh` defaults to ad-hoc signing. For a release with a stable certificate, set
`TYPELEAST_SIGN_IDENTITY` to its installed signing identity; the final package and both
native workers retain that certificate and receive a secure timestamp. Certificate import
and Apple notarization remain separate publisher setup steps. Do not commit private keys.

When the installed app and the downloaded update have the same certificate-backed
designated requirement, the updater verifies the update's signature, nested code and
resources against that requirement and installs it without accessing a local signing key.
Other updates retain the existing local-signing path and refuse to replace an existing
certificate identity with a different one. Already saved API keys and history keys stay in
the Keychain; this path does not export or reset them or broaden their access controls.

This avoids update-induced signing prompts for releases that preserve the trusted identity.
It cannot promise that macOS never requests authorization: a locked/reset Keychain, an
ad-hoc installation moving to its first certificate identity, or a user changing access
permissions can still require it. Stable certificate configuration is required before the
publisher workflow can run. Directly built ad-hoc packages do not meet that condition.

The manual `release.yml` workflow now requires repository secrets
`MACOS_SIGNING_CERTIFICATE_BASE64` (a persistent PKCS#12 identity and certificate chain,
encoded as base64) and `MACOS_SIGNING_CERTIFICATE_PASSWORD`. It imports them into a temporary
CI Keychain and stops publishing if they are missing or invalid; it never generates a new
release identity or falls back to ad-hoc signing. A publisher-controlled self-signed CA can
also be used without Developer ID: its root is trusted only on the disposable CI build
machine and removed afterward. No publisher root is installed on end users' Macs. This
does not provide Apple notarization or bypass the first installation's Gatekeeper checks.
Do not replace these secrets with freshly generated identities for each release.

An owner with GitHub Actions Secrets permissions can create the fixed self-signed identity
and configure both secrets once, without using the Mac login Keychain:

```bash
bash apps/macos/scripts/configure-publisher-signing.sh FlaxXTT/Typeleast "$HOME/.local/share/typeleast-publisher-signing"
```

The command requires `gh`, `openssl` and `git`, refuses to overwrite existing signing
secrets, and keeps an encrypted root key and certificate backup outside the repository.
It does not publish a release or print private values. Preserve that directory securely;
leaf renewal should keep the same root anchor. If only the first secret uploads, use the
same local identity to configure the missing password secret rather than generating a new
identity. The current connector may lack Secrets access even when it can push code.

An existing ad-hoc/local-signed installation may still need a one-time authorization when
moving to a publisher-signed baseline. An older updater re-signs downloaded apps, so install
the first publisher-signed baseline directly; subsequent matching-identity updates use the
signature-preserving path. The new code cannot prevent an old updater's password request
before it has itself been replaced.

The isolated macOS CI job runs `Tests/update-identity.sh` with a disposable certificate and Keychain.
It checks silent credential access after a binary update with the same identity and
rejects a changed identity or changed sealed resource. It neither reads user credentials
nor enables authentication UI in the probe applications.
Signing temporarily trusts only the disposable certificate on the CI build machine; that
positive trust is cleared and ordinary certificate evaluation confirms the root is untrusted
before the credential-access probes; temporary private material is cleaned
up afterward. This integration check is skipped by default in `test.sh`; opt in on an
isolated CI machine with `TYPELEAST_TEST_UPDATE_IDENTITY=1`.

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
