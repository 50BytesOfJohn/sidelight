# SidePanel PoC: native Swift (SwiftUI + AppKit)

Everything is in `~/Desktop/sidepanel-poc/native/`. As of round 3 the code is structured as a seed for the real app (about 3,100 lines in 25 files under `Sources/SidePanel/`):
- `App/`: entry point and menus, panel controller, window coordinator, hotkey.
- `Core/`: Codable config with hot-reload, child-process spawning, logging.
- `Services/`: data models and window avoidance.
- `Widgets/`: the widget protocol, registry and card chrome, plus one file per widget.
- `UI/`: panel root, widget manager, settings, theme.

**The build needs Xcode's toolchain** (from round 2 on), because the macOS 26 SDK's SwiftUI `@State` is a macro whose plugin isn't in the Command Line Tools. `build.sh` picks Xcode automatically and **fails loudly on compile errors**. Before round 3 it silently bundled the previous binary; see round 3 DX notes.

## Build & run

```bash
cd ~/Desktop/sidepanel-poc/native
./build.sh                      # swift build -c release + assemble build/SidePanel.app + codesign
open -n build/SidePanel.app     # menu bar icon "sidebar.left" appears, panel on the left edge of the primary screen
# use `open -n` when relaunching quickly: plain `open` may reuse a still-quitting instance and drop --args
```

`build.sh` signs with the first `Developer ID Application` / `Apple Development` identity it finds. Here that is
*Developer ID Application: Tomasz Szczuciski (2BJN73MG88)*, without hardened runtime. The designated requirement is
`identifier "io.mynth.sidepanel.native" and ... leaf[subject.OU] = "2BJN73MG88"`, so **TCC grants (Accessibility,
Calendar) survive rebuilds**. This was verified: Accessibility kept working after two rebuilds. Without an identity, the script ad-hoc signs, and grants must then be re-done after every rebuild.

All settings live in **`~/Library/Application Support/SidePanelNative/config.json`** (round 3). Editing it by hand hot-reloads the panel. Launch arguments override some keys for tests, and are not saved:

```bash
open -n build/SidePanel.app --args -position left|right|top|bottom -size regular|compact|minimal \
     -mode glass|cards|black|image -imageCards glass|material -avoidMode off|shift|clip|smart \
     -animatedBG YES -useGlass NO -axPrompt NO -codexDemo YES
# debug/automation: -openManager YES -openSettings YES -closeManagerAfter <s> -managerSelectFirst YES
#   -managerPreviewSize regular|compact|minimal|bar -renderScreens <dir> [-renderName n] -quitAfterRender YES
#   -cycleSizes YES -cyclePositions YES -testLoginItem YES -codexForceFallback YES -cheapRing YES
```
Rounds 1 and 2 used flags such as `-showSeconds`, `-htmlWidget` and `-codexWidget`. In round 3 these are per-widget settings in config.json, edited in the Widgets window.

Other files:
- `scripts/measure.sh <seconds> [label]`: CPU/RSS/energy sampler (see method below). `scripts/measure-all.sh` runs every state.
- `scripts/send-event.sh [status] [message] [source]`: curl POST to the agent widget. It also reads a Claude Code hook JSON payload from stdin and uses its `cwd`.
- `hooks-snippet.json`: an example `Stop` hook (plus `Notification`) for `~/.claude/settings.json`. **It is not installed.**
- `tools/respid.c`: helper that lists the responsible PID of every process (used by `measure.sh`). `tools/testwin.swift`: opens a window over the panel to test avoidance.
- Logs: `avoidance.log` and `launch.log` in this folder are **symlinks** (round 3 adds `frames.log` and `config.log` in the same folder) to `~/Library/Logs/SidePanelNative/`. The app writes to `~/Library/Logs` because writing into `~/Desktop` from an app bundle triggers the "access Desktop folder" TCC prompt.
- Test the agent widget: `curl -XPOST http://127.0.0.1:47821/event -d '{"source":"claude-code","status":"finished","message":"hi"}'`

## Permissions the user must grant

| Permission | How it is requested | Behaviour while not granted |
|---|---|---|
| Accessibility (window avoidance) | `AXIsProcessTrustedWithOptions(prompt: true)` at launch (suppress with `-axPrompt NO`). The menu item "Grant Accessibility…" opens System Settings → Privacy & Security → Accessibility | Panel works and avoidance is inactive. The app **polls `AXIsProcessTrusted()` every 3 s and registers observers once granted, so no relaunch is needed** |
| Calendars (full access) | "Grant calendar access" button in the calendar card → `requestFullAccessToEvents`. If already denied, it opens Privacy_Calendars in Settings | Card shows "No calendar access" and the button |
| (none) Now Playing | needs `brew install media-control` (done) | Card shows the install command if the binary is missing |

## Measurements

Machine: Apple Silicon, macOS 27.0.1, 6016×3384 primary display (3008×1692 pt). Each state was launched fresh and warmed up for 15 s, then sampled for 60 s.
The user was actively using the machine during the runs (moving windows, so AX callbacks fired), which adds a little noise.

**Method (`scripts/measure.sh`):**
- **CPU %** is the delta of cumulative CPU time from `ps -o time` per second, divided by wall-clock time (100% = one core). I did not use `ps %cpu`, because on macOS it is a decaying average.
- **RSS** comes from `ps -o rss`.
- **Footprint and energy** come from `top -stats cpu,idlew,power,mem`, run in parallel over the same PIDs. `POWER` is Activity Monitor's "Energy Impact", and `mem` is the physical footprint shown in Activity Monitor.
- **Related processes** are found in two ways. First, by the *responsible PID*: `tools/respid` calls libsystem's `responsibility_get_pid_responsible_for_pid`. This catches the WebKit WebContent, Networking and GPU XPC services, which are children of launchd rather than the app, and does not mix them up with Safari's or the Tauri app's WebKit processes. Second, by a ppid walk, which catches `perl` (media-control). The "other" group is `com.apple.audio.SandboxHelper` and `SetStoreUpdateService`, both spawned for WebKit.
- **Not counted:** WindowServer compositing cost, which matters for the animated background.

