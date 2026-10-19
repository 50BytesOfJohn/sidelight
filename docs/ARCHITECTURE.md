# Architecture

How Sidelight's code is laid out and how data moves through it. To build and run it, start with
[CONTRIBUTING.md](../CONTRIBUTING.md).

## Source tree

```
Sources/
  SidelightCore/          UI-free domain logic. Foundation only, nonisolated, Sendable, fully unit-tested.
    Configuration/        AppConfiguration, PanelSection, WidgetSettings, Appearance, Hotkey; the config.json schema
    Panel/                Panel geometry and how sections share its length
    Imaging/              Image-effect patterns (Bayer dither, ASCII ramp), desktop-picture crop geometry
    Geometry/             Where a window may go (WorkArea), and the order its frame is written in (pure functions)
    Avoidance/            Window-avoidance geometry, reservations, placement intents (pure functions)
    WindowManager/        Window-manager tiles, display order and size cycling (pure functions)
    Codex/                codex app-server JSON-RPC session, rollout-file parser, usage models
    ClaudeCode/           Claude plan limits per account (each a Claude Code folder) and signing accounts in through Claude Code
    ClaudeSessions/       Claude Code's live session registry, transcript titles, links back into a session
    AgentSessions/        One session shape for every agent, so one widget lists them together
    Cursor/               Cursor's included-usage pools from its dashboard endpoint (opt-in), sign-in, chat list
    OpenCode/             OpenCode 2's session list, read-only from its database
    Usage/                Rate-limit windows: pace forecast, reset rollover; refresh backoff
    NowPlaying/           media-control stream state + diff merging
    System/               CPU/memory sampling
    Process/              ChildProcess (process groups, line streaming), file watchers, ProcessRunner, ProcessTable
    Support/              Logging, formatting
    <Integration>/        The other widgets' models and parsers: Docker, Railway, OpenRouter, Stash, …
  Sidelight/              The app. AppKit + SwiftUI, main-actor isolated by default.
    App/                  Entry point, AppDelegate, AppController (composition root), menus
    Configuration/        ConfigurationStore (persistence, hot reload), user-facing names
    Panel/                The panel window, its frame/animations, root view, backgrounds
    Details/              The full-height details panel a widget opens in place of the side panel
    Displays/             Connected displays and their desktop pictures
    Windows/              Widgets manager + Settings window lifecycle, links between them
    WindowAvoidance/      Accessibility observers and access, the one writer of window frames, Rectangle
    WindowManager/        Shortcuts that tile the frontmost window
    Hotkey/               Global shortcuts (Carbon)
    Manager/              Widgets window: active list, gallery, inspector
    Builder/              The block editor for widgets built from blocks
    Accounts/             Signed-in accounts and their secrets
    Services/             Shared pieces for data services: fetch schedules, paced and delayed tasks
    Settings/             Settings window
    Updates/              Sparkle updater, automatic checks and gentle reminders
    Widgets/
      Framework/          WidgetLayout, metadata, WidgetCard chrome, content/settings dispatch
      <Feature>/          One folder per widget: its data service and its views
    DesignSystem/         Motion, colors, reusable components (rings, bars, badges, …)
    Support/              Alerts, System Settings deep links, activation helper
Tests/
  SidelightCoreTests/     Swift Testing suites for SidelightCore
  SidelightTests/         Tests for the app target
  ReleaseTests/           Tests for the release scripts
```

## Data flow

`AppController` builds every service once and hands them to SwiftUI through the environment (`AppEnvironment`).
`ConfigurationStore` is the single source of truth. Views bind to it directly, and `AppController` observes it
(`Observations`) to drive the parts outside SwiftUI: the panel frame, hotkeys and window avoidance.

`AppController` also runs each data service only while a widget that needs it is visible, or while the Widgets
window, which previews all of them, is open. The Codex, Claude Code and Cursor services each run once for their
own widget and any AI Usage widget showing them. They fetch on a timer only for visible widgets that opted in.

## Configuration

Everything is stored in `~/Library/Application Support/Sidelight/config.json`, and Sidelight applies edits to
the file live. If the file doesn't decode, Sidelight moves it to `config.invalid-<date>.json` and starts from
defaults. Updates keep configurations from published releases readable, migrating them when needed.

## Logs

Sidelight writes to the unified log:

```sh
log stream --level debug --predicate 'subsystem == "app.getsidelight.Sidelight"'
```

## Releases

Packaged releases use Developer ID signing and Apple notarization, and installed copies update through Sparkle.
[RELEASING.md](RELEASING.md) has the release workflow and credentials.
