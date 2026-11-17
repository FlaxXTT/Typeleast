# Passive selection translation

The offer is created only after a mouse drag of at least 5pt or a repeated click,
with no keyboard activity in the preceding 250ms. After a 150ms selection-settling
delay, a utility queue reads the original process's focused element and selected
text. The application and focused-element AX messaging timeouts are 80ms each.
Password fields and blocked applications remain excluded.

Passive offers do not set `AXManualAccessibility` or `AXEnhancedUserInterface`.
This avoids forcing a full accessibility tree in an Electron application such as
Codex while the user is typing. Only an already exposed, confirmed selection can
produce an offer; unavailable selection data produces no popup. Explicit shortcut
translation keeps its existing field-capture path.

Every key invalidates pending offer work. With no active offer, this performs no
window creation, ordering or content-view teardown. Reads are serialized with at
most one queued successor; cancellation clears that successor and discards any
in-flight result. Returning a result cannot recreate the offer after typing or
switching applications. Clicking the offer rechecks the selection on the same
background queue before translation starts.

`SelectionPanel.hide()` uses only an existing panel. It orders out a visible panel
once and releases its content, without initializing the lazy window just to hide
it. The completed translation stays until closed and never becomes key. Waiting
uses the shared lightweight circular indicator. The offer is a 24×24pt transparent
button: a filled, irregular hand-drawn circle and two pen lines, without material,
card border or window shadow. The full square responds to clicks, including the
circle center and gaps. Hover and press use a 120ms opacity/scale response with no
repeating drawing clock. Text is sent only after an explicit click and is not inserted or
saved by this feature.
