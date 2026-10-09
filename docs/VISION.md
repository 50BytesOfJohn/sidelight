# Sidelight: vision

## Why it exists

Developers now work with a lot of AI agents, sources and calendars at once, and much of it happens in parallel.
A big office screen has room to spare, so a small part of it can become an always-on display of what matters
right now.

macOS's native widgets don't fit this. Apps like [CoolDock](https://cooldock.app/) come close, but they're paid
and not quite what's needed.

## Who it's for

General-purpose, but focused on developers and built with them in mind.

## Built for AI agents too

Agents are first-class users:

- Agents can connect to Sidelight and push things to it (e.g. "agent finished", "needs your input").
- Agents should be able to build custom widgets for their users.
- Developer platforms keep shipping CLIs made for agents (Railway, Vercel, …). Sidelight can use the same CLIs
  for its integrations and widgets.

Examples of what it should show: new messages from agents, new mail, deploy and platform status, and other
developer-platform integrations.

## Principles

- **Aesthetics matter a lot.** It should be highly customizable: backgrounds, effects, motion. Looking great is a
  core feature, not a finish.
- **Performance.** It runs all the time, so idle cost must stay close to zero. Measure before adding anything
  that polls, animates continuously or redraws often.
- **Native, Apple Silicon only.** We chose native macOS over web or Tauri for performance and platform
  integration. No Intel, no cross-platform layer.
- **The panel is always visible.** Window management keeps other windows out from under it, and it should work
  well alongside keyboard-driven and tiling workflows (shortcuts, Rectangle and similar).
