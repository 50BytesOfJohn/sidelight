# App Launcher widget: v1 implementation plan

Status: plan, ready to build. Research: the summary from the previous agent, plus the checks below, which were run on
macOS 27.0.1 (26A434) on 2026-10-17 with throwaway Swift probes (not committed).

Goal: a compact grid of app icons that open apps with one click, show which are running, and offer the Dock's
everyday actions on right-click. A small tile opens a searchable list of every app in the details panel. It must cost
nothing while nothing launches or quits: no polling, no timers, no periodic wakeups.

## Scope

**In v1**

- Pinned apps in a grid. Click opens the app, or brings it forward if it's running (like a Dock click). ⌘-click
  shows it in Finder.
- Running indicator: a dot under each pinned app that's running, menu-bar (accessory) apps included.
- Optional "running apps not in the launcher" after a divider, like the Dock's right-hand part. Off by default.
- Right-click menu: New Window (with Accessibility access, see fact 5), Show/Hide, Quit, Force Quit (with ⌥), Show in
  Finder, Remove from Launcher / Keep in Launcher, All Apps….
- An "All apps" tile, or "+N" when apps overflow, that opens the details panel: search, In Launcher / Running /
  All, keyboard (↑ ↓ ↩), pin and unpin, and the same row menu.
- Drag-and-drop of `.app` bundles from Finder onto the widget, at the drop position. It costs nothing at idle
  (fact 7).
- Customisation: icon size, spacing, columns (auto or fixed), row limit, a separate count for the bar, names under
  icons (regular only), and toggles for the dot and the All-apps tile.
- All four layouts, plus the details panel.

**Phase 2** (spike and measure first; see "Badges" below): unread badges, as an opt-in marked experimental.

**Deferred** (don't build): reordering by dragging inside the widget (the settings editor reorders in v1); folders,
files and URLs as items; Dock-style stacks; "Show All Windows" (no public API); "Open at Login" for other apps (not
possible with `SMAppService`); highlighting the frontmost app (needs a wakeup on every app switch); per-app
"Options" (assign to desktop, etc.).

## Pushback and decisions (read first)

1. **Badges aren't v1.** They're possible, and more cheaply than the research thought: no Accessibility, no Dock
   scraping (fact 3). But nothing notifies on changes, so they need polling plus a private LaunchServices call. The
   vision says "measure before adding anything that polls." Ship v1 without them, then do a timed spike. Details
   in "Phase 2".
2. **"New Window" can be general after all, with Accessibility.** No API asks an app for its Dock menu. But nearly
   every app has a "new window" item in its menu bar, and Accessibility can find and press it (fact 5). Sidelight
   already asks for Accessibility (window avoidance, Stash), so this adds no new prompt. Without access, the item
   is hidden, never a prompt from a context menu. A ranked match is needed, not a title search: in kitty, "New
   Window" is a split, and the real thing is "New OS Window" on ⌘N.
3. **Drag-and-drop goes in v1.** Drop targets cost nothing until a drag enters the window (fact 7). Dragging to
   *reorder* inside the widget is deferred: it competes with click-to-open, and the settings list does it.
4. **"Grid size" means auto-fit plus limits, not a fixed rows×columns matrix.** Panel width varies by display and
   preset (fact 8). The grid fits as many columns as the width allows at the chosen icon size. "Columns" can
   pin a number, and "Rows" caps the height. A fixed matrix would clip on narrow displays and waste space on wide
   ones.
5. **Open through Launch Services, never `NSRunningApplication.activate`.** Sidelight is never active behind its
   panel. As `SessionHost.bringForward` notes, an app that isn't active can't hand activation over directly.
   `NSWorkspace.openApplication(at:configuration:)` launches *or* activates, and sends the reopen event, so an
   app with no windows opens one, as a Dock click does. One code path for both.
6. **The "small icon" is a tile in the grid, not a header button.** The card header belongs to `WidgetCard`, and
   titles can be turned off. A tile shows in all four layouts and looks the same everywhere.
7. **Scan folders for the details panel; don't use Spotlight.** `NSMetadataQuery` keeps a live query (and works
   badly when indexing is off). A shallow scan takes 60–230 ms off the main actor (fact 6), once per open.

## Verified facts that shape the design

1. **Launch notifications only cover regular apps.** `NSWorkspace.didLaunchApplicationNotification` fired for a
   regular app and **not** for `.accessory` or `.prohibited` ones (menu-bar apps, LSUIElement). KVO on
   `NSWorkspace.shared.runningApplications` (`[.old, .new]`) fired for all of them, adds and removes. So: KVO is
   the source of truth.
2. **Activation policy at insertion can be wrong.** A probe app appeared in KVO as `.prohibited` and became
   `.regular` a moment later. `didLaunchApplication` fired after it became regular. So pinned apps match by bundle
   URL / bundle ID, never by policy. The "running apps not in the launcher" list (regular apps only) re-reads on
   `didLaunchApplication` too.
