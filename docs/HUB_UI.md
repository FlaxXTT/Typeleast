# Main-window UI

The main window adapts the supplied `Typeless_UI_范本` to native AppKit and SwiftUI.

## Surfaces and controls

- Window: white / `#242121`; sidebar: `#F7F6F5` / `#1D1A1A`.
- Cards: `#F2F1F0` / `#3C3B3B`; text: `#111111` / `#F2F1F0`.
- Primary actions and selection: `#1F5DF2` / `#4F7BFF`.
- Corners are tiered: base controls 8pt, small controls 6pt, cards 12pt, history groups 10pt, Home cards and sidebar 20pt, window panels including Settings 24pt. True pills keep capsule geometry. Page horizontal insets are 24pt, with a 44pt top drag region and 16pt bottom inset.
- The sidebar is 210pt including its 8pt outer inset; its 202pt inner surface has a 20pt corner and 44/12/8pt top/horizontal/bottom padding. Navigation rows are 36pt high with 16pt icons and 14pt text.
- Prompt Medium titles are 48pt on Home, 36pt on other pages, and 24pt for sections. Body, row, explanatory and small-label sizes are 16, 14, 12 and 11pt. Prompt fonts and their OFL licence ship in Resources/Fonts.
- Flat borders separate normal surfaces. Shadows belong to transient notices.
- Control feedback uses 120–200ms easing. Meeting cards do not bounce or acquire decorative blue outlines.

## Navigation and records

### Home insights

The supplied Home screenshot defines the insights area: system bold figures, grey labels,
large white cards with 20-point corners, a soft grey-to-white dot-grid backdrop and a
pill-shaped Share button. Figures use the default system design rather than rounded digits.
The light heatmap colours sampled from the reference are `#F8F8F8` (empty), `#ECF0FE`,
`#C6D2FC`, `#A0B4FB` and `#426AF6`. The screenshot's Display P3 colour space is retained
for its coloured fills and backdrop. Large counts use the reference's K notation.

Four metric cards sit in two columns above the active-day card. Engine status and model
management occupy the top-right column, followed by Quick dictation; Recent is the final
section beneath both columns. The main window is fixed at 1080×750 points. User resizing, zoom and full-screen entry are disabled; scrolling holds content that extends beyond the fixed viewport.

Opening or restoring the hub replays the four metric figures from zero over 250ms. Units and
final number widths are reserved, so counting does not move surrounding content. Active
day and streak figures count up too. Grey day slots are visible at first. Week columns
enter left to right, staggered by 40ms. Each column runs a 300ms scale pulse from 1 to
1.2 and back to 1 while a white cover fades away; all seven cells share the column's
phase. One local elapsed-time animation drives every cell, without per-cell timers.
Reduce Motion displays the final values and grid immediately.
Month arrows navigate actual activity history. No synthetic usage data is added.

The animation is local to numeric text and cell effects, not a timer publishing through
AppModel. Ordinary history/health refreshes do not restart it. Opening the hub starts
Home at its insights; navigation within that opening retains the native scroll offset.
Reduce Motion shows the final figures and cells immediately.

### History and commands

`⌘K` opens one search field for pages, appearance commands and history text. The native
field editor handles text input; arrow keys select results, Return opens them and Escape
closes the panel. Input-method candidate selection takes priority over command navigation.

History retains its header and filters while the list scrolls. Date headings pin at the
top. Groups have 10pt corners at their first/last rows, with square middle rows and no dividers. Rows use 8×12pt insets, a 52pt time column and 14pt text on a 22pt line. Selecting a row opens a trailing detail column when the content area is at least
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
Each window uses two snapshots, cropped into tile faces rather than separate live page hierarchies. Covers live above the SwiftUI hosting hierarchy; the main window and independent Settings window animate together. New-theme capture waits for display frames, and only then compares the effective appearances. Content input
is held while the snapshots are shown. Reduce Motion uses a 180ms crossfade. Changing a
preference without changing the effective light/dark appearance does not animate.

The implementation uses native [Core Animation layers](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CoreAnimationBasics/CoreAnimationBasics.html)
and [perspective transforms](https://developer.apple.com/documentation/quartzcore/calayer/sublayertransform).

The recording overlay uses a fixed transparent 750×500 carrier around its changing capsule. Detailed sizes are in [Window and capsule geometry](WINDOW_AND_CAPSULE_GEOMETRY.md). It keeps its own `VoiceBarPalette`, fixed black-and-white appearance,
configured shortcuts and microphone-driven animation. Main-window theme tokens do not
set its colours.

## Home corrections after 2.1.9

The shared scrolling implementation also covers dialogs and editors. See
[Native scrolling](SCROLLING.md) for display-frame coalescing, lazy lists,
command navigation and meeting bottom-follow behaviour.

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
inside the window corner.


## Settings dialog

Settings opens as an independent 940×652 window with 24pt corners. A 44pt top strip
supports native dragging without covering the close button or scroll content. The 202pt left
classification pane uses 36pt navigation rows; the right pane has independent
scrolling and 36pt horizontal/44pt top insets. Groups use 12pt corners with
16pt internal padding. Regular rows have a 48pt minimum height, 14pt labels and
12pt explanations; switches are 38×22pt. A 24pt close button dismisses the window.
All existing Settings entry points use `AppModel.navigate(to:)` and keep the
underlying Home/History/Meeting page in place.

Category selection never waits for system services. Login-item status and changes,
key-presence metadata, input-device enumeration and permission status run off the
main thread. Models shows a pending saved-key status; General shows a spinner next
to the login-item control while its status loads. These operations do not block
navigation, dragging, closing or scrolling. The Settings scroll surface keeps its
native scrollbar and position memory without the blue top progress strip.

## Loading and window motion

`LoadingMotion.swift` supplies local drawing timelines, separate from app state:

- Skeleton blocks use 10% grey in light mode and 40% grey in dark mode. After a
  500ms initial delay, their highlight travels left to right during the first
  second of each 2s cycle and stays offscreen during the second second.
- Login-item status uses a control-sized skeleton; saved-key status uses a 97pt
  text skeleton. A history retry replaces only the working row's text with a
  full-width, 24pt skeleton until the dictation phase returns to idle.
- Update checks show an 8pt pill track and two travelling blue bars on a 2.1s
  cycle, with the second delayed by 1.15s. Downloads show their actual percentage
  and byte counts. Quiet automatic checks do not open the progress window.
- Model requests, advice and meeting processing use 20pt circular indicators:
  1.4s rotation plus a growing/shrinking arc and dash offset. Determinate circular
  indicators draw a measured foreground ring over a grey full ring.
- Reduce Motion stops all loading loops and makes measured progress updates
  immediate. Completed tasks remove their indicators; the update window releases
  its loading view when hidden.

Settings fades in over 225ms and out over 195ms, changing only window opacity.
It renders content immediately; the fade is not a loading state. Rapid reopening
reverses a pending fade-out. The independent window does not add a modal mask.
No account, organization, embedded browser or cloud-sync module is simulated.
