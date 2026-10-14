# Adding a widget

1. `SidelightCore/Configuration/WidgetSettings.swift`: add a case to `WidgetKind` and to `WidgetSettings`. If the
   widget has options, add a `<Name>Settings` struct and handle it in `WidgetInstance+Codable.swift`.
2. Create `Sources/Sidelight/Widgets/<Name>/` with:
   - `<Name>Widget.swift`: a `WidgetMetadata` (`static let <name>`), the view (takes `WidgetLayout`, handles all
     four layouts), and a settings editor if it has options.
   - `<Name>Service.swift` if it needs live data (see the wiring rules in SKILL.md).
   - Optional styles (looks), like the clock's digital / analog / pixel faces: a `<Name>Style` enum plus a
     `style` field on its settings, with each style's own options in its own struct kept side by side. One face
     view per style (`<Style><Name>Face.swift`). Describe each style as a `WidgetStyle` (title, summary,
     `StyleFamily`, search keywords) and add the kind to `WidgetKind.styles` and `WidgetSettings.styleID` in
     `Widgets/Framework/WidgetStyle.swift`; the inspector's picker and browser come for free. If the widget
     shows the time, draw it through `WidgetClock` so catalog previews and hidden panels don't tick. Widgets
     with one look skip all of this.
   - Widgets with many pieces (several sources, lists, totals) are built from blocks instead of piling up
     options: a `WidgetBlockKind` enum and a `BlockLayout` in their settings (see `RailwaySettings`), and a
     `BlockBuiltWidget` conformance with each block's options, presets and any blocks that can be added more
     than once. Block options are form `Section`s; widget options are rows of one, shared with the Widgets
     window, with rarely changed ones in an `ExpandableRow(title: "Advanced")`. Longer explanations go behind an
     `InfoLabel`, not in captions. The builder window (`Builder/`) comes for free; add the kind to
     `WidgetSettings.blockBuilt` and `WidgetBuilderWindow`. Fetch only what the shown blocks need.
3. Add the case to the switches in `Widgets/Framework/WidgetViews.swift` and `WidgetMetadata.swift`.
4. If it signs in to a provider, it uses accounts (see SKILL.md): add the provider to `AccountProvider`, save an
   `account: AccountID?` in its settings, and let the Accounts pane and `AccountKeySheet` add keys for it.
5. If it has a service: make it a `DataService`, create it in `AppController`, add it to `AppEnvironment` and its
   `dataServices`, and start/stop it in `AppController.runServices(for:)`.
6. Give it, and any option you add to a widget later, a non-default value in
   `Tests/SidelightCoreTests/ReleasedConfigurationFixture.swift`, so the next release's saved configuration
   covers it.
7. `make check`, then look at it in all four sizes in the Widgets window (`make dev`).

The compiler flags every switch that's missing the new case.
