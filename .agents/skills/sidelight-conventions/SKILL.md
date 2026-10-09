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
- Services are `@Observable` with `start()`/`stop()` that are safe to call twice. `AppController.runServices(for:)`
  runs a service only while a visible widget needs it.
- Periodic work is a `Task` loop owned by the service and cancelled in `stop()`. No `Timer`, no Combine.

## Data and UI

- JSON from `codex` or `media-control`: decode with the helpers in `LenientDecoding.swift`, so one odd field
  breaks one value, not the whole payload.
- Animations come from `Motion`, usage colors from `Color.usage(percent:)`, logging goes through `Log.<category>`.

## Adding a widget

Follow [adding-a-widget.md](adding-a-widget.md).