| State | Total avg CPU % | Total peak CPU % | App avg CPU % | WebKit avg CPU % | media-control avg CPU % | Total RSS avg / peak MB | Footprint (top) MB | Energy Impact avg |
|---|---|---|---|---|---|---|---|---|
| (a) idle, panel (Liquid Glass), no seconds, no anim, HTML on | **0.38** | 2.60 | 0.32 | 0.05 | 0.01 | 141 / 158 | 77 | 0.31 |
| (b) seconds ticking | **0.61** | 0.93 | 0.60 | 0.01 | 0.00 | 132 / 166 | 76 | 0.54 |
| (c) animated background (SwiftUI MeshGradient @ 30 fps) | **9.05** | 12.47 | 9.00 | 0.06 | 0.00 | 137 / 151 | 101 | 8.95 |
| (d) cards style (glass per card) | **0.35** | 1.85 | 0.32 | 0.01 | 0.01 | 153 / 159 | 77 | 0.29 |
| (e) HTML widget off (no WKWebView) | **0.25** | 1.56 | 0.24 | — | 0.02 | 84 / 99 | 31 | 0.21 |
| (f) panel, glass off → NSVisualEffectView | **0.34** | 1.86 | 0.26 | 0.06 | 0.02 | 134 / 166 | 72 | 0.23 |

Takeaways:
- At idle the whole thing costs about 0.3–0.4 % of one core. Per-second clock ticks add about 0.25 %.
- The **animated background is the only expensive feature, at about 9 % CPU in-process** plus unmeasured WindowServer/GPU work. If it is kept, it should be a Core Animation layer animation (rendered out of process) or a very low frame rate.
- **The WKWebView costs about 50–55 MB RSS (about 46 MB footprint) and 3 extra processes**, but almost no CPU. Its CSS animation is transform/opacity only, so it is composited off the main thread.
- Liquid Glass and NSVisualEffectView cost the same, and so do the panel and cards styles.
- RSS fluctuates a lot because macOS compresses idle pages. Footprint (top MEM) is the more stable number.

Raw output: `measurements.txt`.

| Other metric | Value |
|---|---|
| Clean build (`rm -rf .build && swift build -c release`) | **47 s** (first-ever build including package setup: 81 s) |
| Incremental release build (touch main.swift) | **45 s**: release is whole-module, and the module is one big SwiftUI file |
| No-op release build | 7.4 s |
| Clean / incremental debug build | 44 s / 2.6 s |
| `./build.sh` (build + bundle + codesign), incremental | about 40 s |
| `.app` bundle size | **544 KB** (541 KB unstripped binary; the Swift runtime ships with the OS) |
| Launch → panel visible (process start → after `orderFront` + `CATransaction.flush`, from `launch.log`) | 556–936 ms warm (556 ms without WebKit). The very first launch after signing took 1891 ms (Gatekeeper assessment) |

## Window avoidance

The implementation works like this:
- NSWorkspace launch, activate and terminate notifications drive one `AXObserver` per regular app. Each observer watches `kAXWindowCreated`, `Moved`, `Resized` and `Miniaturized` on the app element.
- If an app is not yet AX-ready right after launch, registration is retried up to 10 times at 0.5 s intervals.
- Existing windows are checked as soon as an app is registered.
- The fixer skips the app's own windows, non-`AXStandardWindow` subroles, `AXFullScreen` windows and minimized windows.
- If the left mouse button is held (the user is dragging or resizing), the fix waits until mouse-up instead of fighting the drag.
- Each fix is logged with mode, action, event, `delay_ms` (from AX callback, or first callback before mouse-up, to fix complete), and the from/to AX frames.

Avoidance modes (menu → Avoidance mode; default **smart**):
- **shift**: move the window to `x = panelRight + 8` and keep its width, clamped to `visibleFrame`.
- **clip**: keep the window's right edge (`maxX`) and set `x = panelRight + 8`, so the width shrinks by the overlap. It falls back to shift if the new width would be under 40 % of the original, or if the app refuses the smaller size (its minimum width).
- **smart**: use clip if the window's left edge is within 2 px of `visibleFrame.minX`, which means it was snapped or maximized by Rectangle, macOS tiling or the green button. Otherwise shift, for free-floating windows dragged over the panel. This fixes the Rectangle quarter-layout problem the user reported, where shift pushed the left quarters under the right ones.

Observed in `avoidance.log` (real usage plus `tools/testwin`): fix delays are **2.6–64 ms**, typically under 10 ms for programmatic moves. Examples:
```
fix mode=smart action=shift app=testwin title="AvoidanceTest" event=AXWindowMoved delay_ms=4.7 from={{10, 910}, {900, 532}} to={{328, 910}, {900, 532}}
fix mode=smart action=clip  app=Claude  title="Claude"        event=AXWindowMoved delay_ms=36.1 from={{0, 861}, {1504, 831}} to={{328, 861}, {1176, 831}}
```

Rectangle integration (menu):
- **Print Rectangle gap command**: shows the two `defaults write` commands in an alert and copies them to the clipboard. The values are `screenEdgeGapLeft -int 328` and `screenEdgeGapsOnMainScreenOnly -bool true`.
- **Configure Rectangle for panel…**: shows a confirmation alert. On confirm, it quits Rectangle (and Rectangle Pro, `com.knollsoft.Hookshot`, if installed), waits for it to exit, writes both keys, then relaunches it.
- **Revert Rectangle config…**: does the same, but runs `defaults delete` on both keys.
- *I did not run either of these.* Whether Rectangle Pro honours the same key names is an assumption I have not verified.

### Manual test checklist

Prerequisites: Accessibility is granted to `build/SidePanel.app`, and you run `tail -f ~/Desktop/sidepanel-poc/native/avoidance.log` in a terminal.

1. **Drag a window over the panel (free-floating)**. Smart mode: on mouse-up the window jumps right to x=328 with its width unchanged, and the log shows `action=shift ... +mouseup`. Avoidance should not fight you during the drag.
2. **Green-button zoom / Option-click "fill"**: the window fills from x=328 to the right screen edge (`action=clip`).
3. **macOS tiling** (drag to the left edge, or Window → Move & Resize → Left): the window ends at x=328, right edge unchanged (`clip`).
4. **Rectangle quarters, without a gap configured, smart mode**: create top-left, bottom-left, top-right and bottom-right windows.
   - Expected: the left quarters are *clipped* (x 328 → middle) and do **not** slide under the right quarters. The right quarters are untouched.
   - The left quarters end up narrower than the right ones. That is the cost of the hack.
   - Repeat in **shift** mode to see the old overlapping behaviour, and in **clip** mode for comparison.