3. **Badges are readable without Accessibility.** A probe that set `NSApp.dockTile.badgeLabel = "3"` showed up
   in its LaunchServices record as `"StatusLabel"={ "label"="3" }` (`lsappinfo info -long <ASN>`, ~0 ms).
   `-only StatusLabel` returned NULL (don't use it). `lsappinfo listen +all` showed **no** notification when the
   badge changed, so reading it means polling. `lsappinfo list` doesn't include badges.
4. **Idle churn is zero.** With 99 running apps (9 regular, 57 accessory, 33 prohibited), two minutes of KVO plus
   notifications recorded **0** events. Chrome's 11 renderer helpers show up as one "Google Chrome Helper
   (Aperitif)" entry, so opening tabs doesn't trigger KVO.
5. **Menus over Accessibility.** Reading an app's whole menu bar took 55–110 ms (Finder 111, Chrome 55, Zed 59,
   kitty 56). What matched:
   - Finder: `New Finder Window` ⌘N (mods 0). Chrome: `New Window` ⌘N, `New Incognito Window` ⌘⇧N.
   - Zed: `New` ⌘N (a new file), `New Window` ⌘⇧N.
   - kitty: `New OS Window` ⌘N, `New Window` ⌘↩ (a split, not an OS window).

   Matching rule in fact 5's tests and in `NewWindowMenu` below.
6. **App folders.** A shallow scan (depth ≤ 2, skipping package contents) of `/Applications`,
   `/System/Applications`, `~/Applications` and `/System/Library/CoreServices/Applications` found 193 apps in 30 ms
   cold / 12 ms warm. Reading bundle IDs took 118 / 29 ms, display names 80 / 19 ms, and 50 icons 49 / 12 ms. So:
   scan `@concurrent`, never on the main actor. Don't also list `…/Utilities` as a root, or depth 2 lists it
   twice (dedupe by standardized path anyway). Different copies of one app share a bundle ID (Xcode and
   Xcode-beta are both `com.apple.dt.Xcode`), so identity is the path first.
7. **Drop targets.** SwiftUI's `.dropDestination(for: URL.self)` registers dragged types on the hosting view once.
   AppKit calls it only while a drag session is over the window, and that works while Sidelight isn't active
   (`AppearanceSettingsPane` already uses it). Nothing is scheduled at idle. Verify in manual check 2 anyway.
8. **Room per layout** (from `WidgetDensity.presetWidth`, `PanelColumns.maximumColumnWidth` = 420,
   `WidgetCard` padding and `PanelMetrics.barThickness` = 44):

   | Layout | Column | Content width |
   |---|---|---|
   | regular | 272–420 | 244–392 (padding 14) |
   | compact | 168–196 | 148–176 (padding 10) |
   | minimal | 64–72 | 56–64 (padding 4) |
   | bar | 44 tall | chip height ~44 |

9. **The config store diffs arrays by `"id"`** (`ConfigurationStore.values(in:)`). If a pinned app had no `id`, one
   unreadable entry would shift every later index, and the next save would back the file up as "unsupported". So
   each pinned app has an `id`.
10. **An older Sidelight can't read a config containing a new widget kind.** It fails to decode, and the file is
    moved aside. This is the existing policy for every new kind (Docker included): downgrades aren't supported.
    Nothing to do; just don't promise otherwise.

## Files

### SidelightCore (no AppKit/SwiftUI; everything `Sendable`, all tested)

`Sources/SidelightCore/Configuration/AppLauncherSettings.swift`

```swift
/// One pinned app. Found by its path first, then by its bundle identifier, so a moved or renamed app is still found
/// and two copies with one identifier (Xcode, Xcode-beta) stay two.
public struct LauncherApp: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID                    // fact 9
    public var path: String                // standardized absolute path of the .app, as pinned
    public var bundleID: String?           // nil for the rare app without one
    /// Its name when pinned, shown while it can't be found.
    public var name: String
    public init(id: UUID = UUID(), path: String, bundleID: String?, name: String)
    // init(from:): id, path and name required; bundleID decodeLeniently. An entry that can't be read is dropped by
    // the settings' lenient array, not the whole widget.
}

public enum LauncherSpacing: String, Codable, CaseIterable, Identifiable, Sendable {
    case tight, regular, roomy
    public var points: Double     // 4, 8, 12 (compact uses ×0.75, rounded)
}

public struct AppLauncherSettings: Codable, Hashable, Sendable {
    public static let iconSizeChoices = [24, 28, 32, 40, 48, 56]
    public static let iconSizeRange = 16...64
    public static let columnRange = 0...12        // 0: as many as fit
    public static let rowRange = 0...12           // 0: every app
    public static let barCountRange = 1...20

    public var apps: [LauncherApp] = []
    /// Regular layout. Compact draws min(iconSize, 28), minimal 32 (or 28 when the column is narrow), and the bar 24.
    public var iconSize = 32
    public var spacing = LauncherSpacing.regular
    public var columns = 0
    /// Rows shown in regular and compact. Also caps the minimal layout's single column.
    public var rows = 0
    /// Icons in the bar layout, before the All-apps tile.
    public var barCount = 8
    /// Names under icons, in the regular layout only.
    public var showsNames = false
    public var showsRunningIndicator = true
    /// Running apps that aren't pinned, after a divider, as the Dock shows them.
    public var showsRunningApps = false
    public var showsAllAppsTile = true

    // init(from:): every field decode(_:or:) / decodeLeniently; numbers clamped to their ranges;
    // apps = decodeLeniently([LenientElement<LauncherApp>]).compactMap(\.value), then deduplicated (see `adding`).

    /// Adds apps not already pinned (same path, or same bundle ID and that path no longer exists), at `index` or at
    /// the end. Returns how many were added.
    @discardableResult public mutating func add(_ apps: [LauncherApp], at index: Int? = nil) -> Int
    public mutating func remove(_ id: LauncherApp.ID)
    public mutating func move(fromOffsets: IndexSet, toOffset: Int)
    public func isPinned(path: String, bundleID: String?) -> Bool
}
```

