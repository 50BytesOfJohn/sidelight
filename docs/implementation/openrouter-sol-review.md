# Preliminary independent Sol source review

Reviewed 2026-10-13 on `review/openrouter-widgets`. Production snapshot: `438dd799fd2581e5ef93fc30b6395423542d7d57`; baseline: `512173986c441629a4157e063fe520decbe2365f`. All 45 changed production files were inspected, together with their relevant existing callers and helpers.

This is an immutable **partial WIP review**, not acceptance or an implementation-completion handoff. Opus stopped at its session quota; there is no production completion claim. No builds, tests, fixtures, app launches, measurements, AX writes, credentials, permissions, real configuration changes, commits or external messages were performed in this review. Only this untracked report was added. The separate tester owns compilation, checks, tests and safe native validation. All production fixes below belong to Opus upon availability.

Authority: repository AGENTS, CONTRIBUTING, VISION, `sidelight-conventions` and `write-swift`; the copied implementation handoff; and the proposal's **Decided by you (2026-10-13)** block. Superseded popup/overlay/always-left assumptions were not used. The actual package uses Swift tools 6.4, main-actor-default app isolation and nonisolated Core; older future-version wording in the Swift skill is not the toolchain authority.

P1 means address before any broader native use of this feature. P2 means a concrete correctness or approved-contract defect to fix before completion. Complexity refers to future Opus production work. Triggers below are source-derived reproducer instructions, **not executed tests**.

## Actionable defects in the current paths

### R1 — P1: ordinary avoidance can still mutate windows on inactive Spaces

**Location:** `Sources/Sidelight/WindowAvoidance/WindowAvoider.swift:481–517`; callers at `:128–133`, `:409–416`, `:448–475`. **Complexity: High.**

The new reservation transaction checks `OnScreenWindows.contains` before mutation, but `avoid` never does. Initial application registration, the delayed `avoidAllWindows` sweep, and AX move/resize/create callbacks all use this unrestricted path. It also creates restoration records for these writes. Adding the safe transaction therefore does not establish the promised active-Space boundary for window movement.

**Trigger:** an eligible app has a standard non-minimized window on another Space with coordinates overlapping the effective details strip. Registration or a geometry-triggered sweep enumerates its AX windows, and `avoid` can set its frame without on-screen evidence. An ambiguous pair of same-frame AX windows likewise bypasses the new ambiguity check.

**Impact:** unseen user windows can be moved, including while browsing details. This is a blocking safety gap even though the unrestricted basic avoidance path predates this snapshot.

**Recommendation:** share one eligibility/identity/current-Space gate across every mutation path, including ordinary avoidance, pending callbacks and restoration. Apply the disposable-app restriction at that same boundary. Fail closed when membership is ambiguous. Keep the public CG/AX correlation conservative; its reliability across real Spaces remains unverified.

### R2 — P1: the hidden main window can stop a visible details panel's demand

**Location:** `Sources/Sidelight/Panel/PanelCoordinator.swift:117–128,169–170`; `Sources/Sidelight/App/AppController.swift:160`; `Sources/Sidelight/Details/DetailsPanelController.swift:90–95`; `Sources/Sidelight/Details/DetailsPanelView.swift:41`. **Complexity: High.**

Opening details orders the main panel out. Only that main panel supplies the display's occlusion notifications. Its invisible state schedules `unseenDisplays` after 60 seconds, and the details-demand merge excludes that display when it becomes unseen. The details controller has no corresponding occlusion/workspace observer to keep visibility accurate. Its clock environment uses `layout.isShown` alone, so it also has no sleep/lock signal for stopping minute redraws.

**Trigger:** open details on the only display needing Models, leave it visible beyond the unseen grace, then attempt refresh. On the normal AppKit invisible-state notification path the catalogue policy becomes nil despite the visible details window; `refreshNow` then ignores the action. Conversely, the details clock's source state remains shown on sleep/lock.

**Impact:** visible browsing loses fetch demand, and hidden native detail content lacks the intended idle behavior.

**Recommendation:** observe the currently displayed surface independently of the covered main panel, sharing explicit screen/session visibility signals. A deliberate main `orderOut` must not classify visible details as unseen. Feed the resulting details visibility to both demand and `WidgetClock`. The notification timing and actual sleep energy effect still require isolated native validation; this report does not claim to have observed them.

### R3 — P1: nil demand is used as a preview flag, allowing mock money in real panels

**Location:** `Sources/Sidelight/Widgets/OpenRouter/OpenRouterCreditsWidget.swift:44–50`; `Sources/Sidelight/Widgets/OpenRouter/OpenRouterModelsWidget.swift:55–62`; `Sources/SidelightCore/Configuration/OpenRouterSettings.swift:429–431`. **Complexity: Medium.**

