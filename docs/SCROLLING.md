# Native scrolling across the Mac app

Every vertical SwiftUI scroll surface uses `HubScrollView`: Home, all Settings
categories, History and its detail panel, meeting transcripts, command search,
onboarding, prompt questions, recognition/quantity review, translation results,
model recommendations, and update progress. Native review editors use the same
`NativeScrollAppearance`; SwiftUI text editors keep their system indicators and
native hover feedback.

## Input and rendering

Wheel input, trackpad inertia, scroller dragging, keyboard scrolling and elastic
scrolling stay with AppKit/SwiftUI. The wrapper does not override wheel events,
apply a global scrolling animation, or publish offsets through `AppModel`.
The theme-transition overlay still blocks interaction during its own transition.

History and meeting results retain their lazy stacks; command results also use a
lazy stack. SwiftUI creates and prefetches nearby rows as needed, rather than
mounting an entire long list. There is no browser-specific 40px row estimate or
fixed 20-row overscan in the Mac implementation. Existing selectable history
text caches its measured size until its width or content changes.

Settings and other short forms retain their normal stacks, so scrolling a card
out of view does not discard unsaved editor state.

## Passive scroll work

Scroll notifications only request one display callback. A view-bound
`CADisplayLink` coalesces updates to the display cadence; it pauses after the
pending frame and is invalidated when detached. Document height is cached and
updated on document-frame or viewport-size changes, not measured in the scroll
notification. Progress and bottom fade use retained layers: offset changes update
only the progress layer's width or fade visibility, without invalidating the full
viewport overlay or constructing a new gradient. The back-to-top button changes
visibility only when its threshold is crossed. Home retains its dot geometry and
rebuilds it only when viewport dimensions change.

Plain popups with no chrome, position memory or bottom following install no
scroll observers or display link at all. Position memory remains scoped to page
keys. Scrollbars use the native overlay style, without changing content width
when they appear.

`HoverScroller` changes only `drawKnob` and `drawKnobSlot`, preserving AppKit's
separate overlay fade handling and native drag action. Hover/drag raises the thumb
opacity from 22% to 46% and width from 4pt to 6pt; leaving restores its quiet state.
Native appearance properties are assigned only when they change.

Settings hides the blue top progress strip. Its native scrollbar, position memory,
bottom fade and back-to-top button remain available.

## Navigation without fighting the reader

Command search caches its results until the query, history or command inputs
change. Hover changes the selected row without requesting a scroll. Arrow-key
navigation requests native positioning of the selected result; a new query
returns to the first result.

Live meeting text follows appended content only while the reader remains near
the bottom. Scrolling up leaves the viewport in place. Reading back is not
interrupted by a `scrollTo` on every transcript update, and live scroll gestures
are not repositioned by the follow behaviour.

## Sources

- [Apple: LazyVStack](https://developer.apple.com/documentation/swiftui/lazyvstack)
- [Apple: Dive into lazy stacks and scrolling with SwiftUI](https://developer.apple.com/videos/play/wwdc2026/321/)
- [Apple: What's new in AppKit — view-bound display links](https://developer.apple.com/videos/play/wwdc2023/10054/)
