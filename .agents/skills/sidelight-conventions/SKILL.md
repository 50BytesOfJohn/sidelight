---
name: sidelight-conventions
description: Sidelight project conventions - where code goes and how services and widgets are wired. Use when writing, changing or reviewing Swift code in this repo, or adding a widget or service.
paths: Sources/**, Tests/**, Package.swift
---

# Sidelight conventions

## Where code goes

- Doesn't need AppKit or SwiftUI → `SidelightCore`, with tests. Everything else → the app target.
- App target is MainActor by default, so don't write `@MainActor`. `SidelightCore` is nonisolated; its types are `Sendable`.
- One folder per widget: `Widgets/<Feature>/` holds its service and its views.

## Wiring

- No singletons. `AppController` creates long-lived objects; views get them through `AppEnvironment`.
- Services are `@Observable` and conform to `DataService` (`start()`/`stop()`, safe to call twice).
  `AppController.runServices(for:)` runs a service only while a widget on a panel someone can see (not hidden,
  and not on a sleeping or locked screen for over a minute), or the Widgets window, needs it.
- Timing comes from the primitives in `Services/`, owned by the service and stopped in `stop()`: `RepeatingTask`
  for a sweep or sample, `CoalescedReload` to turn bursts of file events into one read, `FetchSchedule` for
  fetching from a provider with backoff, `RemoteResource` for a fetched value with its problem, `Retry-After` and
  daily-UTC timing (one per kind of data, shared by every widget showing it), `PacedTask` for a loop whose every
  run picks the next wait, `DelayedTask` for one run later (a debounce, a retry, a watchdog). No `Timer`, no Combine, no hand-rolled
  `Task { sleep; … }`. After every `await`, check `Task.isCancelled`
  and publish nothing once it's set.
- File and network work runs off the main actor: `@concurrent` functions, `HTTP.send`, `Keychain`
  (other apps' items), `KeychainItem` (a secret typed into Sidelight, never in `config.json`). Watch files
  with `FileWatcher` / `FileEventStream` (their `onMainActor` initializers).

## Data and UI

- JSON from `codex` or `media-control`: decode with the helpers in `LenientDecoding.swift`, so one odd field
  breaks one value, not the whole payload.
- Session widgets list sessions with the shared `SessionList`, `SessionRow` and tally views in
  `Widgets/Framework/SessionViews.swift`; their status types conform to `SessionStatusDisplay`.
- Views that show the time draw it through `WidgetClock`, which freezes in catalogs and stops in hidden panels.
- Settings decode with `decode(_:or:)` (a missing key takes its default) or `decodeLeniently(_:or:)` (an
  unreadable value does too), and clamp hand-edited numbers into the range the UI offers.
- Animations come from `Motion`, usage colors from `Color.usage(percent:)`, logging goes through `Log.<category>`.

## Adding a widget

Follow [adding-a-widget.md](adding-a-widget.md).
