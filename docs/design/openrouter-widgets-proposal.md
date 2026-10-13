# OpenRouter widgets: design proposal

Status: **proposal, awaiting your UI/UX approval.** Nothing here is implemented, and no production source or
configuration changed. Date: 2026-10-12. Branch `design/openrouter-widgets`, base `2d21e62`.

Evidence: [research report](../research/openrouter-widget-research.md) and
[POC files](../research/openrouter-poc/). Sketch: [openrouter-widgets-sketch.html](openrouter-widgets-sketch.html)
(open it in any browser; no network). All money in the sketch is **mock**. The catalogue rows are the 17 real
sample entries from the 2026-10-12 capture; counts (662 / 459 / 149) are **historical sample** numbers.

The HTML sketch only shows layout, wording and interaction order. It **cannot** prove native AppKit focus,
window behaviour or performance. Those need the native checks listed at the end.

---

## 1. Recommendation in one paragraph

Ship **two widget kinds**, *OpenRouter Credits* and *OpenRouter Models*, backed by **one shared
`OpenRouterService`** that talks to the HTTP API directly (no CLI). Credits needs a **management key** and
shows the **account balance** plus an optional **bar chart of the last 7 completed UTC days of spending**, either
for the whole account or for one key. Models needs **no key**. It is **block-built** with the existing builder
(Summary + repeatable Model list blocks), sorts by **Latest added** by default, and has a
**Text-only / Text output / All** filter and **Lean / Standard / Detail** rows. "View all" opens the full,
searchable catalogue in a **standard-width, full-height side surface**. This is your *always-left* idea (§6.3):
on a left panel it covers the panel like a takeover, and on compact or minimal panels it widens to standard width.
From a top or bottom bar it spawns a temporary left surface. It's built as **one separate key-capable window**
drawn like the panel, so the panel itself is never resized, rebuilt or made key, and **it overlays apps rather
than reserving space**. *Revised after evaluating your idea:* the first version of this proposal recommended an
anchored popup. That, in-place takeover and a normal window all remain approval alternatives (§6).

## 2. Approval choices (please pick)

**Decided by you (2026-10-13): the details panel.** This replaces the earlier side-surface notes and overrides
§6 / §6.3 wherever they differ.

- **What it is.** A reusable **details panel**: a separate window that any widget can fill with more detail. The
  model catalogue is the first user; Railway and others come later.
- **It replaces your panel; it doesn't sit on top.** While it's open, the side panel is hidden and the details
  panel takes its place.
  - **Left or right panel:** it opens on the same side.
  - **Top or bottom bar:** it opens on the left.
- **Always the same fixed width,** whatever the panel's width, so detail views can be designed once.
- **It makes room by moving windows, and puts them back on close.**
  - Windows move only by the difference between the panel's width and the details panel's width.
  - On close, a window goes back to its old position and size **only if it hasn't changed since**. If you moved or
    resized it yourself, it's left alone.
  - **Exception:** a window whose edge touches the details panel's edge is moved or stretched on close to keep
    touching whatever is there afterwards: **the panel's edge**, or **the screen edge** when there's no side panel
    there (the bar case). This applies even if the window changed. A snapped edge is usually deliberate, and this
    avoids leaving a gap.
- **Style.** By default it uses the main panel's background style. A **"Custom style"** switch reveals its own
  background options. Transparency stays allowed.
- **Closing.** Clicking outside never hides it, and it never closes on a timeout. It has its **own close button**,
  part of the details panel's generic chrome, so every future widget gets the same one for free. Escape (when it
  has focus) and the close shortcut do the same.
- **Shortcuts.**
  - The existing hide/show shortcut (default ⌥⌘S) hides the details panel together with the panel. Showing them
    again brings the details panel back if it was open.
  - A **second shortcut** closes the details panel from anywhere. Default **⌃⌥⌘S** (agreed), changeable in
    Settings. Not ⇧⌥⌘S, which is *Save As* in many apps.

Implementation notes (for the issue after approval):

- **One handoff, not two steps.** Swapping panel → details panel must not first restore windows for the hidden
  panel and then push them again. The reserved area changes once, from the panel's strip to the details panel's
  strip.
- **Reuse your planned window restore.** It's the same restore feature you're building for the panel's show/hide.
  Record the frame Sidelight set on each moved window, and compare it on close to decide "unchanged".
- **When windows can't move,** for example when window avoidance is off or Accessibility access isn't granted, the
  details panel overlays apps instead.
- **Windows that can't take part:** windows opened while it was showing, and fullscreen windows or windows on other
  Spaces, have no saved position, so they aren't restored. Apps that refuse a size get as close as they allow.
- **A details panel wider than the main panel moves nothing outward.** Only snapped edges follow on close.
- **Data under the hidden panel:** widgets that are hidden behind the details panel can pause their data like a
  hidden panel. Use a short grace period so a quick open and close doesn't refetch everything.
- **Fixed width:** start at ~360 pt and adjust later, comfortable for search and readable rows on a 1440 pt-wide
  screen.

Still open: B (Credits scope), C (two kinds vs one) and D (Models defaults).