Default for a new widget: `apps = []`. The empty state helps the person add apps (see Layouts). Previews draw a
sample (`AppLauncherSettings.sample`: Finder, Safari, Terminal, Mail, Notes, Calendar, Music, System Settings,
with system paths; they exist on every Mac).

`AppLauncherDemand` (same file, as `DockerDemand` sits in `DockerSettings.swift`):

```swift
public struct AppLauncherDemand: Equatable, Sendable {
    /// A launcher widget, or its details panel, is on screen.
    public var isShown = false
    /// Pinned apps across every shown launcher. Accessory apps are tracked only if pinned (keeps redraws to what's shown).
    public var pinned: Set<LauncherAppKey> = []
    /// Unpinned regular apps are listed somewhere (a widget with showsRunningApps, or the details panel).
    public var listsRunning = false
    public var isEmpty: Bool { !isShown }
    public mutating func merge(_ other: AppLauncherDemand)
}
public struct LauncherAppKey: Hashable, Sendable { public var path: String; public var bundleID: String? }

extension AppConfiguration {
    public func appLauncherDemand(of widgets: some Sequence<WidgetInstance>) -> AppLauncherDemand
}
```

`Sources/SidelightCore/AppLauncher/RunningApps.swift`: the pure matching, so the service stays thin.

```swift
/// What Sidelight knows about one running app, copied off `NSRunningApplication` (which isn't a value).
public struct RunningAppInfo: Hashable, Sendable, Identifiable {
    public var id: Int32                  // pid
    public var bundleID: String?
    public var path: String?              // bundleURL, standardized
    public var name: String
    public var isRegular: Bool            // activationPolicy == .regular, read at publish time
    public var isHidden: Bool
    public var launchDate: Date?
}

public struct RunningApps: Hashable, Sendable {
    public var apps: [RunningAppInfo]     // launch order
    /// Path match first. If the pinned path no longer exists (`pathExists` false), the bundle ID matches instead.
    public func instances(of app: LauncherApp, pathExists: Bool) -> [RunningAppInfo]
    public func isRunning(_ app: LauncherApp, pathExists: Bool) -> Bool
    /// Regular apps none of `pinned` matches, launch order, without Sidelight itself.
    public func unpinned(excluding pinned: [LauncherApp], ownBundleID: String?) -> [RunningAppInfo]
    /// Only what `demand` can show: regular apps, plus non-regular ones whose key is pinned. Comparing two filtered
    /// values decides whether to publish.
    public func filtered(for demand: AppLauncherDemand) -> RunningApps
}
```

`Sources/SidelightCore/AppLauncher/LauncherGrid.swift`: all layout arithmetic, so it's tested and views only draw.

```swift
public struct LauncherGrid: Equatable, Sendable {
    public struct Input: Sendable {
        public var width: Double; public var iconSize: Double; public var spacing: Double
        public var fixedColumns: Int   // 0 = auto
        public var rowLimit: Int       // 0 = none
        public var itemCount: Int      // pinned (+ unpinned running, which come after a divider)
        public var showsAllAppsTile: Bool
        public var labelHeight: Double // 0 without names
    }
    public var columns: Int           // ≥ 1; fixed columns are reduced to what fits (never clips)
    public var visibleItems: Int      // items drawn before the tile
    public var overflow: Int          // items hidden; > 0 turns the tile into "+N"
    public var showsTile: Bool        // the All-apps or +N tile
    public var cellSize: Double       // the column width actually used, centring the grid
    public init(_ input: Input)
    /// Where a drop at `point` (in grid coordinates) would insert, between 0 and visibleItems.
    public func insertionIndex(at point: CGPoint) -> Int
    /// Single row (bar) / single column (minimal) helpers.
    public static func bar(count: Int, limit: Int, showsAllAppsTile: Bool) -> LauncherGrid
    public static func column(count: Int, rowLimit: Int, showsAllAppsTile: Bool) -> LauncherGrid
}
```

Rules: `columns = max(1, floor((width + spacing) / (iconSize + spacing)))`, with `fixedColumns` kept when it fits.
When the tile is shown it takes the last cell. On overflow the tile becomes "+N" and replaces the last app cell, so
there's never a lone tile on a new row just for the button.

`Sources/SidelightCore/AppLauncher/AppCatalog.swift`: the details panel's list of every app.

```swift
public struct CatalogApp: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String; public var bundleID: String?; public var name: String
    public var folder: CatalogFolder   // .applications, .system, .user, .coreServices, .elsewhere (only running)
}
public enum AppCatalog {
    /// /Applications, /System/Applications, ~/Applications, /System/Library/CoreServices/Applications.
    public static func defaultRoots(home: URL) -> [URL]
    /// Depth ≤ 2, skipping package contents and hidden files, deduplicated by standardized path, sorted by
    /// localizedStandardCompare. Reads Info.plist via Bundle(url:) and the name via FileManager.displayName.
    @concurrent public static func scan(_ roots: [URL], fileManager: FileManager = .default) async -> [CatalogApp]
    /// Running apps not found in any root (an Xcode build in DerivedData, an app in ~/Downloads), as .elsewhere.
    public static func merging(_ scanned: [CatalogApp], running: [RunningAppInfo]) -> [CatalogApp]
}
public struct AppSearch: Sendable {
    public init(_ text: String)     // case- and diacritic-insensitive
    /// Name prefix, then word prefix ("code" → "Visual Studio Code"), then substring, then bundle ID substring.
    public func ranked(_ apps: [CatalogApp]) -> [CatalogApp]
}
```

