# Typeless — Feature & UX Specification (reverse-spec to imitate)

**Product identity (verified):** "Typeless" (also styled *Typeless: AI Voice Keyboard*), an AI voice-dictation
product by **Simply CA LLC**, Palo Alto, CA (founder/CEO Huang Song, Stanford alumni). Authoritative site:
<https://www.typeless.com>. Not "Typless" (a separate Finnish OCR/invoice-AI brand). Help centre:
<https://www.typeless.com/help>. Trust centre: <https://trust.typeless.com>.
Platforms: macOS (Apple Silicon + Intel), Windows, Linux, iOS, Android.
Sources checked: 2026-10-16. All quoted text below is taken verbatim from those pages.

```
EVIDENCE KEY
[P]  Primary — typeless.com / its help centre / its legal pages (vendor's own words)
[S]  Secondary — third-party reviews, comparisons, reverse-engineering reports, app-store reviews
[I]  Inference — my own reading of the evidence; not stated by the vendor
```

---

## 1. Activation UX

### 1.1 Verified behaviour [P]
Three separate, independently bound actions, each with its own global shortcut. Defaults:

| Action | macOS default | Windows default |
|---|---|---|
| **Dictate** | `Fn` | `Right Alt` |
| **Translate** | `Fn` + `Left Shift` | `Right Alt` + `Right Shift` |
| **Ask anything** | `Fn` + `Space` | `Right Alt` + `Space` |

- **Dictate is press-to-toggle, not hold-to-talk.** Official flow: "Press the keyboard shortcut for Dictate
  **once** … start speaking naturally. Press the keyboard shortcut **again** when you are done." [P] A
  third-party macOS integration PR states it flatly: "Typeless (v2.x on macOS) uses **tap-to-toggle**
  dictation: tap Fn once to start, tap again to stop." [S]
- **Terminating a session always uses the *main* shortcut.** Translate and Ask anything are *started* by
  their own shortcut but *stopped* by the main `Fn` shortcut. [P]
- **Shortcuts are fully remappable** per action, and you can **add extra bindings**: Settings →
  *Keyboard shortcuts* → *Add another* beside Dictate / Translate / Ask anything → press the key combo on the
  external keyboard. Individual extra bindings can be removed. [P] (This is the documented mechanism for
  "another keyboard has no Fn key".)
- **No documented per-app shortcut.** The only per-app behaviour is automatic **tone/style** selection. [P]
- **No documented hold-to-talk, double-tap, or hands-free-lock mode.** [P] One secondary review claims
  "I use the default press-and-hold" [S]; the v0.9.0 release note says "**Hold** your Hotkey (e.g., Fn)" [P].
  I read both as loose wording for "press the hotkey" — every step-by-step procedure on the site says tap
  once to start / tap again to stop. → [I] Treat toggle as the required semantics; treat a true
  hold-to-talk binding as competitor-parity, not a Typeless behaviour.
- **Feedback at session boundaries:** an **interaction sound** plays on start and stop (toggleable), and a
  **Voice bar** appears on screen while listening. [P]
- **9-minute hard cap per dictation.** At 8:00 a 60-second countdown appears on the Voice bar; at 9:00 the
  session ends and what was said so far is auto-saved to History. [P]
- **Mic test / input selection:** Settings → Audio → Microphone (`Auto-detect` or a named device); live blue
  level bars confirm capture. [P]
- **Audio behaviour options:** *Interaction sounds* on/off; *Mute when dictating* (duck other audio) on/off;
  *Launch app at login*; *Show app in dock*; Light/Dark/System appearance. [P]

### 1.2 Mobiles
iOS/Android are **keyboard extensions**, not hotkey apps: tap the Speak button on the Typeless keyboard to
start, tap again to stop. Translate is entered by **press-and-hold** on Speak then **swipe up** to pick a
target language. [P] (Android's bubble model in the competitor set uses tap-to-start / tap-to-check, so
expect platform-specific divergence.)

## 2. Text delivery (insertion)

- **The vendor describes it as a paste.** Installation guide: "Enable **Accessibility** so Typeless can
  **paste** text into any text field … Click Allow to let Typeless **insert** your spoken words into the
  active text field." The FAQ repeats: Accessibility "lets Typeless insert text directly into wherever your
  cursor is", and "also lets you trigger dictation with your Function (Fn) key". [P] → [I] Clipboard-write +
  synthetic ⌘V via Accessibility, with the same Accessibility grant also carrying the Fn event tap. A
  separate reverse-engineering report lists **clipboard read/write** access explicitly. [S]