| # | Decision | Recommended | Alternatives |
|---|---|---|---|
| **A** | Where the full catalogue opens | **Always-left side surface** (§6.3): standard width, full height, a separate key-capable window that never activates Sidelight. It covers a left panel, widens a compact or minimal one, and spawns at the left edge from bars. **Overlays apps; never moves windows.** | **Anchored popup** beside the trigger (the earlier recommendation). **In-place takeover** that mutates the panel itself. **Normal window** (activates Sidelight; the fallback if non-activating key focus fails). |
| **A2** | Right-edge panels under the always-left surface | **Use the panel's own edge** (mirror the left behaviour on the right), since its value is "a side panel at standard width where your panel is" | **Strictly left**: a temporary left surface while the right panel stays. Consistent, but it's the farthest point from both the trigger and the panel. |
| **A3** | Space for a spawned or widened surface | **Overlay apps** (no avoidance, no window moves) | **Reserve space**: other windows get pushed or shrunk, and today nothing moves them back (§6.3) |
| **B** | Credits first scope | **Management key only.** Account balance, plus a 7/14/30-day completed-UTC-day chart that covers the account or one selected key. One saved connection. | (B2) Balance only first, with the chart later. (B3) Also accept an ordinary inference key in a clearly labelled reduced *Key budget* mode. |
| **C** | Widget structure | **Two kinds.** Credits uses a simple inspector; Models uses the builder. They share one service and cache. | One *OpenRouter* builder widget with Balance, Spend and Model list blocks. |
| **D** | Models defaults | **Latest added**, **Text output** filter, **Standard** rows, 5 rows, sync every **60 min**, glance shows the **newest model** | Default filter *All* (the latest "All" entries are often decision/embedding models, which surprised us in the sample). Glance shows the *catalogue count*. |

Everything else below follows from these. If you pick a different option, only the matching sections change.

## 3. Widget kinds and why they're separate

| | **OpenRouter Credits** | **OpenRouter Models** |
|---|---|---|
| Credential | Management key (Keychain) | None (public `GET /models?output_modalities=all`) |
| Data | `GET /credits` (balance = purchased − used), `GET /activity` (30 completed UTC days), `GET /keys` (only when picking a key) | One shared catalogue snapshot (~662 rows / ~0.99 MB in the sample) |
| Editor | Inspector (no builder) | Existing `BlockBuilder` + presets |
| Glance (minimal/bar) | Balance, e.g. `$74.25` | Newest added model name (or count) |

Why two kinds rather than one combined widget:

- **Credentials don't leak into the catalogue.** Someone who only wants the model list never sees a
  management-key prompt, and Sidelight never loads a secret for that widget.
- **Each glance is clear.** Minimal and bar sizes show one value. "Money" and "newest model" make two good glances;
  a combined widget would have to pick one.
- **Demand stays narrow.** A visible Models widget never starts private requests, and a Credits widget never
  downloads the 1 MB catalogue.
- Both appear together under **OpenRouter** in the Widgets window, so they still feel like a family.

Why Credits doesn't use the builder (yet): it has two pieces, and one of them (balance) is always shown. A builder
would add ceremony with no real choice behind it. If key budgets or extra charts come later, Credits can become
block-built, because `BlockLayout` loads unknown blocks hidden, so released configurations stay readable.

## 4. Credits

### 4.1 Credential tiers (setup)

| Tier | What you add | What works |
|---|---|---|
| 0: nothing | n/a | Models widget fully. Credits shows a setup message, never `$0`. |
| 1: **management key** (recommended) | Pasted once in Settings › Connections › OpenRouter, stored in Sidelight's **own** Keychain item | Account balance, 30-day spending, key picker (default workspace), key-scoped chart |
| (later / B3) ordinary inference key | Same place, labelled *Key budget only* | That key's own usage, limit and remaining allowance. **Never shown as account money.** |

Setup copy has to be honest: *"A management key can also create and delete keys. Sidelight only reads with it,
but a narrowly scoped read-only management key wasn't established in our research."* Sidelight never auto-detects keys from shells, files, other apps
or the Ori CLI. If someone pastes an ordinary key, Sidelight checks the `is_management_key` flag from `GET /key`
and explains that this key can't read the account balance, rather than failing silently.

**API vs CLI:** API. OpenRouter's official CLI (Ori) exists, but no stable JSON commands for credits, activity or
models were found. Calling a CLI would add process spawning, updater and auth-file dependencies for no gain.
Sidelight's `HTTP.send` already runs off the main actor and handles cancellation.

### 4.2 Layouts

- **Regular:** label *ACCOUNT BALANCE · USD*, big figure `$74.25`, a quiet caption *Updated 4m ago* followed by a
  tiny refresh icon. Below that sits the chart: 7 bars and a caption with the total, e.g.
  *$1.55 · last 7 UTC days*. When a key is selected, the caption reads *Key "dev-laptop" · last 7 UTC days* and a
  one-line note under the balance says *Balance is account-wide*. The key's budget never replaces the balance.
- **Compact:** figure + the chart, without the caption line.
- **Minimal / bar:** just `$74.25`. Hovering shows a tooltip with the last update time; clicking does nothing in
  the first scope. Stale data shows as a dimmed figure plus a small dot.