`Sources/SidelightCore/AppLauncher/NewWindowMenu.swift`: which menu item means "new window" (fact 5).

```swift
public struct MenuItemInfo: Hashable, Sendable {
    public var title: String; public var commandKey: String?; public var modifiers: Int  // AXMenuItemCmdModifiers
    public var isEnabled: Bool; public var path: [Int]    // indexes from the menu bar, to press it again
}
public enum NewWindowMenu {
    /// Enabled items only, skipping the Apple menu. In order:
    /// 1. ⌘N with no other modifiers, whose title contains "Window" (Finder, Chrome, kitty's "New OS Window").
    /// 2. An item titled exactly "New Window" whose shortcut key is N, with any modifiers (Zed's ⌘⇧N). kitty's
    ///    "New Window" is ⌘↩ (a split) and never gets here, because rule 1 already matched its "New OS Window".
    /// 3. ⌘N with no other modifiers, whatever its title ("New", "New Document"): what the app calls new.
    /// Titles containing "Tab", "Incognito", "Private" or "Split" never match any rule.
    /// Returns nil when none matches; the action then just brings the app forward.
    public static func best(in items: [MenuItemInfo]) -> MenuItemInfo?
}
```

Title words are English. In other languages, rules 1 and 2 find nothing and rule 3 (⌘N, no other modifiers) takes
over. That's the right item in Finder, Chrome and kitty in any language, and "New" in Zed. Keep the title words in
one list so translations can be added later.

