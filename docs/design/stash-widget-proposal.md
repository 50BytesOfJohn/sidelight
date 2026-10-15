# Stash widget: design proposal

Status: **proposal, agreed in direction, not implemented.** Date: 2026-10-15. Branch `design/stash-widget`,
base `9b5d6ca`. "Stash" is a working name.

Inspired by [Copper](https://shadcn.com/copper): a to-do list, clipboard and scratchpad for AI-assisted work.
You capture a selection with a shortcut, queue prompts you'll use next, copy them into Claude, Codex or Cursor,
and check them off. Everything stays local. Brainstormed with GPT-6.1-Sol as a second opinion.

---

## 1. In one paragraph

A widget that shows the next few things you stashed, with **Copy**, **Done** and **Copy & Done** on each, and a
details panel that holds the full list with search, filters, editing and reordering. Items come in through a
global **capture-selection** shortcut, an **add-clipboard** shortcut, or the **+** button. Organisation is pins
and search only. No AI, sync or clipboard history in v1.

## 2. The item

| Field       | Notes                                                                 |
| ----------- | --------------------------------------------------------------------- |
| `id`        | Stable UUID.                                                          |
| `text`      | Plain text. The first line is the title.                              |
| `createdAt`, `updatedAt` |                                                          |
| `source`    | Bundle ID of the app it came from, shown as that app's icon. Optional. |
| `pinned`    | Pinned items sort first and never get marked done: reusable snippets. |
| `state`     | `open` or `done` (with `doneAt`). Done items can be reopened.         |
| order       | Position in the queue, changed by dragging in the details panel.      |

Copying never marks an item done; only **Done** or **Copy & Done** does.

## 3. Storage

- Items live in their **own versioned file**, `~/Library/Application Support/Sidelight/stash/items.json`, not in
  `config.json`. The list changes constantly; settings need careful migration (see `AGENTS.md`). Keeping them
  apart keeps both simple.
- Atomic writes, one writer (the app). A corrupt file is moved aside, like `config.json`.
- One shared store for every display and every Stash widget instance.
- `config.json` holds only the widget's display choices (how many items to show, show done, and so on).

## 4. Capture

The panel never takes keyboard focus (`PanelController.canBecomeKey` is `false`), so capture happens through
global shortcuts and the details panel, never by typing into the widget.

1. **Capture selection** (global shortcut, configurable). Reads the focused app's selected text through
   Accessibility, which Sidelight already has for window avoidance. It doesn't switch apps. A short "Saved"
   message with **Undo** confirms it; if the app exposes no selection, say so instead of failing silently.
2. **Add clipboard** (global shortcut and a button). Reads the pasteboard once, on request. Fallback for apps
   whose selection Accessibility can't read.
3. **+ button.** Opens the details panel focused on a new-item editor. Esc returns to the previous app.

Shortcuts go through `HotkeyCenter` (Carbon `RegisterEventHotKey`, no extra permission).

## 5. Widget and details panel

**Widget**: 3–5 open items (configurable), pinned first, then queue order. One or two lines per item, source app
icon, and hover actions **Copy**, **Done**, **Copy & Done**. Footer: "+12 more", opening the details panel.
An empty state explains the capture shortcut.

**Details panel** (new `DetailsRequest.stash`): the whole list.

- Search across text.
- Filters: Open / Done / All, plus Pinned.
- Edit text inline, pin, reorder by drag, delete.
- Keyboard first: arrows to move, ⌘C copy, ⏎ done, ⌘⌫ delete, ⌘N new, Esc close. While editing, ⌘C copies
  text as usual.
- Closing returns focus to the app you came from.

## 6. Housekeeping and privacy

- Done items are deleted N days after they're done (default 7, or never), so the list stays clean and
  `items.json` stays small on its own. Pinned items are never done, so they stay. Checked when the stash loads,
  changes or its panel opens, never on a timer.
- Never capture from secure text fields. Per-app exclusions (e.g. password managers).
- Never log item text.
- **Zero idle cost:** no polling, no clipboard watching, no continuous animation. Only shortcuts, clicks and
  file writes cause work.

## 7. Later, in rough order

1. **Agents add items.** A small CLI, `echo "…" | sidelight add --project foo`, so an agent can drop next steps
   into the queue. Pushed text is data, never instructions. Fits `docs/VISION.md` directly.
2. **Double-Shift capture**, as an option. Copper's signature, but it needs an always-on modifier-key monitor
   (`flagsChanged`), unlike normal shortcuts, and must avoid accidental triggers.
3. **Smart filters** by rule, no AI: Prompts, Links, Code.
4. **AI tag suggestions** with Apple's on-device Foundation Models: one or two tags, chosen from tags you
   already use, shown as chips to accept. It never files things by itself, is off where Apple Intelligence is
   unavailable, and any cloud model would be explicit opt-in.
5. An optional **project** field, if real use shows it's needed.

## 8. Not in v1

AI, sync and accounts, clipboard history, images and OCR, due dates, nested tasks, automatic pasting, guessing
the current repo, double-Shift.

## 9. Open questions

- Name: Stash, Queue, Scratch, something else?
- Default capture shortcuts.
- Should the widget show one item large (the "next prompt") or a short list?