### 4.3 Chart semantics (UTC, partial, missing, error)

- Bars are **completed UTC days only**. Today isn't drawn, because `/activity` has no today and a partial bar
  would mislead. The caption says "UTC" so nobody assumes local days.
- The first scope shows **7 days** (options 7/14/30). It reuses the existing **bar** `Sparkline`, so no new line
  chart is needed, and the most recent bar gets the accent colour.
- One `/activity` request covers all 30 days. Rows are summed by date into `usage` (credits). **BYOK external
  inference** (`byok_usage_inference`) is kept separate: it appears in the hover detail as
  "+ $1.20 BYOK (not from balance)" and is **never** added to the total.
- **No rows for a day** in a complete, successful response draws as a hairline baseline tick, not a bar. Its
  hover text says "No activity reported". The total sums only reported rows. Nothing is invented.
- **Error / never loaded:** the chart area says *Spending unavailable* with a retry control. It never shows an
  empty or zero chart.
- **Stale** (the last fetch failed after an earlier success): keep the last bars, dim them slightly and add
  *as of Oct 11*.
- **Key scope that no longer resolves** (key deleted or disabled): *Key "dev-laptop" not found*. It does
  **not** quietly fall back to the whole account. The saved hash stays, so the chart comes back if the key does.
- Longer ranges or a *partial today* via `/analytics/query` are possible **later**. They aren't a dependency for
  the first version.

## 5. Models

### 5.1 Blocks and presets (existing builder)