- **Paste is corroborated by an independent, non-marketing artefact.** A developer building a TUI bridge
  documents that Typeless emits text **containing embedded newlines**, and that desktop terminals (iTerm)
  receive it as *pasted* content — the newlines do not fire per-line Enters — whereas mobile SSH clients
  (Termius) treat each newline as a real Enter and shatter one utterance into 5–6 messages. That asymmetry
  only exists on a paste path. [S]
- **Clipboard restoration:** *not documented by Typeless either way.* [P] The competing implementations both
  do it and both document the failure modes (see §6). → [I] Save-and-restore the user's clipboard, restore
  after a short delay, and expose a "keep dictation on the clipboard instead" toggle; this is the de-facto
  category behaviour and its absence is a common complaint vector.
- **Blocked synthetic input:** Typeless publishes **no** documented fallback, no "simulate keypresses" mode,
  and no per-app insertion strategy. [P] The closest thing to an acknowledgement is a troubleshooting page
  for *"Where did my transcript go?"*: if you missed copying it or closed the card, it is in **History** —
  i.e. the recovery model is "the transcript always lands in History, copy it from there." [P]
- **Secured fields / terminals:** no Typeless documentation covers password fields, secure input, or IDEs.
  The **Use cases** page lists **Terminal** among supported surfaces ("Draft commands, scripts, and notes
  without breaking your flow"), alongside VS Code, Cursor, Claude, ChatGPT, Slack, Gmail, Notion, Obsidian,
  Word, PowerPoint, WhatsApp, Discord, Telegram. [P] → [I] Terminal support is claimed but naive: it is the
  same text field as anything else, with newline semantics delegated to the host.
- **Result surfaces differ by action:** Dictate → text into the field; Translate → translated text into the
  field; **Ask anything about a selection → answer stays in a pop-up card, original selection unchanged**;
  **quick answers → pop-up card**; **quick actions → opens the relevant web page**. Speak-to-edit replaces the
  selection in place. [P]

## 3. The "AI cleanup" pipeline

### 3.1 What it does (all [P], from product + release-note copy)
1. **Filler removal** — "um", "uh", "you know".
2. **Repetition removal** — collapses repeated/unnecessary words.
3. **Self-correction resolution** — "Typeless recognizes when you correct yourself mid-sentence and keeps only
   your final intended message." The launch framing: "Auto-edits when you change your mind."
4. **Punctuation, spelling and grammar** — "Fix the spelling and format the writing for you" (onboarding).
5. **Intent-preserving rewrite** — "comprehends the meaning behind your words and optimizes your phrasing";
   "Find the perfect words".
6. **Structural formatting** — spoken lists/steps/key points become real lists/paragraphs; Markdown
   (headers, lists) is applied when the command asks for formatting. [P]
7. **Detail completion** — onboarding claims it will "Fill in the details you can't remember" and "Reorder
   and update everything as you go". [P]
8. **Tone/register** — "Different tones for each app … from work emails to casual chats". [P]
9. **Translation** — separate mode; produces "ready-to-send" phrasing "natural to locals", preserving
   "your energy and tone"; multiple target languages selectable from the Voice bar mid-session. [P]
10. **Instruction→draft ("Help me write", v2.8.0, 2026-09-22)** — speak the brief ("Write an email asking if
    Emma's free this Friday afternoon. Sign off with 'Will.'") and the model writes the artefact. This is
    prompt restructuring as a first-class feature: the utterance is a *spec*, not a transcript. [P]
11. **Ask anything / voice superpowers (v0.4.0)** — selected text + spoken command → rewrite, shorten,
    lengthen, change tone, translate, summarise, explain, find action items, "solve this math", "debug the
    code", draft a reply. Chained: select the new draft, press the hotkey again, "Make it sound more
    friendly", then "Translate this to Japanese." [P]
12. **Web-grounded rewriting (v0.9.0)** — commands containing "search", "latest" or "current" trigger a live
    web lookup before rewriting (example given: "Update this with the current price of Bitcoin"). [P]

### 3.2 Latency & streaming
- **No published latency figure.** Typeless advertises "in real time" / "instantly" and a "220 wpm" effective
  rate vs "45 wpm" typing. [P] — marketing, not a measurement. → [I] Do not treat "real time" as evidence of
  token streaming into the field.
- **Text lands at the end, as one polished block.** Every procedure reads: speak → stop → *"Your polished
  writing appears where you began dictating."* [P] The design constraint is structural: cleanup needs the
  *whole* utterance (self-corrections must be resolved after the fact), so a live word-by-word commit into the
  field is impossible without a rewrite pass. The nearest competitor states this explicitly — "Desktop
  dictation inserts the completed text after you stop, rather than displaying a live word-by-word transcript
  as you speak" [S] — and Typeless's own "reorder and update everything as you go" implies buffering. [P]
- **Voice bar is the progressive element**, not the text field: it is where listening state, the translation
  target, and the 60-second countdown are shown. [P]
- **Comparable measured latencies** (recording-end → final visible text, median of 20, same harness; Typeless
  not tested; harness built by a competitor, Talkify): Talkify **123 ms**, Spokenly **189 ms**,
  superwhisper **216 ms**, VoiceInk **324 ms**, Wispr Flow **587 ms**, Aqua Voice **630 ms**,
  MacWhisper **1149 ms**. [S] → [I] Budget **~0.3–0.8 s** from key-release to inserted text for a cloud
  design; anything over ~1 s reads as broken in reviews of this category.

## 4. Context awareness

- **What is sent to the cloud [P, vendor's own privacy text]:** "your voice audio **along with limited
  contextual information, such as the application you're using and relevant text within it**", processed in
  real time on Typeless's servers and "immediately discarded once the result is returned". The same claim
  appears in the Privacy Policy: "No voice recordings or screen context data are stored on our servers."
- **Per-app tone is automatic and profile-based**, not user-authored: "Typeless adapts tone and style based
  on the app you are using". [P] No user-editable per-app profile editor is documented. [P]
- **Selected text is an explicit input channel:** select text → hotkey → speak a command; the selection is
  both the object and the context. [P]
- **Clipboard context** is *not* claimed by Typeless. [P] (The nearest competitor reads clipboard text copied
  within 3 s of dictation. [S]) → [I] Nice-to-have, not required.
- **Previous utterances:** no documented cross-utterance memory in the *editor*. The **personalization**
  layer is the persistent channel: "Typeless naturally adapts to your tone … whether you tend to write more
  formal, more casual, more concise, or more detailed. There is nothing to set up." It surfaces a
  **personalization progress card** with a *View report*, is toggleable in Settings → Personalization, and the
  vendor claims it learns "general patterns only" and "never stores your actual messages". [P]
- **Personal dictionary:** manual add (one word/phrase at a time), **CSV bulk import**, and **automatic
  learning** — "When you correct a word after dictating, Typeless automatically recognizes your preferred
  spelling and adds the word under *Auto-added*." List views are filterable: All / Auto-added / Manually-added,
  with search, edit and delete. [P]
- **Regional variants** (v0.8.1): per-language dialect selection — variants exist for **English, Chinese,
  Spanish, French, Portuguese** — which "optimize its recognition for that specific dialect" and word choice
  (colour vs color). [P]

## 5. Onboarding, permissions, models, privacy, pricing, languages

### 5.1 Onboarding (macOS) [P]
1. Download `.dmg` from the Downloads page → open → drag to Applications → launch → click *Open* past Gatekeeper.
2. **Sign in:** Google, Apple, or email. Enterprise with SSO may sign in with / be required to use SSO.
3. **Grant two permissions:**
   - **Accessibility** — "so Typeless can paste text into any text field"; also enables Fn-key triggering.
     Deep link to System Settings → Privacy & Security → Accessibility. Manual path documented, plus
     *Quit & Reopen* if macOS asks.
   - **Microphone** — in-app *Allow*, then the macOS dialog; manual path via System Settings → Microphone.
4. **Microphone test** — speak, confirm moving blue bars; failure offers "No, change microphone" and points
   at System Settings → Sound → Input.
5. **Guided examples** for all three verbs, with their shortcuts shown, before first real use.
- **Input Monitoring is not requested on macOS** in Typeless's documentation — contrast Wispr Flow, which
  requires **both** Input Monitoring ("so Flow can detect the key being held") and Accessibility for
  hands-free. [P] → [I] Typeless's toggle model lets it live on Accessibility alone; a hold-to-talk feature
  is what forces Input Monitoring.
- **Known shortcut-conflict procedure** (a real support cost): if `fn` misbehaves, open System Settings →
  Keyboard and disable/reassign whatever system shortcut is bound to it. [P]
- **No documented keyboard-layout caveat.** Competitors document failure on non-QWERTY layouts. [S]

### 5.2 Model options: **cloud-only** [P]
- "**Cloud Processing:** Transcription is performed on the cloud to ensure the highest accuracy and
  low-latency performance." (Data Controls page.) There is **no on-device mode** in any Typeless
  documentation, no model picker, and no BYO-key path.
- **Third-party LLM subprocessors** named on the trust centre: **Gemini, Fireworks AI, X, Microsoft Foundry,
  OpenAI, Groq** (US), under "zero retention" agreements; hosting on AWS; analytics Mixpanel; payments Stripe
  and Apple; sign-in WorkOS. The vendor does not say which provider handles which request. [S — reporting of
  the trust-centre list; the underlying list is a vendor artefact]
- Independent [S] reverse engineering of macOS **v0.9.3** (Feb 2026, @medmuspg) found **no local speech model
  bundled**, audio compressed and sent to **AWS**, and a local `typeless.db` containing transcripts, browsing
  URLs and app info in **plaintext**, with audio files not fully deleted. It also asserted the app requests
  screen-recording, camera, Bluetooth and clipboard permissions and has a CGEventTap keyboard monitor, making
  keylogging *technically* possible. Tone: cautionary, not proof of misuse. Treat as [S], and note it
  contradicts the "Everything stays local" line in the Aug-2025 beta notes (the vendor later clarified that
  line meant *history*, not transcription).

### 5.3 Privacy claims [P]
Zero cloud data retention; never trained on your data (by us or third parties); on-device history; no audio
stored in the cloud; history encrypted across devices when Cloud Sync is on; ISO 27001 certified, GDPR
compliant, HIPAA compliant. Trust centre shows ISO 27001 *Compliant*, GDPR/HIPAA *Self-Attested*, SOC 2 Type
I/II *In Progress*. **History retention is user-set**: Forever / 1 year / 1 month / 1 week / 24 hours /
Never. **Optional Cloud Sync** (Pro) is the only way history text leaves the device; turning it off deletes the
cloud copy. Local History additionally stores the **audio** (you can *Download audio* and *Retry* with the same
audio) — a point reviewers flag as under-appreciated, since "zero retention" describes the server, not the Mac.
Feedback is the only opt-in path to share pseudonymised corrections.

### 5.4 Pricing (live page, 2026-10-16) [P]
| Plan | Price | Notes |
|---|---|---|
| **Free** | $0 | "**Limited words**", standard accuracy, standard access during high demand. The live page **no longer states a number** — archived copies showed 4,000/wk (Jan 2026), then 8,000/wk (Jun–Aug 2026), and current App Store reviewers report **2,000 words/week**. Full feature set otherwise. |
| **Pro** | **$12**/member/mo billed yearly ($144/yr) — or **$30**/member/mo billed monthly | Unlimited words, enhanced accuracy, priority during high demand, Cloud Sync, team management, centralised billing, usage analytics. |
| **Enterprise** | Custom | SSO, SCIM + JIT provisioning, domain verification & capture, configurable audit logs, enforced HIPAA + BAA, volume discounts, invoicing, priority support. |
| **Students** | 50% off Pro | New subscribers, desktop checkout only. |

Feature gates worth copying: word metering; accuracy tiering; queue priority; Cloud Sync; team/SSO/audit.
"Whisper mode" is listed as a plan feature and is included on Free. [P]

### 5.5 Languages [P]
**100+ dictation languages** with automatic detection and free mid-sentence mixing. **58 interface
languages.** Regional variants for English, Chinese, Spanish, French and Portuguese. Localisation exists for
en, pt-pt, es, ko, ja, zh-cn, zh-tw (site locales).

## 6. Known pain points, and why users pick something else

### 6.1 Typeless complaints
- **Free-tier cut is the loudest grievance.** App Store reviews on v2.6–2.7: "The limit was 8000 words per
  week, now it's 2000"; "only takes 3 days to hit the limit"; "don't be too awful". [S]
- **Upgrade nag prompts interrupt live sessions** — "interrupted me mid-session multiple times, leaving
  important information unrecorded". [S]
- **Over-aggressive rewriting**: "overly aggressive at trying to polish your words, often completely changing
  the intent … annoyingly trying to convert everything to bullet points and numbered lists". [S] A Russian
  review says the same in one line. This is the direct cost of the "restructure, don't transcribe" design.
- **iOS background defects**: battery drain (one user: 54% vs Instagram's 5%), device heating, and
  **auto-lock broken while Typeless runs in the background** (multiple v2.3–2.6 reports, fixed only by force
  quitting). [S]
- **Keyboard-extension friction on iOS**: session must be re-armed per message; no Enter key in the voice UI;
  manual swipe-back to the host app; no emoji; limited autocorrect. [S]
- **Cloud-only / no offline**, and the privacy-architecture critique above. [P][S]
- **Monthly price $30** vs Wispr Flow's $15. [S]
- **Context awareness called "basic"** next to Wispr Flow, with no IDE/code-specific handling. [S]

### 6.2 What users cite when they choose the alternatives
| Product | The behaviour users cite | Evidence |
|---|---|---|
| **Apple Dictation** | Free, on-device on Apple Silicon; but verbatim (no cleanup), **no custom vocabulary**, stumbles on names/jargon/code, and inserts one finished block you then hand-fix. One head-to-head counted 17 errors vs 1. | [S] |
| **Wispr Flow** | **Hold-to-talk push-to-talk** (default `Fn` on Mac, `Ctrl+Win` on Win) + separate **hands-free lock** (`Fn+Space`; `Ctrl+Opt+Space` on Fn-less Macs); **double-tap PTT within 0.5 s** to go hands-free; a **third rapid PTT tap cancels**; `Esc` cancels with **Undo**; experimental **"press enter"** command; per-app tone + IDE/code context; recovery path **"Paste Last Transcript"** (`Ctrl+Cmd+V`); **clipboard restoration that excludes file contents, PDF, RTFD and audio**, and a timed-out paste does **not** auto-restore; Android bubble is **hidden in password, phone-number, numeric fields and recognised banking apps**; 20-min desktop cap, 5-min Android cap; requires **Input Monitoring + Accessibility** on Mac. | [P] |
| **superwhisper** | **Modes** (Message / Super / Mail / Note / Meeting / Voice to Text) with a **Tone slider**; **Super Mode context** = active app + input-field text + **selected text** + **clipboard text copied within 3 s**, plus date/time and your name; commands deliberately limited to formatting/transformation, *not* generation; delivery is **paste**, default **"Keep what I have copied"** restores your clipboard, with a documented failure mode where the target app reads the clipboard late and pastes the *old* content — the fix is "Replace with dictation"; experimental **"Simulate keypresses"** types key-by-key for **secure fields, some terminals and VMs**, US-QWERTY only; local models (Parakeet, Cohere Transcribe) vs cloud (S1-Voice, Nova 3), so privacy-first users get a genuinely offline path. | [P] |
| **VoiceInk / MacWhisper** | Fully local Whisper (whisper.cpp); VoiceInk is open source, MacWhisper is a one-time purchase aimed at transcribing *files* rather than live dictation. Chosen when "audio must never leave the machine" is a hard rule. | [S] |
| **Aqua Voice** | Selected for accuracy plus **live editable text** and a **Voice Edit Mode** (fix by voice instead of reaching for the keyboard), ~450 ms to final words, system-wide including terminal. | [S] |
| **The recurring meta-reason** | In community threads the deciding factors are, in order: *does it run locally / where does my audio go*, *subscription vs one-time*, *does the cleanup actually reduce editing*, and *is the latency acceptable*. One MPU Talk thread's summary of Apple Dictation vs Wispr Flow is representative: Apple improved but "nowhere near as good … in correcting minor rambles, formatting", yet the poster abandoned Wispr Flow anyway "because they've made Wispr Flow so painful to use on iOS". | [S] |

---

## 7. Implementation spec — essential vs nice-to-have

### Tier 0 — Essential (the product does not exist without these)
1. **Global hotkey, press-to-toggle**, one main binding, with a second "start this other verb" binding.
   Remappable + *add another* binding for external keyboards. Must not require the user to leave the app.
2. **Insertion into the focused field via clipboard + synthetic paste under Accessibility**, with (a)
   save/restore of the previous clipboard, (b) a "leave dictation on the clipboard" option, (c) a fallback
   typing mode for apps that reject synthetic paste, and (d) **every transcript always recoverable from
   History** when insertion fails.
3. **Cloud STT + one LLM cleanup pass, committed as a single final block on stop.** Target < 1 s
   (aim 300–800 ms) from key-release to visible text. Do not stream raw words into the field.
4. **Visible, cancellable session state**: floating voice bar, start/stop sound, `Esc` to cancel, a hard
   duration cap with a countdown warning, and auto-save-on-timeout.
5. **Cleanup primitives**: filler removal, repetition collapse, self-correction resolution (keep the last
   intent), punctuation + capitalisation, list/paragraph structure, and a rewrite that preserves meaning.
   Self-correction is the differentiating primitive — implement it deliberately.
6. **Context = active app identity + on-screen/field text + selection**, sent with the audio, used for tone
   and terminology. Per-app tone must be automatic and profile-based, with zero setup.
7. **Personal dictionary** with three ingest paths: manual, bulk CSV, and automatic capture from
   post-dictation corrections (labelled *Auto-added* vs *Manually-added*).
8. **Local history** with retention control, copy, retry-with-same-audio, delete-one/delete-all, and
   optional audio download.
9. **Onboarding that asks for exactly two permissions** (Microphone, Accessibility), deep-links to System
   Settings, handles the "toggle off and on again" repair, and includes a live mic-level test plus a guided
   first run of every verb.
10. **Metered free tier + paid tier with accuracy and queue-priority gating.**

### Tier 1 — Nice-to-have (differentiators, in the order Typeless ships them)
11. **Translate mode** with multiple pre-set target languages and in-voice-bar switching mid-session.
12. **Selection verbs**: rewrite selection in place; ask *about* a selection with the answer kept out of the
    document (pop-up card); quick answers in a card; quick actions that open a web page.
13. **Instruction→draft** ("Help me write"): treat the utterance as a brief, not a transcript.
14. **Personalization** that learns register over time, with a visible progress indicator and an off switch.
15. **Web-grounded rewriting**, triggered by explicit "search / latest / current" phrasing.
16. **Markdown output** (headers, lists) when the command asks for structure.
17. **Whisper mode** — quiet-speech recognition for shared spaces. Cheap to add, disproportionately
    appreciated.
18. **Language variants** per locale, and 100+ languages with code-switching.
19. **Quality-of-life**: interaction sounds, mute-other-audio while dictating, launch at login, dock toggle,
    light/dark/system, device picker with level meters.
20. **Sync / team / compliance**: encrypted history sync, team seats, analytics, SSO/SCIM/JIT, audit logs,
    BAA + enforced HIPAA, domain capture.

### Tier 2 — Explicitly do NOT copy
- **Over-bulletising.** Reviewers punish "converts everything to bullet points". Format only when the user
  spoke a list or asked for one.
- **Intent drift.** If the cleanup changes what was meant, the product is worse than raw transcription.
  Constrain the rewriter: never add facts, recipients, dates or commitments that were not spoken.
- **Nag prompts during a live session.** Gate, warn, degrade — but never interrupt dictation.
- **Undocumented permission sprawl.** Ship the two permissions you need; every extra one costs trust.
- **A free tier that is quietly cut.** The single most damaging thing Typeless did to its own reviews.

### Acceptance tests worth writing first
- Tap hotkey, speak "um, so, uh — send it Tuesday, no wait, Wednesday" → field receives "Send it Wednesday."
- Speak a three-item list → three bullets, not one paragraph; speak prose → prose.
- Copy text, dictate, paste → the original clipboard content is intact.
- Dictate into a field that blocks paste → text is typed or the user is offered the clipboard, and History
  always has the transcript.
- Close the text field mid-dictation → transcript is in History and recoverable.
- Speak 8:50 → countdown is visible; at 9:00 the session ends and History holds the partial transcript.
- Dictate into Gmail vs Slack → measurably different register from the same words.
- Correct a name after insertion → the word appears under *Auto-added* and is fixed next time.