The Credits view chooses the $74.25 sample whenever it has no success and `service.demand.balance == nil`. It never checks whether it is a preview. Real panel hosting views are laid out and shown before the asynchronous demand observation runs in `AppController.start`, so a real cold view can select this sample branch. The same structural problem affects Models. Conversely, opening the manager or any builder adds private demand for **every configured Credits widget**, even widgets hidden from every panel; the gallery/inspector views then use live private data and refresh callbacks. That contradicts the handoff's mock/placeholder-only private previews.

**Trigger:** cold-start with a real Credits placement; separately, hide panels with a configured Credits widget and open a Models builder or Widgets window. The first path has a source-level opportunity to render mock account money; the second initiates balance/activity demand solely for previews.

**Impact:** fabricated financial data can be presented as an account balance, and unrelated preview work can read the Keychain and start private requests.

**Recommendation:** make preview context explicit, preferably through the preview composition/environment. Choose mock/placeholder data only there, and mark financial samples as examples. A real panel without a fetched balance must remain loading/setup/unavailable. Exclude private preview demand while retaining demand from genuinely visible placements and explicit connection/key-picker actions. Native first-frame timing has not been measured.

### R4 — P2: unchanged restore can override the required edge-follow geometry

**Location:** `Sources/SidelightCore/Avoidance/ReservationTransition.swift:180–198`. **Complexity: High.**

`closingDetails` computes edge-follow, but returns an old-frame restoration first whenever the restored **near edge** matches. It does not compare the far edge or apply the specified edge-follow-first priority. For a window shifted rather than clipped on open, restoring its old width changes its far edge; following the current snapped boundary should instead retain that edge and resize subject to app constraints.

**Trigger:** on a 1440 pt display, left main strip ends at 200, details ends at 360. A window at x=208, width=400 is clear of main, then shifts to x=368, width=400 under smart avoidance. Closing restores x=208, width=400 because contact is preserved, moving the far edge from 768 to 608. The handoff's edge-follow rule targets x=208, width=560, preserving far edge 768.

**Impact:** closing moves the opposite edge of a snapped window contrary to the approved restoration exception. The same branch can give a new window a general old-frame restore when it should participate only through edge following.

**Recommendation:** apply eligible contact-follow geometry first. Only use unchanged-frame restoration when contact-follow does not apply, or when its entire target frame agrees. Keep the layered main baseline correct after this choice. This numerical trace is source reasoning, not a test run.

### R5 — P2: bar-to-details takeover adds the new axis without freeing the old one

**Location:** `Sources/SidelightCore/Avoidance/ReservationTransition.swift:151–161`. **Complexity: High.**

The generic main-to-details branch calls avoidance against the current frame and the new strip only. It never uses the main baseline to remove the old top/bottom reservation when changing axes. An unchanged window shortened or moved by the bar retains that old vertical displacement throughout the left-side takeover.

**Trigger:** a top bar clips a full-height window downward. Open Models details from that bar. The left-strip plan changes x/width but starts from the already clipped y/height, leaving the former bar area empty although that reservation has gone away.

**Impact:** the final free rectangle includes obsolete bar displacement; the specified atomic removal-of-bar/addition-of-left geometry is incomplete.

**Recommendation:** for unchanged eligible windows, compose the old baseline with the final reservation in one decision and one apply. Do not implement this as an intermediate restore then push. Preserve user edits and invalidate geometry-dependent baselines conservatively.

### R6 — P2: private cooldown/auth state is resource-local, and key paging discards it

**Location:** `Sources/Sidelight/Widgets/OpenRouter/OpenRouterService.swift:390–405`; independent balance/activity policies at `:129–137`; `Sources/Sidelight/Services/RemoteResource.swift:102–108,160–170`. **Complexity: High.**

`loadKeys` discards the returned retry advice. After a page fails, another Load More action or picker reopening may immediately issue the same request. Balance and each activity scope also have separate cooldown/auth state, with no shared connection gate. A newly demanded resource is free to request during another resource's Retry-After, and `.onRequest` allows explicit refresh with the same credential after 401/403. The handoff requires connection-wide cooldown and auth pause until credential changes.

**Trigger:** page two returns 429 with `Retry-After: 600`; click Load More again. Or balance returns that status and then enable a new key chart. Neither path consults that established account deadline. After 401, the same saved credential can be retried via refresh or a newly demanded scope.

**Impact:** the integration can bypass server pacing and repeatedly use a credential known to be rejected.

**Recommendation:** retain a credential-generation-scoped private request gate covering balance, all activity scopes and key paging, alongside each resource's freshness/backoff. Apply the shared manual gap there where specified. Credential validation needs its own explicit policy. Preserve stale data and expose a usable first-page retry after its deadline. This is source evidence, not live rate-limit behavior.