| Block | Kind | Options |
|---|---|---|
| **Summary** | fixed | Shows `662 models · synced 12m ago ⟳`. Option: show count per current filter or the whole catalogue |
| **Model list** | **repeatable** (like Railway's Service block) | Title, sort, filter, density, rows (1–20, default 5), show retiring badge |

Whole-widget options (the builder's *Widget* section): **Sync every** Manual / 15 / 30 / **60** / 180 / 360 min,
and **Glance** Newest / Count.

Presets: **Latest** (Summary + list: Latest added, Text output), **Text-only** (list: Text-only, Name),
**Rich list** (Summary + list: Detail rows, 8 rows).

A *Pinned model* block (one model in detail, with a retiring badge) is a natural later addition. It's not in the
first scope.

### 5.2 Sort, filter and density

- **Sort:** **Latest added** (default; `created` descending, ties broken by ID), Name, Context (largest), Input price
  (lowest), Output price (lowest). Unknown prices (`-1`, missing) **sort last**. The label stays "Latest added",
  never "released".
- **Filter:** **Text-only** means input and output are both exactly `{text}` (149 in the sample). **Text output**
  means the output includes text, whatever the inputs. **All** applies no filter, so decisions, embeddings,
  speech and video models show up and unknown future modalities still appear. The filter reads the
  `input_modalities` / `output_modalities` arrays, never the display string.
- **Density:**
  - *Lean:* one line with the name and a muted age (`2d`). Best for compact and narrow columns.
  - *Standard:* name and age, plus a second line with the provider-trimmed ID and `$in / $out per M`.
  - *Detail:* Standard plus context (`1M ctx`), modality (`text·image·file → text`), and badges: **Free** (only
    `:free` IDs), **Retiring Oct 31** (from `expiration_date`), **Varies** (router price `-1`).
- **Prices** are USD per million tokens, converted from per-token decimal strings. A bare `$0` stays `$0`; the
  *Free* badge appears only for `:free` variants, because 105 entries had zero token prices but only 22 were
  `:free`.

### 5.3 Small controls: refresh and "View all"

There's no header accessory hook today, and hidden titles would make one disappear anyway. So the controls live
**in the content**, and behave the same with titles on or off:

- **Refresh** is a tiny `arrow.clockwise` at the end of the Summary caption (or the list's last line if Summary is
  hidden). It's visually quiet but has a ~22×22 pt hit area, a tooltip and a VoiceOver label. It becomes a spinner
  **only while a request is in flight**, and is disabled during that time.
- **View all 662 ›** is a full-width footer row under the list. It's a plain button, never nested inside another
  clickable row.
- **Minimal card / bar chip:** the whole chip opens the catalogue. Refresh lives inside the catalogue, because
  there's no room on the chip.

### 5.4 Full catalogue

- It opens **instantly from the cached snapshot**. If the snapshot is stale, a background refresh starts, and
  results replace the rows without jumping the scroll position (rows keep stable IDs).
- The header holds a search field (name or ID), filter chips (Text-only / Text output / All), a sort menu and a
  count (`149 of 662`). A tiny refresh with *synced 12m ago* sits there too.
- Rows use **Standard** density. Clicking a row expands it in place to show Detail (context, modalities, prices,
  retiring date, alias target) and an **Open on openrouter.ai** link. No per-row API calls.
- The initial filter and sort come from the list the user clicked. Changes made in the catalogue last until it
  closes and don't write back to config. The search text clears on close.

## 6. Where the catalogue opens: popup, takeover, normal window, always-left side surface

| | **Anchored popup** (earlier recommendation) | In-place panel takeover | Normal window (fallback) |
|---|---|---|---|
| Typing focus | Separate small `NSPanel` that **can become key** but uses `.nonactivatingPanel`, so the app you were in stays frontmost and the menu bar doesn't change. Needs native validation (§8). | The panel itself would have to become key-capable. That changes behaviour for every widget and contradicts the "never key" design. | Reliable: Sidelight activates, a real key window, and the Edit menu works. |
| Other widgets | Untouched | Hidden while browsing | Untouched |
| Window avoidance / geometry | Unchanged; the popup floats over other apps briefly | A fitted panel would grow or shrink, and other windows get pushed around | Unchanged |
| Top/bottom bar | Opens below or above the chip, clamped to the screen | **Doesn't fit**: a 44 pt bar would have to grow to a list height and push every window | Fine |
| Minimal column | Opens beside the column at normal width | The list would be squeezed into ~100 pt | Fine |
| Feel | Like a menu-bar popover: quick and contextual | Feels native inside the panel, but disruptive | Heavy for a glance; steals focus from your editor |
| Cost to build | New small window controller, anchoring and key handling | Panel state machine, back stack, demand and avoidance changes | Smallest, using the manager's existing patterns |

*This comparison was written before your always-left proposal. §6.3 re-evaluates it and changes the recommendation.*

**Why the popup (original reasoning):** it is the only option that works the same on all five placements (left, right, top, bottom,
minimal) without moving other windows or hiding other widgets. It also keeps the panel's "never key" rule intact.
Panel takeover breaks down on bars and minimal columns. The normal window is the safety net: if native testing
shows a non-activating key panel can't do reliable text editing, switch to it. That fallback still works as a
popup-*placed* window that activates Sidelight while it's open.

### 6.1 Interaction spec for the popup

- **Opening:** triggered by a click or keyboard activation of *View all* or a minimal/bar chip. The popup takes key
  status and focuses the search field immediately, since the user explicitly asked to browse. Sidelight is
  **not** activated, so other apps don't reflow and the menu bar doesn't change. It uses a ~120 ms fade and scale
  from the anchor via `Motion`, and respects Reduce Motion.
- **Typing and editing:** typing, ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z work in the search field. A non-activating panel doesn't
  get the app's Edit menu, so the panel forwards these standard key equivalents to the first responder (with
  `NSApp.sendAction` and the standard selectors). This must be verified natively, along with the IME and dictation
  basics.
- **Escape:** the first press clears a non-empty search, the second closes. **Back** doesn't exist here, because
  the popup has no stack. Expanded rows collapse on Escape before the search clears.
- **Outside click:** closes the popup. Focus goes **wherever the user clicked**, not back to the trigger.
  Clicking the trigger again toggles it closed.
- **Focus return:** if closed with Escape or the close button, key status returns to the window that had it
  before (the previously frontmost app). Sidelight never ends up as the active app, and the trigger's
  accessibility focus is restored for VoiceOver users.
- **Anchoring:** left panel opens to the right of the card, right panel to the left, top bar below the chip, bottom
  bar above it, minimal column beside it. The popup is vertically or horizontally aligned to the trigger, then
  **clamped to the panel screen's `visibleFrame`** with an 8 pt margin. Size is about 380×min(560, available) pt,
  with a minimum width of 300 pt.
- **Multi-display / fullscreen:** the popup goes on the trigger's screen, never the main screen. It uses the
  panel's `collectionBehavior` (`.fullScreenAuxiliary`, `.canJoinAllSpaces`), so it works over fullscreen apps
  wherever the panel does.
- **Closes automatically when:** the panel hides (hotkey or Space change), the panel's orientation or screen
  changes, the originating widget is deleted or moved to another section, the display configuration changes, or
  the screen locks. It doesn't try to re-anchor after a geometry change; closing is predictable.
- **State restore:** scroll position and expanded row are kept while the popup is open. On close, nothing
  persists except the user's widget settings (§5.4).
- **Accessibility:** the popup is a dialog labelled "OpenRouter models". Rows are buttons, and ↓ moves from search
  to the first row.

### 6.2 If you choose panel takeover instead

The panel content swaps to *‹ Back · search · list*. The panel would need key status while it's showing (scoped
to takeover only), and its fitted length freezes at the current size so avoidance doesn't move windows. On bars,
the catalogue would have to become a horizontal strip with no list, so in practice bars would still need the
popup. Escape: clear the search, then Back. Back restores the previous scroll offset.

### 6.3 Always-left side surface: your proposal, evaluated

**Your idea:** the full catalogue is always a side panel at standard size on the left. If the panel is already a
regular left panel, it's an ordinary takeover. A compact or minimal left panel grows to standard size while the
catalogue is open. A top or bottom bar spawns a left panel for it. So the catalogue is always a left panel at
standard size.

#### Strongest case for it

- **For the default setup it is simply the best fit.** Sidelight's defaults are a **left** panel at the **regular**
  preset, filling the whole edge, on the main display (`PanelDefaults`). For that user, "View all" turns the panel
  they already look at into the catalogue, and Back returns. Nothing appears anywhere new.
- **Full height and room.** The popup was capped at ~560 pt. A side surface gets the display's whole visible
  height, about twice as many rows, with the search, filters and sort always visible at the top.