5. **Rectangle quarters, with the gap configured** (menu → Configure Rectangle for panel…, then confirm):
   - Rectangle now lays out halves and quarters inside 328…right edge.
   - Expected: **no log entries**, because the windows never overlap the panel. Halves and quarters are equal sizes.
   - Then revert with "Revert Rectangle config…".
6. **Fullscreen app** (green button → full screen): the window is skipped (`AXFullScreen`). The panel should appear next to or over the fullscreen Space (`fullScreenAuxiliary`). This has not been verified visually.
7. **Switch Spaces**: the panel stays (`canJoinAllSpaces` + `stationary`).
8. **Second monitor** (none was attached here): windows on other screens never intersect the panel rect, so they are untouched. The panel always sits on `NSScreen.screens[0]` (the primary, menu-bar screen), and Rectangle's gap is main-screen-only.
9. **Fix all windows now**: moves every currently overlapping window.
10. **Window avoidance off**: nothing is moved.
11. **Panel hidden** (Toggle panel): nothing is moved, because the panel rect is treated as absent.

## What worked

- Everything compiled with CLT-only SwiftPM on the first try. The hand-made bundle (Info.plist with `LSUIElement`, bundle id and `NSCalendarsFullAccessUsageDescription`), Developer ID signing, and persistent TCC grants all worked.
- **Non-activating borderless `NSPanel`** at `.floating` level, 320 pt wide and the full `visibleFrame` height. `CGWindowList` showed it at `{0,30,320,1662}`. Its `collectionBehavior` is `canJoinAllSpaces`, `stationary`, `fullScreenAuxiliary` and `ignoresCycle`, with no Dock icon (accessory policy).
- **Menu bar item** with all requested items, plus Clock seconds, HTML widget, Liquid Glass toggle, Avoidance mode, Grant Accessibility, and Configure/Revert Rectangle.
- **Liquid Glass**: SwiftUI `.glassEffect(.regular, in:)` is available at runtime (`glassAvailable=true` on macOS 27) and is the default for both panel and cards styles. `-useGlass NO` falls back to `NSVisualEffectView` (`.hudWindow`, behind-window). See below for what I could not verify visually.
- **Window avoidance via AX**: works, confirmed on the user's real windows and on the test window, with millisecond-level delays.
- **Agent HTTP server**: Network.framework `NWListener` bound to `127.0.0.1:47821` only (checked with `lsof`). `POST /event` returns `{"ok":true}`, and the list keeps the latest 10 entries with relative time refreshed every 30 s.
- **Now Playing**: spawns `media-control stream` and parses the JSON lines (`{"type":"data","diff":bool,"payload":{…}}`, merging diffs), including base64 artwork. The artwork rendered (a Chrome YouTube tab was the source). Grandchild perl processes are killed on quit.
- **System stats**: `host_statistics` CPU ticks delta, VM stats memory, and the app's own RSS, every 2 s (timer tolerance 0.2 s).
- **Clock**: `TimelineView(.everyMinute)`, or `.periodic(by: 1)` only when seconds are on.
- **WKWebView card**: loads `Contents/Resources/widget.html` with a transparent background. It has a CSS pulse animation, JS-computed content, and a `fetch` to open-meteo.com.

## Failed, hacky, or unverified

- **I could not take screenshots**, because the agent's terminal lacks Screen Recording permission (`screencapture` fails). My offscreen `cacheDisplay` snapshot (debug flag `-snapshot path.png`) confirmed the layout: cards, artwork, icons, the webview. It cannot render glass, materials or (here) text. So **the look of Liquid Glass, panel vs cards, and the animated gradient were not visually verified by me.** Please eyeball them.
- **Not verified without user interaction:**
  - that clicking the panel doesn't steal focus (it should not: `nonactivatingPanel` with `canBecomeKey=false`);
  - that the "Grant calendar access" button works in a non-key panel;
  - calendar event listing (access is not granted);
  - the fullscreen-Space behaviour;
  - the menu items, which I can't click. Rectangle configure/revert was deliberately never run.
- **Smart mode is a heuristic.** A window placed at x=0 by the user is treated as "snapped" and gets clipped. Clipping also makes Rectangle's left quarters narrower than the right ones. The proper fix is the Rectangle gap. macOS's own tiling has no gap setting, so clip is the best available there.
- **Avoidance is reactive**, so a window briefly appears under the panel before it is fixed (one frame to ~60 ms). Some apps animate their own frames and may produce two fixes. Electron, Chrome and other apps with odd AX trees were not tested individually.
- **Animated background** in SwiftUI `TimelineView` + `MeshGradient` at 30 fps costs about 9 % CPU. It is the obvious thing to rewrite (CAGradientLayer + CABasicAnimation, or a Metal shader compiled at runtime) if it should stay.
- **`responsibility_get_pid_responsible_for_pid`** used by the measurement helper is private libsystem API. It is fine for a dev tool, not for shipping.
- **Logs** go to `~/Library/Logs/SidePanelNative/` with symlinks in this folder, to avoid the Desktop-folder TCC prompt.
- **Launch time of about 0.6–0.9 s** is slower than expected for a native app. Most of it is probably the synchronous creation of EventKit, WebKit and the process spawn before the first frame. This was not profiled, and could be cut by deferring model and WebKit setup until after `orderFront`.

## Developer-experience notes (no Xcode)

**Easy:**
- SwiftPM executable target, plus an about-25-line `build.sh` that copies the binary and Info.plist into a bundle and runs `codesign`. That is all an LSUIElement app needs.
- No asset catalogs, storyboards or entitlements were required, because hardened runtime is off. With hardened runtime on (needed for notarization), EventKit would need the `com.apple.security.personal-information.calendars` entitlement.
- All the system APIs are first-class and well-typed in Swift: NSPanel, AX, EventKit, Network.framework, WKWebView and SwiftUI glass.
- The final bundle is 544 KB.
- Developer ID signing gave stable TCC grants across rebuilds for free.

