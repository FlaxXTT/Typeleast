# Window and capsule geometry

## Fixed windows

Dimensions are native points, corresponding to CSS pixels. Owned frame sizes are fixed;
the user cannot drag a resize edge or zoom the main window.

| Window | Size |
| --- | --- |
| Main | 1080 × 750 |
| Transparent recording carrier | 750 × 500 |
| First-run setup | 940 × 610 |
| Prompt questions, recognition/quantity review, update progress and result/advice panels | 350 × 500 |

The project has no separate account-login flow; its first-run setup uses the supplied
login-window footprint. The reference's 988×685 lower bound is not an interactive resize
range: the main window's minimum and maximum frame sizes are both 1080×750. A separate
frame-save key prevents restoration of an older resizable layout.

## Circular corners

Controls, fields, cards, activity cells and owned popup surfaces use a 99-point radius.
Native layers clamp it to `min(99, width / 2, height / 2)`. SwiftUI uses circular geometry,
not the continuous/squircle style. Larger cards and editors reserve content insets so text
stays within the curve. Owned windows have clear backgrounds and rounded content layers;
their native traffic lights sit inside the larger corner. Brand artwork and the mosaic's
image fragments retain their own drawing geometry.

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
owner. It retains both 26-point discs: a grey cancel button and white finish button with
a black check. Compact modes are explicit `RecordingBarMode` options. The existing final
15-second countdown adds exactly 40 points to the recording width.

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
