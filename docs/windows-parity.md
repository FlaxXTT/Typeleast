# Windows parity: evidence and delivery

Baseline: `e2fccb98aee1bfa0ed4c0f5747bc13cacde8e594`, inspected on 2026-10-20 UTC.
The current Windows machine has no TypeLeast installation (confirmed by the maintainer).
The reported older Windows 1.15.0 is not an inspected installation. Source version 1.16.0
does not imply a Windows release: v1.16.0 has Mac artifacts only. PR #20 remains open.
Mac 1.16.0 build 7 installation is handoff evidence, not a local execution result.

## Matrix

Every item below requires runtime acceptance before being called aligned. Source presence
and compilation alone are insufficient. Evidence refers to the baseline sources, not screenshots.

| Mac behavior/evidence | Windows baseline and difference | Adaptation / modification boundary | Acceptance | Risk / current status |
|---|---|---|---|---|
| HubWindow: fixed sidebar, bottom settings, activation refresh, saved frame | MainWindow reuses pages but settings at top; no frame restore | Native WPF navigation / window bounds | Tray page opening, hide/quit, no service reload, multiple monitors | Partial; native interaction unverified |
| Theme: semantic light/dark colors and capsules | Theme has fixed light brushes | Dynamic resource palette, DIP layout | Both themes/languages, minimum size and scaling | Partial |
| HomePage: greeting, keycaps, guidance, four metrics, recent entries, engine | Basic hero, checklist, summary, heatmap | Shared history projections, responsive cards | Add/delete reflected in home and history | Partial; retained history is not lifetime totals |
| ActivityCard: responsive weeks, months, streaks | ActivityView fixed 26 weeks | Width-based weeks and wrapping summaries | Cross-year/date boundaries, tooltips | Partial |
| HistoryPage: search, filters, day groups, retention | HistoryPage copies/deletes, caps rendering | Shared repository / filtered projections | Same-count edits, filters, storage failures | Partial |
| HistoryStore/dictation: retained audio and original retry options | HistoryEntry lacks retry metadata and audio | Optional metadata, protected 24h recordings | Retry translation preserves target, expired audio disabled | Missing |
| DictionaryPage: source, search, edit, CSV | String chips with add/remove | Structured entries, legacy migration, preview import | Duplicates, invalid rows, persistence/sync | Partial |
| HubSettings: ordered groups, explicit behavior | SettingsPage incomplete groups | Commands and responsive settings rows | Save failure, restart semantics, compatibility | Partial |
| LLMSettings: draft tests and saved credentials | DraftRoute/test vs ActiveRoute/dictation | Separate connected/saved states | Fake store save failure and route consistency | Source exists; runtime unverified |
| PromptifySettings/languages: independent fields and guarded replacement | Modes/languages/panel exist | Preserve prompt field meaning and service contract | Append/override/reset; independent language fields | Partial |
| Recorder/onboarding: explicit mic testing and mute recovery | Capture/device choice exist | Windows microphone status, explicit test, session audio restore | No capture on page open; unplug/cancel/exit | Partial/platform adaptation |
| Inserter/PreviewPanel: paste/copy/preview and restoration | Automatic text paste and window comparison | Policy-based insertion and field identity | Clipboard races, focus changes, terminal/elevated app | Partial |
| IdleBar/Onboarding: compact entry and preparation steps | No complete equivalents | Shared coordinator entry, Windows steps | Tray restoration, no duplicate recording | Missing |
| RecordingBar/BetaPanel: nonactivating states and questions | Both exist; thinking cancel does nothing | Cooperative cancellation and target preservation | Answer/skip/cancel/expire/change mode | Partial |
| AppDelegate/AppModel/AppActions: distinct responsibilities | AppHost has basic three-state coordination | Incremental testable operation state / commands | Late result, rapid entry, exit/restart races | Partial |
| Shared service: classification and deterministic fallback | 12s/800 tokens polish; 20s ping | Allowlisted diagnostics, no blind budget increase | Synthetic timeout/length/format/validation/auth/network | Source exists; actual DeepSeek unverified |
| Service/model managers: serialized lifecycle | Limited backoff resets on each successful start | Stable-window restart policy and serialized start | Crash loops, stale port, switch/download failure | Partial |
| Loopback/auth/bounds/redaction and protected history | Shared checks/DPAPI exist; Unix modes do not prove ACL | Current-user Windows ACL and native tests | ACL, DPAPI, corrupt migration, redirect/auth/body limits | Runtime evidence incomplete |
| Updater/package scripts: verified artifacts | No cross-platform private-repo updater | Explicit version/download entry; isolated package QA | Upgrade/uninstall boundary and process cleanup | Evidence insufficient |
| Independent service identity / publisher signature | Neither platform has independent trusted identity | Separate security proposal; no new protocol in parity work | Threat model, trust root, rotation and recovery | Known gaps, not fixed |