**Fought me:**
- **Build times.** A ~800-line SwiftUI file takes about 45 s per release build, and incremental release builds are not faster (whole-module optimization). Debug incremental was 2.6 s, so iterate in debug. Splitting files or adding explicit view types would help.
- **No visual feedback loop.** Without Xcode previews and without Screen Recording permission for the agent's shell, UI work is blind. An Xcode user would not have this problem. With Xcode now installed, `#Preview` would help.
- **AX API ergonomics** are C-style: `AXValue` boxing, `CFTypeRef` casts, an Unmanaged refcon, and a non-capturing C callback. Gotchas:
  - AX coordinates are top-left of the primary screen, while Cocoa uses bottom-left.
  - AX registration fails silently for apps that are not ready yet. This was a real bug, now fixed with a retry.
  - You must not fight user drags.
- **Writing logs to `~/Desktop` from the app would trigger a TCC prompt.** I worked around it with `~/Library/Logs` and symlinks.
- **Measuring WebKit** is non-trivial, because its helper processes are launchd children. A small C helper using the private responsible-PID API was needed.
- The CLT linker prints two harmless warnings (`search path .../CommandLineTools/Developer/... not found`).
- The `metal` compiler was not needed, because no shaders are used.

---

# Round 2: Codex widget, polish, display modes

## 1. Codex usage widget

**Primary source: `codex app-server`**
- The app spawns `/opt/homebrew/bin/codex app-server` (codex-cli 0.161.0, a native binary) and speaks newline-delimited JSON-RPC over stdio.
- Handshake: `initialize` (clientInfo `sidepanel`), then the `initialized` notification.
- Then `account/rateLimits/read` and `account/usage/read`, repeated every 60 s.
- It listens for the `account/rateLimits/updated` notification (`params.rateLimits` has the same shape as the read result) and for `account/updated` (`planType`).
- Fields used:
  - `rateLimits.primary`: the 5 h window (`usedPercent`, `windowDurationMins=300`, `resetsAt` in unix seconds).
  - `rateLimits.secondary`: the weekly window (10080 min).
  - `rateLimits.planType`.
  - `rateLimitResetCredits.availableCount`.
  - `account/usage/read` → `summary.lifetimeTokens` and `dailyUsageBuckets[{startDate,tokens}]`. The widget shows today's tokens, lifetime tokens and a 14-day sparkline.
- The schema was checked with `codex app-server generate-json-schema` (`v2/GetAccountTokenUsageResponse.json`, `AccountRateLimitsUpdatedNotification.json`).
- **Only read methods are ever sent.** The `…/consume`, login/logout and thread/turn methods are never called. The method names are hard-coded in `CodexModel.readAll()`.

**Process hygiene (lesson from the media-control leak)**
- All helpers are now spawned with `posix_spawn` + `POSIX_SPAWN_SETPGROUP` (own process group) + `POSIX_SPAWN_CLOEXEC_DEFAULT`, so the child doesn't inherit the app's listening socket. A background `waitpid` reaps them so no zombies are left.
- On quit: close the child's stdin, then `killpg(pgid, SIGTERM)`. This applies to both `codex app-server` and `media-control` (which forks a second perl).
- If the app dies hard, app-server exits on stdin EOF anyway (verified in the manual handshake test).
- After about 20 launch/kill cycles today: **zero leftover codex or perl processes from SidePanel.**

