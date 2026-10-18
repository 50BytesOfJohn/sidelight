# Sidelight

Native macOS (Apple Silicon only) side panel / bar of always-on widgets, general use, but with more focus aimed at developers. It runs all the time, so idle performance is critical. Aesthetics and customization (backgrounds, effects, motion) are core features. Full context: `docs/VISION.md`.

- Build with `make`, not raw `swift build`: it points `DEVELOPER_DIR` at Xcode, and SwiftUI macros need that.
- Done = `make check` passes: lint, zero warnings, tests.
- Never wait a fixed time in a test. `make check` runs the suite once on an idle machine, so a wait a loaded CI runner outruns passes here and fails there. Wait for something with `eventually { }`, and use `settle()` before asserting something didn't happen (both in `Tests/SidelightTests/TestSupport.swift`; `make lint` enforces this). `make stress` reruns the suite under load, which may shake out a rarer flake but can't prove the absence of one.
- Commits, PRs and the contributor workflow: `CONTRIBUTING.md`.
- Signing, notarization, Sparkle updates and cutting a release: `docs/RELEASING.md`.
- Try changes in the real app with `make dev` (Ctrl-C quits).
- Preserve settings shipped in published releases. Changes to `config.json` must keep released configurations readable or explicitly migrate them, so an automatic app update doesn't reset someone's panel. Unreleased names and APIs can still change freely. Invalid or corrupt configurations are moved aside automatically.
- Same for UI: when something new doesn't fit the current design (e.g. the settings layout), rethink and redesign it rather than force-fitting or patching around it.

## Working together

I'm new to Swift and native macOS, so act as a product partner, not just an implementer. Speaking up is always welcome.

- If a request seems off, conflicts with the vision, or has a clearly better alternative, pause and say so before building it. Propose what you'd do instead.
- Mention improvements and ideas you notice along the way, even unasked. Keep them short and concrete; I decide.
- When a Swift or macOS choice isn't obvious, explain it in a sentence so I learn.