## Delivery and privacy

Five stacked PRs: diagnostics; lifecycle/security; data/features; UI; acceptance/packages.
Do not merge or publish. Do not change the historical API prefix, Mac bundle identifier,
upstream prompt text or third-party attribution. Keep shared changes additive and tested.
Use repository-local maintainer identity and UTC commit timestamps. No AI attribution.

Only synthetic text/audio, fake credentials, isolated state and provider substitutes are
allowed in verification. Do not inspect real credential entries or private history/audio.
Diagnostics accept only fixed operation/stage/reason fields and bounded numeric metrics.
Do not forward provider messages, response text, URLs or exception bodies to diagnostic output.

## Stage 1 verification

Environment: portable .NET SDK 8.0.426 downloaded from builds.dotnet.microsoft.com into
the task tooling directory; Node v24.13.0; dependencies installed with `npm ci --ignore-scripts`.
No global SDK installation or installed TypeLeast replacement.

- Baseline before dependency restore: 196 passed, 2 failed (missing opencc-js), 1 skipped.
- After restore and six synthetic regression cases: `npm test`: 204 passed, 0 failed,
  1 skipped (real recognition unavailable without model files).
- Synthetic cases prove a successful ping can coexist with dictation timeout, max tokens,
  invalid format, invented content, authentication or network failures. They do not prove
  the cause of a real DeepSeek failure. Default budgets and validators remain unchanged.
- Native Windows Core Release: 173 passed, 0 failed, including real current-user DPAPI
  round-trip, corruption rejection and original-data retention (not a cross-user proof).
- WPF Release build succeeded: 0 errors, existing WFAC010 DPI warning retained for UI QA.
- Hosted CI has not been executed by this work and is not marked passed.

## Required final acceptance

## Stage 2 verification (2026-10-20 UTC)

Implemented processing cancellation and immutable per-recording request options, cancellation
propagation to HTTP, late-completion isolation, and no transport replay of dictation/Beta POSTs.
The recording overlay keeps Cancel available during processing. Quit/restart cancels work.
Service starts are serialized, pending restarts are cancelled on stop, stale ports invalidated,
and restart attempts reset only after 60 seconds uptime. Arbitrary child stderr is not retained.
Dedicated state directories reject links/unrelated files and receive current-user ACLs before
service startup; existing immediate state files inherit that ACL. This is access control,
not proof of service identity or protection against the logged-in user.

Native Windows Core: 481 passed, 0 failed, including 100 entry/cancellation/late-result rounds,
restart exhaustion/stability, ACL inheritance and current-user-only grants, plus native DPAPI.
WPF Release compiles, 0 errors, existing WFAC010 warning. Actual mic, overlay focus, crash-loop
subprocesses, cross-user ACL/DPAPI and sleep/wake interactions remain unverified at this stage.

## Stage 3 verification (2026-10-20 UTC)

Added structured dictionary entries with legacy source migration, bounded CSV preview,
retention policies, optional retry metadata and DPAPI-protected 24-hour retry audio.
History retries preserve language/mode/translation/variants and copy the result, matching
Mac retry behavior. Prompt Beta cannot be reconstructed from one recording and is disabled
for this action. Never-save keeps paste-last in process memory only. Corrupt settings cannot
be overwritten silently. Dictionary entries respect the shared service's 120-character limit.