**Fallback source: rollout files**
- Used if app-server can't be spawned, exits, or gives no rate limits within 15 s.
- It parses the newest `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (reading the last 512 KB) and takes the last line containing `"type":"token_count"`.
  - `payload.rate_limits.primary|secondary` (snake_case `used_percent`, `window_minutes`, `resets_at`) and `plan_type`.
  - `payload.info.total_token_usage.total_tokens`, shown as "Session".
- An FSEvents stream on `~/.codex/sessions` (2 s latency, file events) re-parses on change.
- While in fallback, app-server is retried every 5 min.
- Tested with `-codexForceFallback YES`: the card showed `rollout file`, 85 % / 28 %, PLUS and Session 9.7M.

**Caveats**
- app-server is an unofficial integration surface; method names may change between codex versions.
- Rollout data is only as fresh as your last Codex turn. It has no reset-credit count or daily buckets.
- `codex app-server` costs about **100–110 MB RSS** (avg CPU 0.2–0.3 %, with spikes to 8–10 % at startup and on the 60 s re-read). That is more memory than the whole panel (WebKit included) without it.
- Small UI label (top right of the card) shows the active source: `app-server` / `rollout file` / `unavailable`.

**UI**
- The 5 h window is an animated ring: a trim spring with conic gradient, `contentTransition(.numericText)` digits and SF Pro Rounded.
- The weekly window is a gradient capsule bar.
- "5h resets in 3h 51m" and "resets in 5d 17h" are in `TimelineView(.everyMinute)`.
- There is a PLUS plan badge, and a reset-credits count (↻ 3).
- Colour runs green → amber → red via a hue ramp.
- Above 80 %: a glow (shadow) plus a one-shot spring **pulse when the value changes** (`phaseAnimator` with `trigger:`). It never loops.

## 2. Polish
- Liquid Glass is used properly:
  - `.glassEffect(.regular)` for the single panel.
  - `.glassEffect(.regular.interactive())` per card in cards mode, inside a `GlassEffectContainer(spacing: 10)`.
  - `.regular.tint(.black.opacity(0.15))` for cards over the image.
  - `.buttonStyle(.glass)` for the calendar button.
- Typography:
  - SF Pro Rounded thin 46 pt for the clock.
  - Tracking-spaced uppercase section labels with SF Symbols.
  - SF Mono for token counts.
  - `.monospacedDigit()` everywhere numbers change.
- Motion, all event-driven:
  - staggered spring entrance of cards on appear;
  - a spring scale and border highlight on hover;
  - numeric text transitions on the clock minute and Codex numbers;
  - spring ring and bar fills;
  - agent rows insert with move+opacity and a **one-shot shimmer sweep** across the card on a new event;
  - Now Playing crossfades and slides on track change, and uses a symbol-replace transition for play/pause.
- **Idle cost of polish:**
  - Round 1 idle (a) was 0.38 % total. Round 2 glass mode with Codex off (h) is **0.96 %**: +0.6 % from polish, including the once-a-minute clock transition.
  - Codex on adds about 0.6 % (app plus codex process).
  - **Gotcha found and fixed:** my first version animated the System card (2 s refresh, a ~1.5 s spring plus numericText). SwiftUI was then *permanently* mid-animation, which cost **12–16 % CPU at idle** in every mode (`measurements-round2-before-stats-fix.txt`). Periodic data now updates without animation.

## 3. Display modes
`-mode` / menu → Style:
- **glass**: the previous single glass panel.
- **cards**: the previous floating glass cards.
- **black**:
  - #000 panel; cards #161616 (#1D1D1D on hover) with a 0.5 pt hairline of white at 7 %, radius 16.
  - Dark appearance is forced.
- **image**:
  - Uses `wallpaper.jpg`, a copy of `~/Pictures/Wallpapers/wallhaven-21zex9.jpg`, in the bundle.
  - At load, a full-height, panel-aspect slice centred at 57 % of the width (the face) is cropped and **redrawn into a small bitmap** (533×2767). The 45 MB full decode is not kept resident.
  - Aspect-fill, top-aligned, with a 45 % black overlay and a gradient from clear (top 35 %) to 90 % black at the bottom. Dark appearance is forced.
  - Card style is chosen with `-imageCards glass` (Liquid Glass, tinted) or `material` (`NSVisualEffectView` with **`.withinWindow`** blending, which blurs the in-window image, not the desktop).

## 4. Round 2 measurements
All runs: avoidance OFF (the Tauri app was running), animated background off, seconds off, HTML widget on, 15 s warm-up. Raw output: `measurements-round2.txt`.

| State | Total avg CPU % | App avg / peak % | codex app-server avg % / RSS MB | Total RSS avg / peak MB | Footprint (top) MB | Energy Impact |
|---|---|---|---|---|---|---|
| (g) glass, Codex on | **1.55** | 1.13 / 34.9 | 0.33 / 108 | 275 / 311 | 126 | 1.45 |
| (h) glass, Codex off | **0.96** | 0.91 / 34.5 | — | 153 / 164 | 77 | 0.89 |
| (i) black idle | **1.74** | 1.44 / 29.1 | 0.25 / 107 | 268 / 313 | 123 | 1.25 |
| (j) image, material cards | **1.00** | 0.77 / 24.9 | 0.22 / 98 | 277 / 367 | 136 | 0.91 |
| (k) image, Liquid Glass cards | **1.10** | 0.84 / 26.2 | 0.22 / 108 | 290 / 324 | 133 | 0.94 |
| (l) baseline, 10 s | 1.48 | 0.28 / 0.9 | 1.20 / 157 | 377 / 385 | 128 | 1.27 |
| (m) **Codex demo burst**, new random values every 1 s, 10 s | **39.4** | 38.4 / 42.4 | 0.93 / 136 | 393 / 416 | 228 | 37.6 |

- **What the numbers mean:**
  - The peaks of 25–35 % in 60 s runs are single samples: the minute-boundary clock transition, the Codex 60 s re-read, the user hovering over or moving windows near the panel. The averages are what matter.
  - **Codex widget cost:** +0.6 % CPU and about +100–120 MB RSS (≈ +49 MB footprint). Almost all of it is the `codex app-server` process.
  - **Image mode:** the app's RSS rises from about 80 to 93–95 MB (+13–15 MB for the cropped bitmap and its layers). CPU is the same as the other modes, and Liquid Glass vs within-window material cards cost about the same.
  - **Transition animations are expensive when they run back to back:**
    - A change every second keeps SwiftUI animating almost continuously. That costs **about 38 % of a core in glass mode and about 51 % in black mode** (the 15 s spot check `-mode black -cheapRing YES -htmlWidget NO`), with footprint up about 100 MB.
    - `sample` shows the time going to SwiftUI/RenderBox **CPU rasterization**: `CGDrawingLayer` → `RB::DisplayList::render`, `make_cgimage` + `apply_blur` (vImage Gaussian for the shadows/glows), and `rgba64_shade_conic` for the AngularGradient.
    - Things I tried that **did not** help: `.drawingGroup()` (Metal offscreen) on the ring, 37.6 % vs 38.5 %; replacing the conic gradient and blur glow with flat strokes (`-cheapRing YES`), 36.9 % vs 38.0 %.
    - The cost is SwiftUI re-rendering the animated hierarchy each frame, not one effect. With real Codex updates (about once per minute) this is negligible. A widget that ticks animated values every second is not.
- **Bundle size:** 544 KB → **11 MB**, of which 10.7 MB is the wallpaper JPEG. The binary is 1.0 MB. A pre-cropped 533×2767 JPEG would be about 0.3–0.5 MB if size matters.
- **Builds, Xcode 27 toolchain** (same Swift 6.4 compiler as the CLT):
  - clean release **13.3 s**, incremental release (touch Views.swift) **5.6 s**;
  - debug incremental 2.6–9 s;
  - `build.sh` about 13 s.
  - Round 1 needed about 45 s per release build. The improvement is most likely from splitting the code into three files, but I did not isolate it.
- **Launch → panel visible:** 0.5–0.75 s (unchanged).

## 5. Offscreen renders (`screens/`)
`-renderScreens <dir> -quitAfterRender YES` writes two PNGs per mode, composited on a slate stand-in "desktop":
- `<mode>.png` uses AppKit `cacheDisplay` of the live `NSHostingView`.
- `<mode>-imagerenderer.png` uses SwiftUI `ImageRenderer` of a fresh root. The root has no `ScrollView`, because ImageRenderer leaves ScrollView content blank.

What does and doesn't appear:

| Renderer | glass | cards | black | image + glass cards | image + material cards |
|---|---|---|---|---|---|
| `cacheDisplay` | ❌ glass becomes opaque white plates, text lost, shadows blown out | ❌ broken similarly | ✅ faithful | ❌ blank (whole glass container missing) | ✅ image, within-window blur and text all render |
| `ImageRenderer` | ⚠️ layout and text perfect; glass approximated as a flat translucent fill (no refraction or blur) | ⚠️ same | ✅ faithful | ⚠️ image plus flat tinted plates | ❌ `NSViewRepresentable` (NSVisualEffectView, WKWebView) render as yellow "unsupported" placeholders |

So **real Liquid Glass and blur can only be judged on screen.** Whether Liquid Glass samples the in-window image properly is unverified by me. The ImageRenderer output only proves the layering order.

## Round 2: what was hard
- **CLT is no longer enough.** With the macOS 26 deployment target, `@State` (and other SwiftUI property wrappers) expand through `SwiftUIMacros`. That plugin ships only inside Xcode, so CLT `swift build` fails with "plugin for module 'SwiftUIMacros' not found". `build.sh` now sets `DEVELOPER_DIR` to Xcode when present. Round 1 compiled with CLT only because it used no `@State`.
- **The blind visual loop again.** The offscreen renderers lie about glass (see the table above). Getting good screenshots needs Screen Recording permission for the terminal, or Xcode Previews.
- **Animation cost is invisible until measured.** One innocent `.animation(value:)` on a 2 s ticker turned a 0.4 % app into a 15 % app. Finding it needed `sample`: obvious once seen, but there is no warning.
- **Easy:**
  - Glass APIs (`glassEffect`, `GlassEffectContainer`, `.interactive()`, `.buttonStyle(.glass)`), numeric content transitions, `phaseAnimator`, springs, `TimelineView(.everyMinute)`: each is one modifier.
  - The JSON-RPC client is about 120 lines, and `posix_spawn` with process groups about 40.
- **Medium:** the image slice (ImageIO crop + redraw to cap memory) and the `.withinWindow` material for blurring in-window content.

## Round 2: please check by eye
1. Each mode via menu → Style: Single glass panel, Floating glass cards, Black, Image (+ "Image mode: Liquid Glass / blurred material cards"). Check whether Liquid Glass over the wallpaper actually refracts and blurs it.
2. Image crop: the face should be visible near the top, and the lower part should fade to black.
3. Hover over cards: a subtle scale and highlight. This may not fire while another app is active, because the panel never becomes key. The interactive glass response in cards mode is also unverified.
4. Codex card: menu → "Codex demo (randomize every 1 s)" shows ring/bar springs, rolling digits and the pulse above 80 %. Turn it off again: it costs about 38 % CPU while on.
5. Agent shimmer: `scripts/send-event.sh finished "test"` should insert a row and sweep a light across the card once.
6. The HTTP server crashed once during your round-1 testing: a negative `Content-Length` hit `prefix()` (crash report `SidePanel-2026-10-08-155300.ips`). That's fixed (clamped to 0…1 MB). Both PoCs use port 47821, so if the Tauri app is running, only one of them can listen.

---

# Round 3: sizes, positions, widget manager, settings

Test machine note: during round 3 the main display was **1680×1050** (visibleFrame 1680×1020 at y=0, Dock hidden), not the 6016×3384 display used in rounds 1 and 2. All frame numbers below refer to that display.

## What was built

**Architecture (a seed for the real app)**
- **`Widgets/WidgetKit.swift`**:
  - `protocol PanelWidget` declares `static meta`, `content(WidgetContext) -> View` and `settings(Binding<WidgetSettings>) -> View`.
  - `WidgetRegistry.all` holds type-erased `WidgetDescriptor`s.
  - `WidgetContext` carries `size`, `bar`, `settings`, the shared `AppModels` and a `preview` flag.
  - `WidgetCard` provides the per-size chrome and headers; `CardChrome` provides the per-mode chrome.
- **Seven widget files.** Each one has deliberate layouts for regular, compact, minimal and bar, plus an inline settings editor.
- **`Core/Config.swift`**:
  - `AppConfig`, `WidgetInstance` and `WidgetSettings` are `Codable`, with `decodeIfPresent` defaults, so old or hand-edited files keep loading.
  - `ConfigStore` saves with a 0.3 s debounce and atomic writes. It hot-reloads through a directory vnode watch, because atomic saves replace the inode. It ignores its own writes, and logs invalid JSON while keeping the last good config.
- Services (calendar, now playing, agents, stats, Codex, avoidance) and the app layer (`PanelController`, `WindowCoordinator`, `HotkeyManager`) are split out.

**1. Three sizes** (side panel 320 / 190 / 68 pt). Every widget has a hand-made layout at each size:

| Widget | compact (190 pt) | minimal (68 pt) | bar chip (44 pt tall) |
|---|---|---|---|
| Clock | 30 pt time and short date | **HH over MM stacked** plus weekday initial | `22:20 Thu 8` |
| Codex | 54 pt ring, countdown, thin weekly bar | **46 pt ring with %, weekly as a thin inner ring**, reset hours | 24 pt double ring, `2%` and weekly dot `29%` |
| Calendar | dot, title, time (N events) | **countdown "14m" with color dot** (tooltip shows title); icon when no access | dot, countdown, title |
| Now playing | 36 pt art, title and artist | **42 pt artwork with play/pause glyph badge** | 24 pt art, title, glyph |
| Agents | last 3, one line each | **sparkles icon with unread badge colored by status**; tap marks read | icon, badge, last message |
| System | two labelled thin bars | **two tiny vertical bars (C/M)** | two vertical bars plus values |
| HTML | WKWebView at 0.72 page zoom | globe icon only (no WebKit processes) | off by default |

- **Size switch:** the window frame animates with `NSAnimationContext` (0.32 s), and the SwiftUI layout animates with a spring on the same change.

**2. Four positions**
- left and right, each in all three sizes;
- top (just below the menu bar) and bottom (just above the Dock), as 44 pt bars across the full visibleFrame width, always with minimal widgets in a row.

Moving between positions does a 0.14 s fade-out, a jump, then a slide-and-fade-in from the new edge, so no stale frame is left behind. Per-instance **`inSide` / `inBar`** flags give the bar and the side panel different widget sets, in the same order.

**Window avoidance per edge.** The left-edge logic is reused by mapping each edge into a canonical space: right mirrors x, top swaps the axes, bottom swaps and mirrors. Smart mode clips windows whose near edge touches the visibleFrame edge and shifts free-floating ones; off, shift and clip are also available.

**The Rectangle helper** writes the key for the current edge (`screenEdgeGapLeft|Right|Top|Bottom` = panel thickness + 8, plus `screenEdgeGapsOnMainScreenOnly`). Revert deletes all four keys. It only runs when the user clicks it, and I did not run it.

**3. Widgets window** (menu bar → Widgets…, or ⌘1 while the app is active). It has three columns:
- **Your panel**:
  - a `List` with `.onMove` for **drag-to-reorder** (native insertion line and animation);
  - `.onInsert(of: plainText)` so **gallery tiles can be dragged in** at a specific index;
  - per-row chips for Side and Bar, a context menu with Remove and Duplicate, swipe/⌫ to delete;
  - quick Position and Size menus, and a "config.json" reveal button.
- **Gallery**:
  - live tiles using the real models (the HTML widget shows a static placeholder, so previews don't spawn WebKit);
  - a segmented Regular / Compact / Minimal / Bar switch that re-lays out the grid with a spring;
  - an "Added ×N" badge, a + button, hover lift, and tiles that are `.draggable`.
- **Inspector**:
  - header, "Show in" toggles, the widget's own settings form;
  - **live previews at all four sizes** that update as you edit;
  - a Remove button.

Every edit writes `config.json`, and the panel updates live.

Per-widget settings:
- clock: seconds, 12/24 h;
- Codex: show weekly;
- calendar: 1–10 events;
- system: CPU + memory, CPU only, or memory only.

**4. Settings window** (a grouped `Form`, separate from the manager):
- position and size (segmented);
- style, Liquid Glass and animated background;
- image mode: live thumbnail of the background, **Choose Image… via NSOpenPanel**, Use Default, card style, **dim and fade sliders**;
- avoidance off/shift/clip/smart, with explanations, Accessibility status and the Rectangle buttons;
- **hotkey recorder** (click, press a combo, Esc cancels);
- **Launch at login** toggle bound to `SMAppService.mainApp`, with status;
- a reveal-config button.

**Global hotkey:**
- Carbon `RegisterEventHotKey` (⌥⌘S by default) toggles the panel.
- It works without Accessibility permission and re-registers when the config changes.
- Registration returned `noErr`.
- **I could not press it myself** (synthetic key events would need Accessibility for the terminal).

**Launch at login:**
- `SMAppService.mainApp` was tested with `-testLoginItem YES`: status went from `notFound(3)` → `register()` → `enabled(1)` → `unregister()` → `notRegistered(0)`.
- **It is left disabled.**
- macOS may have shown a one-off "Login item added" notification during the test.

**Accessory-app window handling** (what was needed):
1. Switch to `.regular` activation policy while a manager or settings window is open (Dock icon and Cmd-Tab entry), and back to `.accessory` when the last one closes (verified in the log: policy 0 → 1).
2. A real main menu with an **Edit** menu; otherwise ⌘C, ⌘V and ⌘A don't work in text fields.
3. **Activation:** macOS 14+ *cooperative* `NSApp.activate()` was **refused** when the window opened without a user click: the window was visible but not key, and the app was inactive (logged `appActive=false isKey=false`). Switching to `activate(ignoringOtherApps: true)` (deprecated, still effective on macOS 27) gave `appActive=true isKey=true isMain=true`. When the window is opened from the menu bar item, the click itself should grant activation.
4. On close, `contentView = nil` releases the SwiftUI tree.

## 5. Testing

- **Frame matrix (all OK).** Driven entirely by editing `config.json` (hot reload) with `scripts/test-matrix.py`; the frame logged after each animation (`frames.log`) is compared to the expected rect:

| position / size | actual NSWindow frame | expected |
|---|---|---|
| left regular / compact / minimal | {0,0,320,1020} / {0,0,190,1020} / {0,0,68,1020} | ✓ |
| right regular / compact / minimal | {1360,0,320,1020} / {1490,0,190,1020} / {1612,0,68,1020} | ✓ |
| top | {0,976,1680,44} (directly below the menu bar) | ✓ |
| bottom | {0,0,1680,44} (Dock hidden, so the visibleFrame starts at 0) | ✓ |

- **Avoidance per edge (smart mode, `tools/testwin`).** Results are from `test-matrix.py` runs; I checked `pgrep` for the Tauri app before each run, and the script aborts if it appears. Fix delays were **1.4–4.4 ms**.

| edge | floating window → | snapped window → |
|---|---|---|
| left | shift: x 40 → 328, width kept | clip: x 0 → 328, width 900 → 572 |
| right | shift: x 1230 → 952, width kept (right edge = 1352 = panel − 8) | clip: width 800 → 472, x kept |
| top | shift: down below the bar (top edge = 968) | clip: height 500 → 448, bottom kept |
| bottom | shift: y 20 → 52 | clip: y 0 → 52, height 500 → 448 |

  - The bottom cases come from the first full run. The rerun aborted at bottom because the Tauri PoC started. The avoidance code has not changed since.
  - One test-design issue: a window placed partly off-screen gets constrained by AppKit flush to the screen edge, so smart mode correctly treats it as snapped and clips it.

- **Renders** (`screens/round3/`; `cacheDisplay` PNGs, plus `-imagerenderer.png` variants of the panel):
  - `panel-left-regular|compact|minimal-black.png`, `panel-right-regular|compact-black.png`, `panel-top-minimal-black.png`, `panel-bottom-minimal-black.png`;
  - `panel-left-regular-glass.png` (glass mode; glass is imperfect offscreen);
  - `panel-left-compact-image.png` (image mode, material cards);
  - `manager-regular|compact|minimal|bar.png` (the manager with the first widget selected, the gallery at each preview size, and the inspector previews);
  - `settings.png`.
  - **The drag-in-progress state cannot be captured offscreen.** The reorder animation and insertion line need a human to look.
  - Glass in the manager renders reasonably here (cards over the gradient stage). In the panel, glass is still unreliable offscreen; black mode is the reliable reference.

## Round 3 measurements
Glass mode, avoidance off (the Tauri PoC was running), 7 widgets (6 in the bar), 15 s warm-up, 60 s runs. Raw output: `measurements-round3.txt`. An earlier run on a slightly older binary (`measurements-round3-prebuildfix.txt`) gave the same picture.

| State | Total avg CPU % | App avg % (peak) | App RSS MB | Total RSS MB | Footprint MB | Energy Impact |
|---|---|---|---|---|---|---|
| (n) left, regular | **1.27** | 1.22 (29.8) | 105 | 378 | 136 | 1.22 |
| (o) left, compact | **0.70** | 0.65 (15.7) | 102 | 374 | 132 | 0.64 |
| (p) left, minimal (no WebKit) | **0.48** | 0.45 (17.8) | 85 | 280 | 92 | 0.46 |
| (q) top bar | **0.59** | 0.34 (5.6) | 83 | 245 | 93 | 0.44 |
| (r) Widgets window open (idle, live previews) | **0.90** | 0.85 (31.7) | **126** | 410 | 150 | 0.88 |
| (s) idle after the window closed | **0.74** | 0.71 (23.3) | **128** | 412 | 143 | 0.69 |
| (t) size switch every 2 s (15 s spot) | **11.1** | 9.9 (20.4) | 114 | 372 | 130 | 10.7 |
| (u) position switch every 3 s (15 s spot) | **5.0** | 3.6 (17.7) | 111 | 363 | 128 | 4.8 |
| (v) baseline 15 s | 0.31 | 0.31 (1.9) | 108 | 380 | 134 | 0.29 |

- **Idle cost is low in every layout.**
  - Minimal and bar layouts drop WebKit (three fewer processes, about 65 MB less RSS) and are the cheapest.
  - `codex app-server` is about 165 MB RSS in this round (it was 100–110 MB in round 2) at about 0.03 % CPU. Its RSS dominates the totals.
- **Widgets window:** while open and idle, it adds about **+20 MB app RSS** and little CPU.
- **Memory does not come back after closing.** App RSS stays at about 128 MB, and footprint drops only about 7 MB, even though the SwiftUI tree is released (`contentView = nil`). The likely causes are SwiftUI/AppKit caches and malloc not returning pages to the OS. That is a typical native pattern; it is bounded and doesn't grow when the window is reopened, though I tested only one open/close cycle.
- **Animation cost:**
  - Each size switch costs roughly 0.2 CPU-seconds: the window frame animation plus a full SwiftUI relayout of all cards, including WebKit re-layout.
  - Each position switch costs roughly 0.1 CPU-seconds; it is mostly Core Animation alpha and frame changes.
  - Both are negligible for occasional switches.
- Launch to panel visible: **0.39–0.49 s**.
- **Bundle:** 13 MB, made up of a 2.7 MB binary (it grew with the manager and settings UI) and the 10.7 MB wallpaper.
- **Build (Xcode toolchain):**
  - clean release **15.6 s**, incremental release (touching one widget file) **8.3 s**;
  - clean debug 10.6 s, incremental debug **1.8 s**.
  - 3,137 lines in 25 files.

## Round 3 DX notes: how hard each part was

- **Multi-size widget layouts: easy to medium.**
  - Each widget is a `switch ctx.size`, and SwiftUI makes per-size layouts cheap to write.
  - The time went into design decisions: what survives at 68 pt, and how a bar chip differs from a minimal tile.
  - With a live gallery preview this would be quick to iterate. Without Xcode Previews I iterated through offscreen PNG renders, which worked well for black mode.
- **Drag-and-drop reorder: easy and good quality.**
  - `List` + `.onMove` gives native macOS reordering (insertion line, auto-scroll, animation) in one modifier.
  - Dragging gallery tiles into a precise index takes `.draggable(String)` plus `.onInsert(of:)`, about 15 lines.
  - **Not verified by hand.** The rows also contain buttons, and the drag start area should be checked.
  - A fully custom card-style drag (reordering in a free grid with lift and shadow) would take much more work in SwiftUI on macOS; I did not attempt it.
- **Multi-window in an accessory app: medium, with real gotchas** (see the four points above).
  - The cooperative activation refusal is the trap: it fails silently.
  - The `.regular` ↔ `.accessory` flip is necessary to get Cmd-Tab and the Edit menu working, and it briefly shows a Dock icon.
  - There's no SwiftUI `Settings`/`WindowGroup` scene here because the app uses an AppKit `NSApplication` main. Windows are hand-made `NSWindow`s hosting SwiftUI, which also gives full control over lifetime and memory.
- **Global hotkey: easy.** It's Carbon `RegisterEventHotKey` (about 50 lines including the recorder conversion), needs no permissions and no dependencies. The KeyboardShortcuts package would add a nicer recorder UI.
- **Launch at login: trivial.** `SMAppService.mainApp.register()` worked from `~/Desktop/...` with Developer ID signing. It is not sandboxed and not in /Applications.
- **Config + hot reload: easy.** Codable with defaults, atomic writes and a directory watch. Hot reload turned out to be the best test harness: every frame and avoidance test above was driven by editing the JSON.
- **Tooling gotchas this round:**
  - `build.sh` used to pipe `swift build` through grep with `|| true`. A compile error was therefore swallowed and the **previous binary got bundled**. I caught it because a new flag had no effect. Fixed: the script now fails with the errors shown.
  - `ImageRenderer` skips `ScrollView` content and `NSViewRepresentable`s; `cacheDisplay` can't render glass. The drag state can't be rendered at all.
- **Not verified, needs the user:**
  - that the hotkey toggles the panel;
  - the drag-and-drop feel;
  - typing in the hotkey recorder after opening the window from the menu bar;
  - NSOpenPanel choosing a custom image;
  - the slide/fade feel of the size and position animations;
  - hover effects in a non-key panel;
  - the Rectangle configure/revert per edge (not run, by rule);
  - a second display (none attached; top and bottom bars always sit on the primary screen).

## Round 3: try by hand
1. Menu bar → **Widgets…**:
   - drag rows to reorder, and drag a gallery tile into the list;
   - toggle the Side and Bar chips; switch Regular/Compact/Minimal/Bar previews;
   - change clock seconds or 12 h and watch the panel update live.
2. Menu bar → **Settings…**:
   - switch position (left → right → top → bottom) and size, and watch the transitions;
   - pick Image style, then Choose Image…, and move the Dim and Fade sliders.
3. Press **⌥⌘S** to toggle the panel. Then record a new shortcut in Settings and try it.
4. Hand-edit `~/Library/Application Support/SidePanelNative/config.json` (for example `"position" : "right"`) and save: the panel should move within about 0.5 s.
5. With smart avoidance on the right, top and bottom edges: drag a window over the panel, and snap one with macOS tiling or Rectangle. Optionally run "Configure Rectangle for panel…" for the current edge, then Revert.
6. Launch at login: toggle it on and off in Settings (it was left **off**).
