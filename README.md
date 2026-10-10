# Sidelight

[![CI](https://github.com/50BytesOfJohn/sidelight/actions/workflows/ci.yml/badge.svg)](https://github.com/50BytesOfJohn/sidelight/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 26+, Apple Silicon](https://img.shields.io/badge/macOS-26%2B%20%C2%B7%20Apple%20Silicon-black?logo=apple)

A native macOS side panel (or top/bottom bar) of glanceable widgets: clock, Codex, Claude Code and Cursor usage
(each on its own, or side by side in one AI Usage card), calendar, now playing, Claude Code sessions and system stats. Other apps' windows are moved or shrunk so they never sit
under the panel. Why it exists and where it's going: [docs/VISION.md](docs/VISION.md).

Requires an Apple Silicon Mac with macOS 26. Download the latest DMG from
[GitHub Releases](https://github.com/50BytesOfJohn/sidelight/releases/latest), open it and drag Sidelight to
Applications. Building from source needs Xcode 26.4+ (Swift 6.2+ toolchain).

## Getting started

```sh
make run      # build build/Sidelight.app (release, signed) and launch it
make test     # unit tests
make check    # lint + build + test, what CI runs
```

On first launch macOS asks for **Accessibility** access (needed to move other apps' windows). Optional tools:

| Widget               | Needs                                                                 |
| -------------------- | --------------------------------------------------------------------- |
| Codex                | `codex` CLI (`brew install codex`); falls back to `~/.codex/sessions` |
| Claude Code          | Pro or Max plan; live limits via its status line (widget settings)    |
| Cursor               | Signed-in Cursor app or `cursor-agent`; turn on fetching (settings)   |
| AI Usage             | What each agent it shows needs (above), set up in its own settings    |
| Now playing          | `brew install ungive/media-control/media-control`                     |
| Calendar             | Calendar access, requested from the widget                            |
| Claude Code sessions | A recent Claude Code; to open terminal tabs, macOS asks once per app  |

Packaged releases use Developer ID signing and Apple notarization. Installed copies check for updates through
Sparkle; update settings and a manual check are in **Settings → General → Updates**. The menu bar also has
**Check for Updates…**. Maintainers: see [docs/RELEASING.md](docs/RELEASING.md) for the release workflow and credentials.

## Configuration

Everything is stored in `~/Library/Application Support/Sidelight/config.json`. Edits to the file are applied
live. A file that doesn't decode (including one written by an older build with a different shape) is moved to
`config.invalid.json` and replaced with defaults. Future updates preserve configurations from published releases.

Logs go to the unified log:

```sh
log stream --level debug --predicate 'subsystem == "app.getsidelight.Sidelight"'
```

## Architecture

```
Sources/
  SidelightCore/          UI-free domain logic. Foundation only, nonisolated, Sendable, fully unit-tested.
    Configuration/        AppConfiguration, PanelSection, WidgetSettings, Appearance, Hotkey; the config.json schema
    Panel/                Panel geometry and how sections share its length
    Imaging/              Image-effect patterns (Bayer dither, ASCII ramp), desktop-picture crop geometry
    Avoidance/            Window-avoidance geometry (pure functions)
    Codex/                codex app-server JSON-RPC session, rollout-file parser, usage models
    ClaudeCode/           Claude plan limits from the status line, ~/.claude.json and the opt-in usage endpoint
    ClaudeSessions/       Claude Code's live session registry, transcript titles, links back into a session
    Cursor/               Cursor's included-usage pools from its dashboard endpoint (opt-in), sign-in reading
    Usage/                Rate-limit windows: pace forecast, reset rollover; refresh backoff
    NowPlaying/           media-control stream state + diff merging
    System/               CPU/memory sampling
    Process/              ChildProcess (process groups, line streaming), file watchers, ProcessRunner, ProcessTable
    Support/              Logging, formatting
  Sidelight/              The app. AppKit + SwiftUI, main-actor isolated by default.
    App/                  Entry point, AppDelegate, AppController (composition root), menus
    Configuration/        ConfigurationStore (persistence, hot reload), user-facing names
    Panel/                The panel window, its frame/animations, root view, backgrounds
    Windows/              Widgets manager + Settings window lifecycle, links between them
    WindowAvoidance/      Accessibility observers, Rectangle integration
    Hotkey/               Global shortcut (Carbon)
    Manager/              Widgets window: active list, gallery, inspector
    Settings/             Settings window
    Updates/              Sparkle updater, automatic checks and gentle reminders
    Widgets/
      Framework/          WidgetLayout, metadata, WidgetCard chrome, content/settings dispatch
      <Feature>/          One folder per widget: its data service and its views
    DesignSystem/         Motion, colors, reusable components (rings, bars, badges, …)
    Support/              Alerts, System Settings deep links, activation helper
Tests/
  SidelightCoreTests/     Swift Testing suites for SidelightCore
```

**Data flow.** `AppController` builds every service once and hands them to SwiftUI through the environment
(`AppEnvironment`). `ConfigurationStore` is the single source of truth; views bind to it directly, and
`AppController` observes it (`Observations`) to drive the parts outside SwiftUI — panel frame, hotkey, window
avoidance — and to run each data service only while a widget that needs it is visible (or the Widgets window,
which previews all of them, is open). The Codex, Claude Code and Cursor services each run once for their own widget and
any AI Usage widget showing them, and fetch on a timer only for visible widgets that opted in.

## Contributing

Contributions are welcome: bug reports, widget ideas, fixes and new widgets. Start with
[CONTRIBUTING.md](CONTRIBUTING.md) for setup and the fork-and-pull-request workflow. Project conventions and the
add-a-widget checklist live in the [`sidelight-conventions`](.agents/skills/sidelight-conventions/SKILL.md) agent
skill; [AGENTS.md](AGENTS.md) holds the rules that apply to every change. Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md), and report security issues privately as described in
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