Insertion supports automatic paste, copy and interactive preview, with field identity checks
and clipboard sequence-based restoration. Unknown target identity safely falls back to copy.
Numbered-list HTML preserves a plain-text fallback; terminals remain plain text.
Optional context uses bounded TextPattern selections, excludes password/known credential apps,
and is redacted by the existing shared service. Optional learning observes only a matching field
containing exactly the insertion, for at most 30 seconds, stops on focus change, and sends one
bounded correction through /learn. It does not capture keyboard input. These checks are
conservative, not a claim to identify all sensitive applications or secrets.

Native Core: 508 passed, 0 failed. New scenarios include retention, never-save, retry metadata,
legacy dictionary migration, CSV duplicates/quotes/invalid rows, corrupt settings preservation,
sealed audio round-trip/expiry/path traversal, HTML escaping and bounded edit extraction.
WPF compiles. Native field providers, clipboard/preview interactions and retained audio with
real microphone input still require UI/runtime QA; cross-user proof remains pending.

## Required final acceptance (pending)

## Stage 4 implementation and preliminary verification (2026-10-20 UTC)

The WPF UI now uses semantic light/dark/system palettes, bottom settings navigation,
window-bound persistence, keycaps, four responsive statistics, recent history, engine status
and a responsive month-labelled heatmap. History supports retention, search, filters, date
groups and retry. Dictionary supports search, sources, edits and previewed CSV imports.
Settings follow the requested group order and include insertion policies, controlled context/
learning, audio testing, session muting, appearance, taskbar/background behavior, idle bar,
privacy, Windows conditions and explicit release checking/download links. Added onboarding
and nonactivating idle entry; active recording/Beta remain coordinated by AppHost.

Microphone tests start only on explicit click, run for at most 15 seconds and do not upload,
recognize or retain their audio. Audio capture is capped and late device callbacks ignored.
Device errors cancel the operation. Existing playback sessions are restored on stop/cancel;
new playback sessions are not claimed muted. Draft model routes no longer mutate effective
settings before save; failed settings writes restore the last saved values and show an error.
Credential access is injectable so verification uses a fake store, never real credential reads.

Preliminary verification: native Core 508/0; WPF build passed with existing WFAC010.
Offscreen UI: 50 checks passed and 136 renders generated (two languages, two palettes,
820/940 DIP content, 100/125/150/200% render DPI plus settings bottom views). Selected
images were visually inspected. Render DPI does not prove actual OS scaling or physical Tab.
These checks found and fixed frozen palette brushes and low-contrast native combo templates.
Native UI: 18 passed / 1 failed. Processing/Beta/idle overlays preserved the observed foreground,
preview cancellation, native popup, keyboard traversal, service-gated onboarding and HTTP retry
cancellation were exercised. Windows refused foreground ownership of the fixture; therefore
target-field foreground integration is explicitly not accepted. No real clipboard payload was
read or changed by those checks. Tests use fake credentials and synthetic state/audio only.

Default SenseVoice files were downloaded into the task's isolated model directory and checked
by the existing model verifier. Thirty SAPI-synthesized speech flows passed through real
recognition and deterministic cleanup / fake provider / no-key fallback, alternating en/auto.
This is short-sample execution, not accuracy or microphone-quality evidence. With these models,
the service suite passed 205/0 with zero skips. Other real recognizers remain pending.

## Final acceptance (pending)

Test all pages, overlays, preview, onboarding, menu/tray in Chinese/English and light/dark,
minimum window and 100/125/150/200% scaling. Check focus, Tab, scrolling, long text,
disabled states and recovery. Use 100 cancellation/entry races, 30 public audio flows,
and a two-hour observation; this is not a claim of long-term stability.
Cross-user DPAPI, alternate model recognition, installer upgrade/uninstall and Mac runtime
need explicit execution evidence or must remain unverified. Independent service identity,
independent update signatures and compromise of the current user session remain known risks.