### R7 — P2: overdue daily activity waits ten additional minutes after every resume

**Location:** `Sources/Sidelight/Services/RemoteResource.swift:190–193`. **Complexity: Medium.**

The daily deadline clamps time to midnight to zero **before** adding the configured post-midnight delay. When midnight plus ten minutes is already past, this still schedules a new ten-minute wait from now.

**Trigger:** fetch activity on Monday; stop demand; resume Tuesday afternoon. The stale chart waits ten minutes instead of one immediate overdue fetch. Repeated short visibility periods can keep cancelling that wait and leave it stale indefinitely.

**Recommendation:** calculate the absolute target `nextDay.start + delay`, then clamp the complete target-minus-now interval to zero. Keep monotonic waiting and no catch-up bursts.

Related boundary concern to validate: `OpenRouterService.load` passes a wall date captured **before** network transport to parsers, while `RemoteResource.record` dates the success after transport. A request crossing UTC midnight can give the activity snapshot and its scheduler different day anchors. Resolve which response-time anchor represents provider coverage and use it consistently; no midnight request was executed here.

### R8 — P2: key removal reports success even when Keychain deletion fails

**Location:** `Sources/Sidelight/Widgets/OpenRouter/OpenRouterService.swift:291–298`; `Sources/Sidelight/Widgets/OpenRouter/OpenRouterCreditsSettingsEditor.swift:121–126`. **Complexity: Medium.**

Removal immediately publishes `hasKey = false`, logs removal, and ignores the queued delete's Bool. The saved secret can remain present with no error or retry shown. The keychain adapter distinguishes deletion failure, but the service throws that information away.

**Trigger:** the credential store returns false from delete (for example a Security-framework failure), then restart. The same management key is read and account fetching can resume although the UI previously said it was removed.

**Recommendation:** immediately suspend private use and clear private data, then await the serialized deletion and generation-check its result. Expose failure/retry without claiming removal succeeded or publishing a stale result over a newer save. No real Keychain access was performed.

### R9 — P2: tolerant key parsing can prematurely end pagination

**Location:** `Sources/SidelightCore/OpenRouter/OpenRouterAPI.swift:145–151`; `Sources/Sidelight/Widgets/OpenRouter/OpenRouterService.swift:401`. **Complexity: Medium.**

The parser drops entries with unreadable hashes, then the service uses the **filtered count** to decide whether the provider supplied a full page and to advance offset. Those counts have different meanings.

**Trigger:** a 100-entry provider page contains one unreadable entry and more keys exist afterwards. The parser returns 99 keys, `nextOffset` becomes nil, and the remaining pages cannot be reached.

**Recommendation:** return a page value with raw entry count/next-offset evidence plus decoded keys. Advance pagination by provider entries, dedupe visible hashes separately, and expose the bounded traversal limit instead of leaving a nonfunctional Load More button. The 100-entry page-size assumption comes from the handoff/research; authenticated pagination remains unverified.

### R10 — P2: expired keys are omitted from the picker request

**Location:** `Sources/SidelightCore/OpenRouter/OpenRouterAPI.swift:66–69`. **Complexity: Medium.**

