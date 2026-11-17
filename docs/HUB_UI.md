# Main-window UI

The main window adapts the supplied `Typeless_UI_范本` to native AppKit and SwiftUI.

## Surfaces and controls

- Window: white / `#242121`; sidebar: `#F7F6F5` / `#1D1A1A`.
- Cards: `#F2F1F0` / `#3C3B3B`; text: `#111111` / `#F2F1F0`.
- Primary actions and selection: `#1F5DF2` / `#4F7BFF`.
- Controls use 8-point corners; cards use 12-point corners. Page insets are 32 points.
- Flat borders separate normal surfaces. Shadows belong to transient notices.
- Control feedback uses 120–200ms easing. Meeting cards do not bounce or acquire decorative blue outlines.

## Navigation and records

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

Manual appearance changes reveal the new theme through a 320ms expanding circle. Only a
temporary image of the old window is used; no second live page hierarchy is created.
Reduce Motion switches appearance immediately.

The recording overlay keeps its own `VoiceBarPalette`, fixed black-and-white appearance,
configured shortcuts and microphone-driven animation. Main-window theme tokens do not
set its colours.