- **One predictable place.** Muscle memory works: the catalogue is always at the left edge, whatever the panel
  placement. It never pops up somewhere that depends on where a chip happened to be.
- **It can stay open while you work.** A side surface doesn't need to close on an outside click. You can find a
  model, copy its ID, click into your editor, paste, and come back with the search intact. The popup loses that
  on the first outside click, and this is a very common developer workflow.
- **It looks like Sidelight.** It uses the panel's own background and shape (`PanelBackground` is already
  reusable outside the panel window), rather than a generic popover.
- **Placement is simpler than the popup's.** It's edge-attached with a full-height frame. There's no
  trigger-relative clamping on four edges.

#### What "standard size" means natively (assumption, please confirm)

The panel's width setting is `PanelWidth`: a preset (`minimal`, `compact`, `regular`), points or a percentage.
Presets scale with the screen: **regular is 272 pt on a 1440 pt-wide screen and 304 pt at 2560 pt and above**
(compact 168–196, minimal 64–72). Columns and density are then derived from the width (`PanelColumns`: regular
needs ≥ 260 pt per column, compact ≥ 120 pt, and a column is never wider than 420 pt).

**Assumption:** *standard* means **the regular preset width for that display**, and the surface is never narrower
than the panel it covers: `width = max(panel width, regular preset)`. A 420 pt or 30 % multi-column left panel
keeps its own width, and the surface covers it exactly. The Standard catalogue rows fit 272–304 pt (the sketch
truncates long IDs cleanly). Detail rows would wrap more than they did in the 380 pt popup.

#### Behaviour per placement (recommended version)

| Panel | What opens | Panel window | Other apps' windows |
|---|---|---|---|
| Left, regular or wider | Surface exactly over the panel's strip. Header **‹ Back**. | Untouched underneath: same frame, widgets, scroll | Not moved |
| Left, compact / minimal | Surface from the panel's left edge, **regular-preset wide**, so it extends over apps by ~100–230 pt | Untouched underneath | **Overlay:** not moved |
| Left, fit length | Full strip height. A fitted panel's strip is already the whole edge, so this needs no new space | Untouched | Not moved |
| Top / bottom bar | **Temporary left surface** on the bar's display, full height minus the bar strip. Header **✕**. The bar stays, with its chip shown as open | Untouched | **Overlay:** not moved |
| Right (**proposal, needs your decision**) | **Recommended:** the right-edge mirror of the left behaviour (covers or widens the right panel). **Alternative:** strictly left, as a temporary surface | Untouched | Not moved |

Why I'd mirror on the right: what makes your idea good is "a full-height side panel where your panel is". For a
right-panel user, a left surface is the farthest point from both their panel and the trigger, often 1,500+ pt
away on a large display. Strictly-left is still a valid choice if you value "always the same edge" more. The
sketch has both.

#### Overlay vs reserve space (spawned or widened surfaces)

- **Overlay (recommended):** the surface floats over apps at the panel's level, like the popup did. Avoidance
  isn't involved, and nothing moves.