The request includes disabled keys but omits `include_expired=true`. Current official [List API keys documentation](https://openrouter.ai/docs/api/api-reference/api-keys/list-api-keys) says expired keys are excluded by default. The UI has an expired label and the handoff requires expired metadata, but this request cannot supply those entries.

**Trigger:** a saved or candidate chart key expires; reopen the picker. It is absent from the fetched list instead of being described as expired (a retained selection only says not listed).

**Recommendation:** request expired keys explicitly and retain stable hash/name selection. Keep default-workspace scope and bounded offset traversal. Documentation establishes the request contract; no private endpoint reconciliation was performed.

### R11 — P2: live hotkey reassignment can collide with an old registration owned by this app

**Location:** `Sources/Sidelight/Hotkey/HotkeyCenter.swift:75–110`, retry guard at `:46`; `Sources/Sidelight/Settings/GeneralSettingsPane.swift:20–21`. **Complexity: Medium.**

Reconciliation releases and registers one action at a time. It can attempt to register the new toggle key while the old close-details registration still holds that key, only releasing the latter later in the loop. If Carbon rejects this collision, the toggle remains unregistered; subsequent same-value `register` calls return without retrying. Duplicate settings are accepted and only warned about, rather than rejected as the handoff requires.

**Trigger:** with details open, externally reload a configuration changing the toggle to the current close shortcut, or swapping the two shortcuts. The UI recorder normally suspends both first, so that particular path mitigates the ordering bug; file reload does not.

**Impact:** an otherwise working global toggle can stop working following a supported configuration reload. The exact Carbon duplicate-registration result is a native validation dependency, not an observed failure here.

**Recommendation:** determine desired winners first, release registrations that conflict with that final mapping before acquiring replacements, and preserve/restore the working toggle if acquisition fails. Reject duplicate physical key/modifier assignments in the editing flow and use physical identity for conflict comparisons. Validate Carbon behavior with an isolated hotkey harness.

## WIP omissions and verification boundaries

These are unfinished obligations or empirical risks, not a claim that Opus submitted completed broken work:

- No prior native focus/window identity is captured for a conditional return on close. Nonactivating search, Edit shortcuts, IME, dictation, VoiceOver and focus after switching apps remain unverified. `makeKey`, `NSApp.sendAction` and selectors express intent, not demonstrated behavior.
- Details entrance animations have no explicit generation/cancellation handling when a hide, geometry change or close overtakes them. Their actual AppKit retargeting behavior needs native evidence before calling it a defect or accepting it.
- Normal main-panel geometry/disabling changes still use the old delayed sweep when no details session is present; no general old-to-new reservation handoff is wired there. Pending 600 ms sweeps are not cancelled by explicit details handoffs. Complete this integration consistently with the ledger; don't solve it with a second window mover.
- The mutation seam is an app-eligibility closure, not an injected AX snapshot/apply/readback adapter. That is useful for restricting a disposable app, but does not by itself prove frame acceptance, self-notification suppression, transaction ordering, Space identity or refusal behavior. Quit calls `releaseAll` but does not explicitly stop the avoider's observers/tasks. Lifecycle completion remains necessary.
- Public on-screen evidence plus PID/frame matching is a conservative approach, but actual CG-versus-AX bounds, active-Space behavior, ambiguous twins and asynchronous size acceptance have not been validated. The installed SDK documents on-screen enumeration and the meaning of visible occlusion; it does not establish the empirical reliability of this correlation.
- Configuration compatibility has the right source structure: the new top-level `details` field defaults while old required keys remain required. New settings and repeatable IDs are wired. Released fixture/round-trip checks, compile coverage of exhaustive kind switches, and `make check` belong to the tester; none are claimed here. Cadence clamping uses the broader `UsageRefresh.minuteRange`, and the editor deliberately exposes hand-edited values; reconcile that with the handoff's offered-range requirement before release.
- Four widget layouts and repeatable builder blocks exist in source. Grouped OpenRouter presentation in the Widgets window is not added. Clipping/long-name behavior at actual widths, accessibility navigation, image/material appearance, scroll preservation and stable cached-open latency have no native evidence.
- Private financial completeness, actual account totals and key pagination are documented contracts only. Malformed required usage/date rows fail the activity parse, but optional BYOK parsing loses the distinction between absent and malformed values; the financial parser validation should cover that distinction. HTTP size limits are post-download parse limits, not peak-memory streaming limits.

## Architecture worth keeping

The basic partition is sound: pure Sendable domain/configuration/API/geometry in Core; observable main-actor services; off-main transport/normalization and Security calls; one shared public catalogue with precomputed orders/search keys; private balance and scoped activity resources; explicit origin placement preventing preview details opens; generic details chrome separated from widget content; 360 pt same-side geometry; and separate main/details baseline layers with accepted-frame readback.

Demand stop cancels resource tasks, and ordinary fetch publications check cancellation and credential generation. Successful snapshots survive transient failures. Money uses Decimal and signed account subtraction, while BYOK stays separate. Unknown modalities remain in All, unknown token prices sort last, zero prices do not imply free, and model links are constrained to the expected host. These are source-quality observations, not measured performance or an absence-of-bugs assertion.

Official references checked without calling APIs: [Credits](https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits), [Activity](https://openrouter.ai/docs/api/api-reference/analytics/get-user-activity-grouped-by-endpoint), [Keys](https://openrouter.ai/docs/api/api-reference/api-keys/list-api-keys), and [Models guide](https://openrouter.ai/docs/guides/overview/models). They support the account-credit, completed-UTC-day/workspace, key-list query and per-token/default-provider semantics. Apple web pages exposed little content; native contract evidence came from the installed Xcode SDK `NSWindow.h` (occlusion comments at lines 184–189 and 982–984) and `CGWindow.h` (enumeration comments at lines 137–145). None of these substitute for native or authenticated verification.

## Routing to root

Prioritize R1–R3 before broader E2E. Route all production findings to Opus; Sol must not patch production. R4–R11 are concrete follow-up work, with R11 explicitly conditional on native Carbon behavior. The remaining omissions belong to the production-completion and tester handoff, not to a duplicate testing pass by this reviewer.

No final acceptance is possible from this snapshot. Acceptance requires Opus completion, Sol validation of revised code, passing required checks, and safe native evidence for the stated remaining assumptions.
