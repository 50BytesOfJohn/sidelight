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
     shows the time, draw `@Environment(\.frozenDate)` when it's set so catalog previews don't tick. Widgets
     with one look skip all of this.
3. Add the case to the switches in `Widgets/Framework/WidgetViews.swift` and `WidgetMetadata.swift`.
4. If it has a service: create it in `AppController`, add it to `AppEnvironment`, and start/stop it in
   `AppController.runServices(for:)`.
5. `make check`, then look at it in all four sizes in the Widgets window (`make dev`).

The compiler flags every switch that's missing the new case.