- **Reserve space:** grow the reserved strip so avoidance pushes windows out of the way. The current code makes
  this a poor choice:
  - Avoidance is **one-way**. When a strip grows, `AppController` calls `avoidAllWindows()` once, which shifts
    windows or (in *clip*/*smart* mode) **shrinks** snapped ones. Nothing remembers or restores their frames
    when the strip shrinks again. Every open would permanently rearrange or shrink the user's windows.
  - Adding restore logic is fragile: the user may move windows meanwhile, some apps refuse frames, and it needs
    Accessibility permission, without which overlay is the only behaviour anyway.
  - On a bar display, reserving a left strip would also make that display have *two* reserved regions, which
    `PanelCoordinator` (one panel per display) doesn't model today.

#### Architecture: separate surface vs mutating the panel

| | **Separate surface window (recommended)** | Mutate the existing panel |
|---|---|---|
| Key focus | Its own `NSPanel` with `canBecomeKey = true` and `.nonactivatingPanel`, the same mechanism the popup needed. The panel stays "never key". | `PanelWindow.canBecomeKey` would have to become conditional, so the window holding every widget gains key/first-responder behaviour |
| Widening | Only the surface window's frame | `move(to:)` with a temporary placement. `PanelColumns` would re-derive density, so **every widget relayouts** to regular and back, visibly |
| Avoidance | Unaffected. Never in `occupiedRegions` | `occupiedFrame` returns `placement.strip`, so a temporarily wide strip makes avoidance nudge windows whenever any window moves, and nothing restores them |
| Exact restore | Close the window. The panel's frame, density, scroll and widget state were never touched | Must snapshot and restore placement, scroll and fit length, with races against config or display changes during browsing |
| Bars / right | Same window, different frame | Impossible without a second panel per display |
| Risk | New code isolated from the panel everyone uses | Touches `PanelController`, the most sensitive code in the app |

Caveats for the separate surface:

- **Don't fade the panel out underneath.** `occupiedFrame` treats alpha ≤ 0.5 as hidden, so avoidance would let
  windows slide into the strip. Instead, the surface draws its own background, plus a solid scrim for the *none*
  and transparent background styles so widgets don't show through.
- **Covering the panel may count as occlusion.** If AppKit reports the covered panel as not visible, it becomes
  "unseen" after 60 s, and its widgets' services pause until the surface closes. That's arguably correct (nobody
  can see them), but it needs native confirmation. A translucent surface may not trigger occlusion at all.
- **Widgets under a covering surface keep their normal on-screen state** (for example, Now Playing could keep
  animating unseen). Validate the cost; an `isCovered` flag could pause them if it's measurable.

#### Honest tradeoffs vs the anchored popup

| | Always-left side surface | Anchored popup |
|---|---|---|
| Browsing room | **Full height**, persistent search header | ~520–560 pt max |
| Location | **Always the same edge**; Back from a left panel | Next to the trigger; varies with placement |
| Reach from a bar chip on the right half | **Far**: the eye has to jump to the left edge. It needs the slide-in from the edge and an "open" state on the chip | Right there |
| Surprise | Compact/minimal "growing" and a bar spawning a panel are bigger visual events, though nothing else moves under overlay | Small, local |
| Covers your work | ~272–304 pt strip at the left edge (from a bar or compact panel) until closed | Smaller, but over the middle of the screen |
| Copy/paste workflow | **Stays open** on outside click | Closes on outside click |
| Other widgets | Hidden while covering a left/right panel; visible from bars | Always visible |
| Multiple openers | One surface per display. Opening from another widget replaces its contents; a second display moves it there | Same |
| Accessibility | A persistent, labelled region; easy to return to | Transient dialog |
| Build cost | Similar: the same key-capable window class with simpler placement, plus a background and scrim | Trigger-relative anchoring on four edges |

#### Interaction spec (recommended version)

- **Open:** *View all*, the minimal card or the bar chip. The surface slides in from its edge (~0.3 s, like the
  panel's own `slideIn`; Reduce Motion fades it instead), becomes key, and focuses search. Sidelight isn't
  activated.
- **Escape** (when key): collapse an expanded row, then clear the search, then close. **‹ Back** or **✕** closes
  too. Clicking the trigger again toggles it.
- **Outside click:** the surface **stays open** and just resigns key. Clicking into it takes key again. This is a
  deliberate difference from the popup, for the copy/paste workflow. Clicking its search field restores typing.
- **Focus return:** on close, key returns to the previously key window of the frontmost app. The trigger gets
  VoiceOver focus without scrolling the panel. The sketch caught this: returning focus must not scroll.
- **Owner and closing:** each surface is owned by (display, widget, list block). It closes on: panel hidden by
  the hotkey, the panel's edge or width changing in config, the owner widget being deleted or moved to another
  display, the display disconnecting, or the screen locking. It follows the panel across Spaces and over
  fullscreen apps with the same `collectionBehavior`.
- **Multi-display:** everything is derived from the **trigger's window's display** (`PanelLayout.displayID`),
  never the main screen. A left panel on *another* display is irrelevant. On the trigger's display there is at most
  one panel today, so "a left panel already exists there" only happens when the trigger is in it, which means
  takeover.
- **State:** the panel is untouched, so its width, density, scroll and widgets restore exactly. The surface keeps
  search, filter, sort and scroll while open. They clear on close, as in §5.4.

#### Performance (proposed, unmeasured)

- Opening uses the shared cached catalogue snapshot (no request just for opening; stale data triggers one
  coalesced background refresh), with a lazy list.
- No widget is rebuilt or relayouted, and no avoidance pass runs.
- The surface window and its hosting view are created on open and released on close (`contentView = nil`, as
  `PanelController.close()` does). Nothing is pre-warmed or kept hidden, so there's no idle cost when it's closed.
- It holds a demand lease only on the catalogue resource.
- Proposed budgets: first frame of the surface under 100 ms from the click. Slide-in with no dropped frames. 0
  windows moved (verified via `Log.avoidance`). 0 extra requests when the snapshot is fresh. Memory returns to
  baseline after closing.

#### Verdict

**Better, with conditions, and it changes my recommendation.** Your always-left idea, built as a **separate
overlay surface** that is **mirrored on right panels** (pending your call, A2), is now my first choice over the
anchored popup. It fits the default left-panel setup perfectly, gives a much better browsing surface, supports
the copy-into-editor workflow, and its placement is simpler. The conditions:

1. A separate window, never mutating `PanelController`.
2. Overlay, never reserve space (unless you accept permanent window rearrangement, or an avoidance-restore
   feature is designed separately).
3. Native validation of non-activating key focus, shared with the popup.

Its real weakness is reach from a right-side bar chip. If that bothers you in the sketch, the anchored popup
remains a clean alternative.

#### Native spike that settles the rest (after approval, throwaway)

A debug-only window in `make dev`, with no config or settings, that hosts a text field and a static list:

1. Can it become key without activating Sidelight? Do typing, ⌘A/C/V/X/Z, IME and dictation work? Does key return
   correctly on close?
2. Does a covering surface mark the panel occluded, and does that pause demand?
3. Over fullscreen apps, across Spaces and on a secondary display (including one placed left of or above the
   main display).
4. Open latency and slide-in smoothness in Instruments.

The same spike can place the window as popup or side surface, so one experiment decides both.

## 7. Configuration and settings mapping

| Lives in | What |
|---|---|
| App Settings › Connections | OpenRouter connections: UUID and label in config. **The secret stays in Keychain** under that UUID. |
| Credits inspector | Connection, refresh interval, chart on/off, days (7/14/30), scope (Account / Key…) |
| Models builder › Widget | Sync interval, glance |
| Models builder › each block | Summary: count scope. Model list: title, sort, filter, density, rows, retiring badge |
| Memory only (not config) | Catalogue snapshot, balances, spending, search text, catalogue-surface filters |

An illustrative excerpt. The names aren't final, and there are no secrets in config:

```json
{
  "id": "6C1F…", "kind": "openRouterCredits", "showsInSidePanel": true, "showsInBar": true,
  "settings": {
    "connectionID": "A51E…",
    "refreshMinutes": 15,
    "chart": { "isShown": true, "days": 7, "scope": "key", "keyHash": "<64-hex>", "keyLabel": "dev-laptop" }
  }
},
{
  "id": "9B7D…", "kind": "openRouterModels", "showsInSidePanel": true, "showsInBar": false,
  "settings": {
    "syncMinutes": 60, "glance": "newest",
    "blocks": [ { "block": "summary", "shown": true }, { "block": "list:3E0A…", "shown": true } ],
    "listBlocks": {
      "3E0A…": { "title": "Latest", "sort": "latestAdded", "filter": "textOutput",
                 "density": "standard", "maximumRows": 5, "showsRetiring": true }
    }
  }
}
```

Every new field decodes with `decode(_:or:)` or `decodeLeniently`, and numbers are clamped to the UI ranges.
Unknown enum values fall back to defaults, and unknown blocks are dropped, following the `BlockLayout` precedent.
Both kinds get non-default values in `ReleasedConfigurationFixture.swift` when they ship.

## 8. Performance and lifecycle plan

All numbers are **proposed budgets, unmeasured**.

**Traffic defaults (while visible):**

| Resource | Default | Options | Proposed ceiling |
|---|---|---|---|
| Public catalogue (one snapshot for all Models widgets + the catalogue surface) | 60 min | Manual, 15, 30, 60, 180, 360 | ≤24 requests/day + manual |
| Balance (per connection) | 15 min | Manual, 5, 15, 30, 60 | ≤96/day |
| Activity (per connection and scope) | Once per completed UTC day, plus one request after UTC midnight when visible | n/a | ~1–2/day/scope |
| Key list | Only when the key picker opens and the list is stale | n/a | 0 in steady state |

**Rules:**

- **One service, shared resources.** `OpenRouterService` owns one catalogue resource plus one resource per
  connection (balance, and activity per scope). Each has its own `FetchSchedule`, using the shortest interval any
  visible widget asked for. Requests already in flight are deduplicated. There's **no per-widget timer, no fetch
  started from a view `body`, and no per-row API call**.
- **Demand:** follows `ServiceDemand`. A hidden panel, an unseen screen (~1 min grace) or a widget not on any panel
  means no requests. Builder and Widgets-window previews of Credits use mock or placeholder data and never load
  the Keychain, following Railway's precedent. Removing the last Credits widget drops that connection's resources
  and its private cache.
- **The open catalogue surface (side surface or popup) holds its own narrow demand lease** on the catalogue resource only, so it keeps working even if the
  panel auto-hides. It doesn't keep other widgets' services alive.
- **Spinner only in flight.** Stale-age labels ("12m ago") update on the existing coarse clock, never a per-frame
  timer.
- **Manual refresh** is coalesced with any request in flight. There's a ~15 s minimum gap, and it can't bypass a
  server `Retry-After`.
- **Backoff:** transient errors use `FetchSchedule` backoff. 429/503 honour `Retry-After` per connection.
  401/403 pause automatic retries for that connection until its credential changes. 400 never loops.
- **Offline / error:** keep the last good snapshot with a stale cue. Money is never replaced with `$0`, and lists
  are never erased on a transient failure.
- **Credential rotation:** bump the connection generation, cancel its work and clear its private cache before
  publishing again.
- **Catalogue processing:** decoding and normalisation happen off the main actor (`@concurrent`) into a compact
  Sendable `[ModelSummary]` that keeps only the needed fields, with a precomputed lowercased search key.
  Filtering, sorting and search over ~662 rows run on that array. The catalogue list is lazy (`LazyVStack`, or
  `NSTableView` if measurements require it). Widget rows render only their visible N.
- **Disk persistence:** none in the first scope. On a cold start while offline, Models shows *Catalogue
  unavailable · Retry*. A persisted public snapshot can come later if you want it. Private data stays in memory
  only.

**Proposed budgets (to measure natively, unmeasured today):**

- 0 network requests and 0 scheduled wake-ups with no demand. CPU stays at its idle baseline with the panel hidden.
- One scheduler per resource, never one per widget.
- Catalogue decode off the main actor; main-actor publish under 16 ms; incremental retained memory under 5 MB;
  response body capped at 5 MB.
- Popup visible within 100 ms of a click, using the cached snapshot. A search keystroke filters in under 8 ms of
  main-actor time. Scrolling 662 rows shows no dropped frames in Instruments.

## 9. Native validation after approval

1. **Focus** (run the §6.3 spike first): with Xcode, Terminal and a browser frontmost, open the surface or popup and check that typing works, ⌘A/C/V/X/Z
   work, the menu bar and frontmost app don't change, and closing with Escape or an outside click returns key
   status correctly. Repeat with VoiceOver, an input method (Japanese IME) and dictation. **If this fails, switch
   to the normal-window fallback.**
2. **Anchoring:** test left, right, top, bottom and a minimal column, each on the main screen, a secondary display
   on either side, a display above, and over a fullscreen app. The side surface must sit flush to its edge at full
   height (minus any bar) and never be narrower than the panel it covers. A popup must be clamped and never cross
   displays.
3. **Lifecycle:** the side surface or popup closes on panel hide, orientation change, widget deletion and display change. Check
   no leaked window or task afterwards (Memory Graph).
4. **Energy:** use Activity Monitor and Instruments (Time Profiler, Allocations, Points of Interest around fetches)
   for before/after idle with each widget visible, hidden and occluded. Confirm request counts match §8 over an
   hour.
5. **Catalogue:** record decode time, memory and search latency against a recorded fixture, plus scroll hitches.
6. **Money (needs your authorised management key, outside the sketch):** reconcile the balance and 7-day sums with
   the OpenRouter dashboard, and check key scope, a disabled key and the 401/403 copy.
7. `make check`, plus screenshots of all four layouts and both states in the Widgets window.

## 10. Out of scope

Inference/chat, key create/delete/edit, top-ups, notifications on new models, auto-detecting credentials,
personalised `/models/user`, performance/popularity sorts, provider endpoint details and multiple accounts.
All are feasible later, and none is needed to judge this design.

## 11. Ideas noticed along the way

- A **header accessory hook** in `WidgetCard` (shown only when titles are visible) could later host refresh for
  every widget consistently. That's a separate small change to discuss on its own.
- The Widgets window could show **OpenRouter** as a grouped family with both kinds, the same way it already
  previews other kinds.

## 12. Sketch QA done (browser only)

The sketch was rendered in local headless Chrome, driven over the DevTools protocol from a throwaway script in `/tmp`.
It made no network requests and installed nothing.

- HTML tags balance and the JS passes `node --check`. No console errors or exceptions across the run.
- The popup opens fully inside the simulated screen, without covering the panel, on Left, Right, Top, Bottom and
  Minimal at 1440 px wide, and on Left, Right, Top and Minimal at 760 px (Bottom wasn't rerun at 760 px). Search
  takes focus on open. No cards overflow horizontally.
- Keyboard: typing filters the list ("haiku" leaves 2 rows). The first Escape clears the search, the second closes
  the popup and returns focus to *View all*. ↓ moves into the rows, Enter expands a row, and an empty search shows
  a "no matches" state. Filters give 2 / 12 / 17 of the sample rows.
- Takeover on the top bar grows the bar to 420 px and pushes the other window down. Escape restores the 56 px bar.
- Two bugs were found and fixed. The popup was positioned from mid-animation panel geometry and overlapped the
  panel on a narrow right edge. Focus also dropped out of the search field when the browser window resized.
- Previews: `openrouter-widgets-preview-popup-left.png`, `-narrow-right.png`, `-takeover-top.png`.
- Not tested: Safari or WebKit, a screen reader, and anything native (focus, windows, energy). See §9.

### Always-left addendum (second QA run)

The always-left side surface was added to the sketch as the default mode, with *Overlay / Reserve space* and
*Right panel: own edge / Strictly left* toggles. Headless Chrome, scripted over the DevTools protocol:

- **36 runs, all passing.** The cases were left regular, left compact, minimal, right regular and right compact
  (each with mirrored and strictly-left surfaces), top and bottom bars, each with overlay and reserve space, at
  1440×860 and 760×900. Each run checked:
  - the surface sits flush to its edge, at full height minus the bar, and is never narrower than the panel;
  - search is focused and the trigger is marked open;
  - **the panel's frame and scroll don't change while open**;
  - windows move only in reserve mode when the surface spawns or widens;
  - an outside click doesn't close it;
  - typing filters, the first Escape clears, the second closes, and focus returns to *View all*;
  - after closing, the panel frame, scroll position (60 px, tested), widget markup and other window's frame
    **exactly match** their state before opening.
- **Regressions:** the anchored popup and in-place takeover still open and focus. No console errors.
- **Sketch bugs found and fixed:**
  - focusing search mid-slide scrolled the clipped stage by 3 px (`preventScroll`);
  - returning focus to *View all* scrolled the panel from 60 to 225 px (`preventScroll`). The same rule is
    written into the native spec;
  - the title wrapped at standard width (now truncates).
  The first run's failures were the test measuring mid-animation; it now waits for animations to settle.
- **Previews:** `openrouter-widgets-preview-side-minimal-widened.png` and
  `openrouter-widgets-preview-side-bottom-spawned.png`.
- Not tested: native focus, occlusion, Spaces, displays and energy. The HTML can't show any of these.