Wiring in Core (the compiler flags every switch that's missing the case):

- `WidgetKind.appLauncher` (raw value `"appLauncher"`, appended last), `WidgetSettings.appLauncher(AppLauncherSettings)`,
  `kind`, `defaults(for:)`, and both switches in `WidgetInstance+Codable.swift`.
- `AppConfiguration.swift`: `ServiceDemand.appLauncher: AppLauncherDemand` (an init parameter defaulting to empty).
  `serviceDemand(…)` fills it from `appLauncherDemand(of: visible)`; with `previewsEveryWidget`, from
  `appLauncherDemand(of: widgets)` with `isShown = true` (observing running apps is harmless; nothing is read that's
  private). `limited(to:)` clears it without `.appLauncher`. Add `.appLauncher` to the exhaustive switches in
  `sessionProviders(of:)` and `UsageServiceDemand.init(widgets:)`, and in `Accounts.swift` (~285; no account).
- `Log.appLauncher` (category `app-launcher`).

### App target: `Sources/Sidelight/Widgets/AppLauncher/`

**First, a small refactor (its own commit):** move `StashAppIcons` out of `StashWidget.swift` into
`Sources/Sidelight/Support/AppIcons.swift` as `enum AppIcons` with `icon(for bundleID:)`, `icon(atPath:)`,
`name(for:)` and `invalidate(path:)`. Stash keeps calling it under the new name. Both widgets share one cache, keyed
by path (by bundle ID for Stash's lookups). It holds pinned apps only, a few dozen. The details panel uses its own
cache (below).

**`AppLauncherService.swift`**: `@Observable final class AppLauncherService: DataService`.

```swift
struct Source {    // injected through AppComposition for tests; .workspace in the app
    var snapshot: () -> [RunningAppInfo]
    /// Calls `changed` on the main actor on every runningApplications KVO change and every didLaunchApplication.
    var observe: (_ changed: @escaping () -> Void) -> Observation   // .cancel()
    static let workspace: Source
}
private(set) var running = RunningApps(apps: [])       // published only when the filtered value changes
private(set) var launching: Set<LauncherApp.ID> = []   // for the launch pulse
var demand = AppLauncherDemand() { didSet { if demand != oldValue { publish() } } }
func resolve(_ app: LauncherApp) -> ResolvedApp         // .found(URL, pathExists:), .missing
```

- `start()`: `guard observation == nil`. Observe through `source.observe { publish() }`, then `publish()` once
  (the initial snapshot; facts 1, 2, 4). `NSWorkspace` KVO changes arrive on the main run loop, so
  `MainActor.assumeIsolated` in the observer, as `NoodleComputerService` does.
- `publish()`: `snapshot()` (about 99 apps, microseconds) → `RunningApps.filtered(for: demand)` → assign only if
  different. An unpinned menu-bar app launching publishes nothing.
- `stop()`: cancel the observation and the launch watchdogs. Keep `running`: it's re-read on the next `start()`
  anyway, so no stale state shows for more than a frame.
- `resolve`: `FileManager.fileExists(path)`, with the bundle ID checked against `Bundle(path:)`, else
  `NSWorkspace.urlForApplication(withBundleIdentifier:)`. Cache per `LauncherApp.ID`, cleared when `demand.pinned`
  changes and on `start()`, so a moved or deleted app is noticed when the panel shows again. Never on every draw.
- When a pinned app *launches*, also `AppIcons.invalidate(path:)` for it: apps usually relaunch after updating, which
  is when their icon changes.

**`AppLauncherActions.swift`**: everything that touches another app, in one place (views never call `NSWorkspace`
directly here).

```swift
enum AppLauncherActions {
    /// Launches or brings forward (decision 5). Marks `launching` until the call returns, with a 10 s DelayedTask
    /// watchdog. On failure: NSSound.beep() and a .notice log (path at .debug only).
    static func open(_ url: URL, id: LauncherApp.ID, service: AppLauncherService)
    static func reveal(_ url: URL)                          // activateFileViewerSelecting
    static func hide(_ instances: [NSRunningApplication]) / unhide / quit / forceQuit
    /// Finds the item with NewWindowMenu.best and presses it (kAXPressAction), then brings the app forward with
    /// open(…). Not running: open(…) alone. Runs off the main actor (@concurrent) with the existing 1 s messaging
    /// timeout, so a hung app can't freeze the panel. No match: open(…) alone.
    static func newWindow(_ app: NSRunningApplication?, url: URL, id: LauncherApp.ID, service: AppLauncherService) async
}
```

Add `menuItems` (a walk to `[MenuItemInfo]`) and `press(path:)` to `AccessibilityElement`, which already caps
messaging at 1 s. Order: press first, then open. Pressing a menu item works while the app is in the background.
Bringing it forward afterwards puts the new window in front. Check this in manual check 7; if an app ignores a
press while in the background, swap the order for it.

**`AppLauncherWidget.swift`**: `WidgetMetadata.appLauncher`, `AppLauncherSettings.summary`, `AppLauncherWidgetView`,
and the empty and missing states.

```swift
extension WidgetMetadata {
    static let appLauncher = WidgetMetadata(
        title: "App Launcher", systemImage: "square.grid.3x3.fill", tint: .indigo,
        summary: "Your apps, one click away",
        details: "Opens apps, and brings running ones forward, like the Dock. Running apps get a dot. Sidelight "
            + "is told when apps open and quit, and never checks on a timer. New Window uses Accessibility, like "
            + "window avoidance does.")
}
```

Category `.essentials`. Summary line: "8 apps · 6 columns", "8 apps · auto", "Empty". In `WidgetStyle.swift`,
`BlockBuiltWidget.swift` and `WidgetBuilderWindow.swift`, add `.appLauncher` to the "no styles / not block-built"
lists. In `WidgetViews.swift`, add the content and settings-editor cases.

**`AppLauncherViews.swift`** (shared by widget and details):

- `LauncherIcon(app:, size:, isRunning:, isLaunching:, isMissing:, showsDot:, label:)`. The icon comes from
  `AppIcons`; the dot (3 pt at ≤ 28, 4 pt above) sits under it in `.primary.opacity(0.55)`. Launching: a
  `Motion.snappy` scale bounce, then opacity 0.6 until done (opacity only with Reduce Motion). Missing: the icon at
  0.35 with a small `questionmark.circle.fill`. Hover: `hoverHighlight`, skipped in previews (as `CardChrome` does).
  `.help(name)`. VoiceOver: a button "Safari, running" with the menu as `.accessibilityActions`.
- `AllAppsTile(overflow:)`: `square.grid.2x2` at 0.45 × icon size in a rounded square of
  `Color.primary.opacity(0.07)`, or "+N" in monospaced digits. Click → details. Disabled in previews ("Opens from
  the panel").
- `LauncherAppMenu(app:, instances:, isPinned:, …)`: built when the menu opens, from live `NSRunningApplication`
  state (`isHidden`, `NSEvent.modifierFlags` for ⌥):

  | Item | When |
  |---|---|
  | Open / Show | always (Show when running) |
  | New Window | running or not, only while `windowAvoider.isTrusted` (`AXIsProcessTrusted`) |
  | — | |
  | Hide / Show | running; "Hide Others" isn't offered |
  | Quit | running; every instance matching the path |
  | Force Quit | running and ⌥ held when the menu opened (if SwiftUI builds the menu too early to see ⌥, show it always, after a divider) |
  | Show in Finder | found |
  | Locate… | missing: `NSOpenPanel` for `.applicationBundle`, replaces path and bundle ID, keeps the id |
  | — | |
  | Remove from Launcher / Keep in Launcher | pinned / running-unpinned |
  | All Apps… | from a real panel |

- `LauncherGridView(items:, grid:, …)`: a `LazyVGrid` with `grid.columns` fixed `GridItem`s, centred, and the
  divider row before unpinned running apps (a hairline across the grid, spanning a full row).

**`AppLauncherDetailsView.swift`**: `AppLauncherBrowser` and `AppLauncherDetailsView` (see "Details panel").

**`AppLauncherSettingsEditor.swift`** (its own file, as Railway's).

## Data flow

```
AppController.observeServiceDemand
  configuration.serviceDemand(…)                  → services.appLauncher (shown launchers, pinned keys)
  + coordinator.details?.appLauncherDemand()      (isShown, listsRunning; merged like docker)
  → runServices: .appLauncher → environment.appLauncher.demand = …; setRunning(!demand.appLauncher.isEmpty)

AppLauncherService
  runningApplications KVO ─┐
  didLaunchApplication ────┴─▶ publish(): snapshot → filtered(for: demand) → running (if changed)
  open/newWindow ─▶ launching (until done, 10 s watchdog)

AppLauncherWidgetView(settings, layout)
  service.running + service.resolve(app) + LauncherGrid(width from GeometryReader-free layout, see Layouts)
  drop (URLs) ─▶ store.configuration.updateWidget(placement.widgetID) { settings.add(…, at: index) }
```

Changes outside the folder:

- `AppEnvironment`: `let appLauncher: AppLauncherService`, in `dataServices` and in `environment(_:)`.
- `AppController`: create `AppLauncherService(source: composition.appLauncherSource ?? .workspace)`. Merge the details
  panel's demand next to Docker's. Add an `.appLauncher` case in `runServices`.
- `AppComposition`: `var appLauncherSource: AppLauncherService.Source? = nil`.
- `DetailsSession.swift`: `DetailsRequest.appLauncher(widget: WidgetInstance.ID, scope: LauncherScope)` and
  `DetailsContent.appLauncher(AppLauncherBrowser)` (title "Apps", kind `.appLauncher`). `adopts` returns true for the
  same widget and keeps the search, taking the new scope. `handlesKey` goes to the browser.
  `appLauncherDemand() -> AppLauncherDemand` returns `isShown: true, listsRunning: true, pinned: <that widget's>`
  for its content and empty otherwise. **This is what keeps running dots live while the details panel covers the
  panel.**
- `DetailsPanelView.DetailsContentView`: a `.appLauncher(let browser)` case.
- `StashWidget.swift`: use `AppIcons`.

## Layouts

Icon sizes: regular `settings.iconSize`, compact `min(iconSize, 28)`, minimal 32 (28 when the content width is
< 60), bar 24. Spacing: `settings.spacing.points` (×0.75 in compact, 4 in the bar). Widths come from fact 8. Read
the real width once with `onGeometryChange(for: Double.self)` on the grid container, and feed `LauncherGrid`.
It changes only when the panel resizes, so there's no redraw loop. Before the first measurement, use the
layout's smallest width.

- **Regular**: the grid, `LauncherGrid(width:, iconSize:, spacing:, fixedColumns: columns, rowLimit: rows, …)`.
  With `showsNames`, a 10 pt name under each icon (one line, middle truncation, cell width), in secondary.
  Unpinned running apps (with `showsRunningApps`) after a hairline, same size, no names, and counted against the
  row limit after the pinned apps. The tile is last.
- **Compact**: the same grid, smaller (no names). About 4–5 columns at 28 pt.
- **Minimal**: `LauncherGrid.column`: one icon per row up to `rows` (0 = every app), then the tile. Unpinned
  running apps are left out (no room for the divider to read clearly).
- **Bar**: `LauncherGrid.bar`: a row of `barCount` 24 pt icons with their dots (2 pt gap), then the tile. No
  unpinned running apps. The tooltip names the app.
- **Empty** (no apps pinned, in a real panel): regular and compact show `WidgetMessage("No apps yet", detail:
  "Drop apps here, or choose some from All Apps.", "square.grid.3x3")` with an action "Choose Apps…" that opens the
  details panel at All. Minimal and bar show just the tile, with that tooltip.
- **Previews** (`isWidgetPreview`): `AppLauncherSettings.sample` when `apps` is empty, otherwise the widget's apps.
  No drop target, no menu actions, tile disabled. Running dots are real (not private).
- **Drop target** (real panels only, every layout): `.dropDestination(for: URL.self) { urls, location in … }
  isTargeted: { isTargeted = $0 }`.
  - Keep URLs whose `contentType` conforms to `.applicationBundle`; resolve symlinks and Finder aliases first.
  - Insert at `grid.insertionIndex(at: location)`, or at the end in the bar and minimal.
  - Skip apps already pinned. Return false (and beep) when nothing was added.
  - While targeted, draw a 1.5 pt `WidgetMetadata.appLauncher.tint` rounded outline and a gap at the insertion
    index (`Motion.snappy`). This is the only animation, and it runs only during a drag.

## Details panel (`AppLauncherDetailsView`)

`@Observable final class AppLauncherBrowser`: `widgetID`, `search`, `scope: LauncherScope` (`.pinned`, `.running`,
`.all`; it opens at `.pinned`, or `.all` from the empty state), `selection: CatalogApp.ID?`, `catalog: [CatalogApp]?`
(nil while scanning), an icon cache `[String: NSImage]` that lives and dies with the browser, and `scanTask`.

- On appear: start `AppCatalog.scan(defaultRoots)` and keep the task. When it finishes, merge running apps
  (`AppCatalog.merging`). Show "Looking for apps…" until then; the Pinned and Running scopes don't wait for it.
  The details content is released on close (`window.contentView = nil`), so the browser's `deinit` cancels the
  task and frees the icons. Nothing keeps running after close.
- Controls, styled like `DockerDetailsView`: the search field (focused on open) and a segmented "In Launcher N |
  Running M | All K".
- Rows (`LazyVStack`): a 24 pt icon (loaded lazily on appear into the browser's cache), the name, and in secondary
  the folder when two apps share a name ("Xcode · /Applications/Xcode-beta.app"). Then the running dot, and a
  trailing button: `plus.circle` to pin to the widget that opened it, `checkmark.circle.fill` to unpin. Click opens.
  Right-click is `LauncherAppMenu`.
- Pinned scope: the launcher's order, with drag-to-reorder (`.onMove` in a `List`). This is the one place reordering
  happens outside settings, and it's cheap: it's only alive while the panel is open.
- Keyboard (`handlesKey`): ↑/↓ move the selection, ↩ opens the selected app (or the first result) and closes the
  panel, ⌘↩ shows it in Finder, and Esc keeps its current meaning (close). Typing focuses search. This makes the
  panel a small keyboard launcher too.
- Empty states: "No apps match “x”", "Nothing running", "No apps in this launcher" (button: Show All).
- Pinning writes through `ConfigurationStore` to `browser.widgetID`. If that widget was removed meanwhile, the
  buttons hide.

## Settings editor (`AppLauncherSettingsEditor`)

- **Apps**: a `List` of the pinned apps (icon, name, "Not found" in orange for missing ones) with `.onMove`, a
  minus button per row, "Add Apps…" (`NSOpenPanel`, `.applicationBundle`, multiple, starting in `/Applications`, as
  `StashExcludedApps` does) and "Choose from All Apps…" (opens the details panel; enabled when the widget is placed).
- **Icon size**: a picker over `iconSizeChoices`; a hand-edited value outside them shows as "N pt (custom)".
- **Spacing**: segmented Tight / Regular / Roomy.
- **Columns**: "Fit" or 1–12 (stepper with a Fit toggle). **Rows**: "All" or 1–12. **In the bar**: 1–20.
- Toggles: Show names (caption: regular layout), Running dots, Running apps not in the launcher, All-apps tile.
- `ExpandableRow(title: "Advanced")`: an `InfoLabel` explaining New Window and Accessibility, with a `StatusRow`
  "New Window available / needs Accessibility access" and the button `WindowsSettingsPane` uses to grant it.

## Tests

`Tests/SidelightCoreTests/AppLauncherTests.swift` (Swift Testing, backtick names):

- `AppLauncherSettings` decoding:
  - `{}` → defaults; `iconSize` 999 → 64; `columns` −3 → 0; `rows` 99 → 12; an unknown `spacing` → `.regular`.
  - `apps` with one malformed entry keeps the others in order; a duplicate path is dropped.
  - Round trip.
- `add`: dedupes by path, and by bundle ID when the pinned path no longer exists; inserts at an index; reports the
  count. `move` and `remove`.
- `RunningApps`:
  - A path match; the bundle-ID fallback only when the path doesn't exist.
  - Xcode and Xcode-beta (one ID, two paths) stay distinct.
  - An app without a bundle ID matches by path; a pinned accessory app counts.
  - `unpinned` lists regular apps only, in launch order, without Sidelight.
  - `filtered` drops unpinned non-regular apps, and two filtered values are equal when only those changed.
- `LauncherGrid` (parameterized over fact 8's widths × sizes 24…56 × spacing):
  - Auto columns; fixed columns reduced when they don't fit.
  - The row limit with overflow (the tile becomes +N in the last app cell); no lone tile row.
  - The tile off; `column` / `bar`.
  - `insertionIndex` at cell centres, gaps, past the end and before the start.
- `AppCatalog.scan` on a temporary folder of fake `.app` directories with `Info.plist`s:
  - Depth 1 and 2 are found; a nested `.app` inside a package is skipped; hidden files are skipped.
  - A missing root is fine; a symlinked root is deduped; sorting is natural ("App 2" before "App 10").
  - `merging` adds running-only apps as `.elsewhere`.
- `AppSearch`: case and diacritics; prefix before word prefix before substring; bundle ID matches
  ("microsoft" → VS Code).
- `NewWindowMenu.best` with the fixtures from fact 5 (Finder, Chrome, Zed, kitty) plus Safari ("New Window" ⌘N),
  Terminal ("New Window" submenu → ⌘N "Basic"; expect rule 3 or nil, decide while building), a disabled item, and
  an app with nothing → nil.
- Demand:
  - A visible launcher → `isShown` and its pinned keys; a hidden one → empty.
  - `previewsEveryWidget` → shown.
  - `limited(to:)` without `.appLauncher` → empty; `merge`.
- `ReleasedConfigurationFixture`: add a launcher with non-default values (two apps, one without a bundle ID,
  `iconSize: 40, spacing: .roomy, columns: 5, rows: 2, barCount: 6, showsNames: true, showsRunningIndicator: false,
  showsRunningApps: true, showsAllAppsTile: false`) and a default one, shown in the side panel only. Don't
  regenerate an existing release file.

`Tests/SidelightTests/AppLauncherServiceTests.swift` with a fake `Source` (a scripted snapshot and a `changed`
trigger):

- `start` twice → one observation; `stop` cancels it; `start` after `stop` publishes the current snapshot at once.
- An unpinned accessory app appearing → no publish (count assignments); a pinned one → publish.
- A policy flip (`.prohibited` → `.regular`) on a later `changed` → the unpinned list updates (fact 2).
- `launching` clears on completion and on the watchdog.
- `resolve`: a moved app is found by bundle ID; a deleted one → `.missing`; the cache clears when `pinned` changes.

## Manual checks (before merging; record results in the PR)

1. `make check` passes. All four layouts look right in the Widgets window (`make dev`), with the sample, at icon sizes
   24/32/56 and widths minimal…420.
2. **Idle cost:** three launcher widgets on two displays, panel visible, 10 minutes untouched. Activity Monitor shows
   Sidelight's idle wake-ups unchanged from a build without the widget (note both numbers), and ~0 % CPU.
   Then drag a file over the panel and away: no lasting wake-ups.
3. Click a pinned app while another app is in front → it comes to the front. Click Safari or Finder with no windows
   open → a window opens (reopen event). Click while it's launching → no second launch.
4. Pin a menu-bar app (e.g. Raycast, Rectangle) → its dot follows quit and relaunch. Open and close 20 Chrome tabs
   with `log stream --predicate 'category == "app-launcher"' --level debug` → no publishes.
5. Drag `.app`s from Finder onto each layout, at the start, middle and end; drag a document → rejected with a
   beep; drag while another app is active.
6. Hide/Show, Quit, Force Quit (⌥) on a running app; with two instances of one app.
7. **New Window** in Finder, Safari, Chrome, Terminal, Zed, kitty and Xcode, both while running in the background
   and while not running. Record which item was pressed, and whether the window came to the front. With
   Accessibility revoked, the item isn't shown.
8. Details: opening with 200+ apps feels instant (scopes before the scan finishes). Search, ↑↓↩, pin and unpin
   update the widget behind. Close → memory footprint drops back (Xcode Memory Graph or `footprint`), and no task
   remains.
9. Move a pinned app to another folder → still found; delete it → the missing state, then Locate… fixes it.
10. Icons look right on light, dark and image backgrounds, and with tinted / clear icon styles (System Settings →
    Appearance), since `NSWorkspace` icons follow the drawing appearance.
11. Update a pinned app (or just relaunch it after replacing the bundle) → its icon refreshes.

## Phase 2: badges (experimental, opt-in)

Only after v1 ships. Steps:

1. **Spike** (a day): read the badge in-process, not through `lsappinfo`. Spawning a process per app per poll would
   be the real cost. Use LaunchServices' private `_LSCopyApplicationInformationItem` (or
   `_LSCopyApplicationInformation`) with the key `StatusLabel`, looked up with `dlsym` at runtime. If a symbol is
   missing, the feature is unavailable rather than crashing. Also check whether LaunchServices offers a per-key
   change notification that `listen +all` didn't show (fact 3). If it does, there's no polling at all.
2. **If it needs polling**, poll only while all of these hold:
   - `showsBadges` is on (a new setting, default false, decoded with `or:`);
   - a launcher is shown (not hidden, not unseen);
   - at least one pinned app is running.

   Use a `RepeatingTask` every 15 s with generous tolerance (so the system can merge the wakeup with others), plus
   one read on `didDeactivateApplication` of a pinned app, which is when unread counts usually change. Read only
   running pinned apps.
3. **Measure** with the manual check 2 setup: wake-ups with badges on, versus off. If it's more than a rounding
   error, talk to Tom before shipping.
4. UI: a `CountBadge`-style capsule at the icon's top-right corner. Numbers use `CountBadge` (9+); other labels
   ("•", "!") use a new `LabelBadge` in `DesignSystem/`. `BadgeLabel(raw:)` parsing goes in Core, with tests.
   Label the option "Badges (experimental)" with an `InfoLabel` saying how it works.
5. The fallback, if the SPI is gone in a future macOS: the Dock's `AXStatusLabel` over Accessibility. It needs
   access and polls the same way.

## Edge points (collected)

- Same bundle ID, two copies (Xcode/Xcode-beta): path first everywhere (running, quit, icon).
- App moved or renamed: found by bundle ID; the stored path is **not** rewritten silently (it would mark the file
  "changed" on every launch). It's rewritten when the person uses Locate….
- App deleted: missing state, kept in the list, with Locate… or Remove.
- Apps without a bundle ID: path only; no New Window fallback by ID.
- Accessory apps: running dot yes, "running apps not in the launcher" no (Dock semantics).
- Policy changes after launch: handled by re-reading on `didLaunchApplication`. A regular → accessory change at
  runtime (rare) is picked up on the next event.
- Sidelight itself never appears in the running list.
- Launch failures (damaged, quarantined and declined, wrong architecture): beep and log; no sticky error UI.
- Gatekeeper's first-launch dialog appears over the panel as usual; the launch pulse ends via the 10 s watchdog.
- Hung apps: AX calls are capped at 1 s and run off the main actor; menus never read AX while building.
- The details panel open: it alone keeps the service running when the panel is covered.
- Hidden panel or locked screen: the service stops (no observers at all); on show, one snapshot.
- Multiple displays: one service, every widget reads the same `running`.
- Config hand edits: clamped numbers and dropped malformed apps back up the file once as "unsupported", as today.
- Previews never edit config (no drop, no pin, disabled tile).
- Localisation: New Window matching leans on ⌘N, not titles alone.
- VoiceOver: each icon is a button with name and state, and menu actions are reachable as accessibility actions.

## Implementation order (one PR, these commits)

1. `AppIcons` shared cache (Stash unchanged in behaviour).
2. Core: settings, demand, `RunningApps`, `LauncherGrid`, `AppCatalog`, `NewWindowMenu`, all with tests.
3. Service, wiring, widget layouts with running dots, empty state, previews.
4. Settings editor and drop target.
5. Menu and actions, including New Window over Accessibility.
6. Details panel.
7. Released-config fixture entry; manual checks; metadata `isBeta: false` (nothing undocumented in v1).

## Product notes for Tom

- The details panel with ↩-to-open is close to a mini Raycast. A global shortcut "Open All Apps" (through
  `HotkeyCenter`, like the Stash shortcuts) would make it one. It's cheap to add later; worth deciding after you've
  used v1 for a week.
- `WindowAvoider` and `NoodleComputerService` each observe launches themselves. Once `AppLauncherService` exists,
  Noodle could read from it. It's not worth doing for its own sake.
- With "running apps not in the launcher" on, this widget can stand in for an auto-hidden Dock. That's a strong
  pitch for the gallery's description, if you like it.
- Folders and URLs as launcher items are the natural v2. The settings model leaves room: a new optional field per
  item, decoded with `or:`, with no migration.
