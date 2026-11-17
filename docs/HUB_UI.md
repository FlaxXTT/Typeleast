# Main-window UI

The main window adapts the supplied `Typeless_UI_范本` to native AppKit and SwiftUI.

## Surfaces and controls

- Window: white / `#242121`; sidebar: `#F7F6F5` / `#1D1A1A`.
- Cards: `#F2F1F0` / `#3C3B3B`; text: `#111111` / `#F2F1F0`.
- Primary actions and selection: `#1F5DF2` / `#4F7BFF`.
- Rounded UI surfaces use a 99-point circular radius, clamped to half the width/height. Page insets are 32 points. Controls, cards, fields, activity cells and owned popups share this rule; larger cards reserve more space for their content.
- Flat borders separate normal surfaces. Shadows belong to transient notices.
- Control feedback uses 120–200ms easing. Meeting cards do not bounce or acquire decorative blue outlines.

## Navigation and records

### Home insights

The supplied Home screenshot defines the insights area: system bold figures, grey labels,
large white cards with circular 99-point corners, a soft grey-to-white dot-grid backdrop and a
pill-shaped Share button. Figures use the default system design rather than rounded digits.
The light heatmap colours sampled from the reference are `#F8F8F8` (empty), `#ECF0FE`,
`#C6D2FC`, `#A0B4FB` and `#426AF6`. The screenshot's Display P3 colour space is retained
for its coloured fills and backdrop. Large counts use the reference's K notation.

Four metric cards sit in two columns above the active-day card. Engine status and model
management occupy the top-right column, followed by Quick dictation; Recent is the final
section beneath both columns. The main window is fixed at 1080×750 points. User resizing, zoom and full-screen entry are disabled; scrolling holds content that extends beyond the fixed viewport.

Opening or restoring the hub replays the figures from zero over 1.2 seconds. Units and
final number widths are reserved, so counting does not move surrounding content. Active
day and streak figures count up too. All empty slots are visible at first; only the real
active blue fills are revealed from left to right over 1.4 seconds after a 150ms lead-in.
Month arrows navigate actual activity history. No synthetic usage data is added.

The animation is local to numeric text and cell masks, not a timer publishing through
AppModel. Ordinary history/health refreshes do not restart it. Opening the hub starts
Home at its insights; navigation within that opening retains the native scroll offset.
Reduce Motion shows the final figures and cells immediately.

### History and commands

`⌘K` opens one search field for pages, appearance commands and history text. The native
field editor handles text input; arrow keys select results, Return opens them and Escape
closes the panel. Input-method candidate selection takes priority over command navigation.

History retains its header and filters while the list scrolls. Date headings pin at the
top. Selecting a row opens a trailing detail column when the content area is at least
760 points wide; narrower windows use a native detail sheet. Copies confirm with a check.

Single-record deletion removes the row immediately and provides a three-second Undo
notice. Up to three notices are visible. Audio belonging to a pending deletion is removed
when its notice expires or closes. Undo restores the row at its timestamp position, subject
to the user's current retention setting. Clearing history and quitting finish pending deletions.

## Scrolling and appearance

`HubScrollView` keeps native wheel and trackpad scrolling. Native clip-view observations
remember offsets by page or settings category and draw a two-point progress indicator,
bottom fade and Back to top control after 360 points. Offset changes do not publish into
the SwiftUI page tree.

Light/dark appearance changes use a 3D mosaic flip. The grid adapts its rows and columns
to the window aspect ratio, with 96–144 near-square tiles and 2-point gaps. Neighbouring
tiles alternate X/Y rotation axes. The old-theme snapshot is the front face and the
new-theme snapshot is the back face; hidden backfaces keep text upright. The backs are
darkened by 8% and have a one-physical-pixel highlight. Perspective is 900 points.

Equal row+column diagonals start together, from top-left to bottom-right. A tile rotates
180 degrees over 420ms; the diagonal wave spans 320ms. After a 40ms settling interval,
the mosaic fades out over 120ms, for a total of 900ms. Only transforms and opacity animate.
The tiles share two snapshots rather than separate live page hierarchies. Content input
is held while the snapshots are shown. Reduce Motion uses a 180ms crossfade. Changing a
preference without changing the effective light/dark appearance does not animate.

The implementation uses native [Core Animation layers](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CoreAnimationBasics/CoreAnimationBasics.html)
and [perspective transforms](https://developer.apple.com/documentation/quartzcore/calayer/sublayertransform).

The recording overlay uses a fixed transparent 750×500 carrier around its changing capsule. Detailed sizes are in [Window and capsule geometry](WINDOW_AND_CAPSULE_GEOMETRY.md). It keeps its own `VoiceBarPalette`, fixed black-and-white appearance,
configured shortcuts and microphone-driven animation. Main-window theme tokens do not
set its colours.

## Home corrections after 2.1.9

Home totals now come from `ActivityLog` rather than retained transcript history.
Each successful new dictation records numeric word counts, the recording duration,
and estimated typing-time savings alongside its activity day. No transcript is
added to the activity log. History retention and single-record deletion do not
change these cumulative totals; the existing explicit clear-all action still
clears activity and statistics together.

Old activity JSON retains its word counts. Its new duration fields are optional,
so missing recording times are not invented. Before the first timed dictation,
time and speed cards show a dash. Afterwards they use only measured dictations;
the speed numerator excludes the old untimed word counts. An information hint
explains partial time coverage. Totals are cached until activity changes.

The sidebar search control is 40 points high. The native share button centres
its symbol and localized title together. The main window reapplies its native
traffic-light placement after AppKit's presentation layout, keeping the buttons
inside the requested 99-point corner.

