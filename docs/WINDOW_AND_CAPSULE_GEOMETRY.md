# Window and capsule geometry

## Fixed windows

Dimensions are native points, corresponding to CSS pixels. Owned frame sizes are fixed;
the user cannot drag a resize edge or zoom the main window.

| Window | Size |
| --- | --- |
| Main | 1080 × 750 |
| Transparent recording carrier | 750 × 500 |
| First-run setup | 940 × 610 |
| Settings dialog | 940 × 652 |
| Prompt questions, recognition/quantity review, update progress and result/advice panels | 350 × 500 |

The project has no separate account-login flow; its first-run setup uses the supplied
login-window footprint. The reference's 988×685 lower bound is not an interactive resize
range: the main window's minimum and maximum frame sizes are both 1080×750. A separate
frame-save key prevents restoration of an older resizable layout.

## Surface geometry

The interface uses tiered circular corners: 8pt base controls, 6pt small controls,
12pt cards, 10pt history groups, 20pt Home cards and sidebar, 16pt generic panels,
and 12pt Settings sheets. Only actual pills, switches and the voice bar use
capsule geometry. Native text editors use an 8pt clip. Main-window traffic lights
sit at the regular 14pt inset; panel rounding does not affect brand artwork.

The main sidebar is 210pt including its 8pt left inset; its inner surface is 202pt
wide. The main content has 24pt horizontal, 44pt top and 16pt bottom insets.
Settings has a 202pt category pane and its own scrollable content column.

## Visible capsule

| State | Size |
| --- | --- |
| Idle | 40 × 6 |
| Hover | 70 × 34 |
| Opening microphone | 54 × 12 |
| Compact recording | 70 × 34 |
| Compact hardware dictation | 82 × 34 |
| Hands-free recording | 116 × 34 |
| Error | 70 × 34 |

The app's press-once/press-again workflow uses hands-free recording, as confirmed by the
owner. It retains both 24-point discs: a grey cancel button and white finish button with
a black check. Compact modes are explicit `RecordingBarMode` options. The existing final
15-second countdown adds exactly 40 points to the recording width.
Supplying `IdleBar.countdown` also gives the hover capsule a 40-point timer slot (110×34).

The waveform always has 10 two-point columns, two-point gaps and a 38×24 drawing area.
Heights are limited to 2–18 points. Real audio, visual gating and per-column smoothing
continue to drive the waveform. Mode text and detailed errors sit above the capsule so
they cannot enlarge or crowd its fixed state dimensions. Opening the microphone shows
a sheen instead of the full-size controls.

The capsule is pure black, with a one-point white border at 32% opacity. Startup uses
50% black. Idle uses #808080 at 50% overall opacity. Its two shadow layers correspond to
the reference's soft near shadow and 25-point downward shadow. The transparent carrier
leaves room below the visible capsule for these shadows.

Geometry follows cubic-bezier(.05,.6,.4,.95) over 200ms; appearance/disappearance uses a
500ms ease-in-out opacity transition. Reduce Motion applies geometry immediately. The
existing recording-to-transcription handoff and one-second cancellation-toast fade remain.

The 750×500 carrier does not take focus or consume clicks outside the circular capsule.
Pointer monitoring is installed only while the capsule has active controls and is removed
when hidden. Passive mode labels are click-through. Microphone reminders anchor above the
visible capsule/mode card, not above the outer 500-point window.
