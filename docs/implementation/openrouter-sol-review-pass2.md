# Independent OpenRouter source review — pass2

2026-10-13. Branch `review/openrouter-widgets-pass2`, immutable production HEAD `e56132feb0e06ac4a90575bc68b9a4262f004b2d`. Reviewed the 51 production source files changed from baseline `512173986c441629a4157e063fe520decbe2365f`, the 32-source-file delta from WIP `438dd799fd2581e5ef93fc30b6395423542d7d57`, and relevant existing callers/helpers. The intervening test commit is not an Opus production change.

**Verdict: blocked for source-review readiness.** Pass2 substantially improves the implementation, but the seven actionable findings below remain. Route production work to **Opus Medium/High only**. Root should combine this report with the independent tester's results and request another production pass.

This was source inspection and bounded primary-document research only. No production/test edits, builds, lint, format, tests, app launches, AX operations, measurements, local commits, subagents or external messages were performed. Only this untracked report was added. Neither checks, native behavior nor performance are asserted to pass.

Authority: repository AGENTS/CONTRIBUTING/VISION, local Sidelight and modern Swift skills, implementation and pass2 production handoffs, prior Sol reports, and the proposal's **Decided by you (2026-10-13)** section. Superseded overlay/popup/always-left sketches were excluded. Swift tools 6.4 and main-actor-default app isolation come from the actual package, overriding older skill version wording.

## Findings for Opus

P1 denotes a safety/authority failure to address before broader native use. P2 denotes concrete correctness or agreed-scope work before completion. Triggers are source-derived traces, not executed reproductions.

### S1 — P1: failed removal reauthorizes the same credential, including a rejected one

**Locations:** `Sources/Sidelight/Widgets/OpenRouter/OpenRouterService.swift:344`, especially `:362–367` and `:401–409`; UI `Sources/Sidelight/Widgets/OpenRouter/OpenRouterCreditsSettingsEditor.swift:129–140`. **Opus: Medium.** New pass2 failure flow; R8 reopened.

After deletion returns false, the service clears `keyLoad`, calls `keyChanged()` again, clears the entire connection's rejection/cooldown, resets demanded resources, and rereads the saved secret. Those resources then send requests with the attempted-removed key. A balance 401/403 followed by Remove → failed delete therefore resumes precisely the credential the connection promised not to use until explicitly saved again. This also reverses an ordinary user's instruction to stop using a non-rejected key. Reporting the failure does not supply new authorization to use it.

The error is shown only in the `hasKey == true` form branch. A failed reread returns nil through the current store adapter, hiding the deletion failure behind the Add Key form even though absence was not established.

**Recommendation:** separate “still stored” from “authorized for use.” Keep private use suspended and data cleared after Remove, retain the rejection/deadline for that credential, and show the deletion failure independently of read success. Retry deletion or an explicit validated save/re-enable can change that state. Do not use `keyChanged()` to authorize the old key after failure. Preserve serialized writes and generation checks. Tester should cover failed deletion after both a usable key and a terminal rejection, with demanded balance/activity and a failed reread.

### S2 — P1: incomplete AX sibling evidence is treated as proof of uniqueness

**Location:** `Sources/Sidelight/WindowAvoidance/WindowAvoider.swift:584–590`, notably `compactMap(\.frame)` at `:589`; consumer `Sources/Sidelight/WindowAvoidance/OnScreenWindows.swift:34–37`. **Opus: Medium.** R1's mutation-path coverage is fixed, but its ambiguity refusal remains incomplete.

The shared gate drops siblings whose frames cannot be read. Consider two AX windows of one app with identical bounds on different Spaces: the candidate on the inactive Space has readable bounds, while reading its active-Space sibling's bounds fails. CG supplies exactly one on-screen window at those bounds; the unknown sibling disappears from the twin count. `mayMove` returns true for the inactive candidate, allowing ordinary avoidance or a restoration write.

This is a source-level fail-open case, not a claim that a particular app or Space produced it. AX attribute reads explicitly return nil on failure in the existing adapter. PID/frame matching cannot establish uniqueness when one possible twin's bounds are unknown.

**Recommendation:** require a complete relevant sibling snapshot, or equivalent public identity evidence, before accepting uniqueness. With the present frame-correlation approach, any unreadable possible sibling must refuse mutation and expire the applicable restoration claim. An unambiguous complete snapshot should retain the present behavior. Add pure gate coverage for unreadable siblings; native CG/AX agreement still needs disposable-window validation.

### S3 — P2: windows created or rebaselined during details receive a general restore claim

**Locations:** `Sources/Sidelight/WindowAvoidance/WindowAvoider.swift:309–326`, especially `:321`; caller `:559–562`; `Sources/SidelightCore/Avoidance/ReservationTransition.swift:192–222`. **Opus: High.** Unresolved lifecycle defect exposed by pass2's contact distinction.

Ordinary avoidance records `baselines.details = before` for every pushed window while details is open, including one created during the session. Close then treats that as a genuine pre-details baseline. There is no opening-session membership or restoration-eligibility distinction.

For example, with main ending at x=200 and details at x=360, create a window at x=250, width=400. Ordinary smart avoidance shifts it to x=368, width=400 and records x=250 as its details baseline. If unchanged, close sees that baseline was not snapped to x=200/208 and restores x=250. The approved contract gives this new window no general pre-details restoration; its current contact may instead follow to x=208, retaining its far edge (width=560 if accepted). A user-modified window that is subsequently pushed and rebaselined can acquire the same incorrect “unchanged pre-details” status.

**Recommendation:** distinguish takeover baselines from later avoidance bookkeeping, retaining accepted frames for self-notification handling without inventing pre-session restoration rights. New/user-modified windows may follow deliberate/current contact, but cannot regain a whole-frame pre-details restore claim through ordinary callbacks. Preserve valid main layers where applicable. Tester needs a trace through `remember` plus close, not only a pure decision supplied with nil baselines.

### S4 — P2: the private request gate is incomplete at the key-page send boundary

**Locations:** `Sources/Sidelight/Widgets/OpenRouter/OpenRouterService.swift:451–461` and `:470–480`. **Opus: Medium** for the send-boundary fix; **High** if completing shared manual pacing in the same pass. R6 partially reopened.

`loadMoreKeys` checks pacing before creating a task. `loadKeys` subsequently awaits `managementKey()` and sends without checking pacing again. Another request can establish 401/403 or Retry-After between admission and this send; the generation stays the same, so the existing generation guard does not stop it. There is also an admission-to-task-start gap. Balance and activity already perform the necessary post-await checks.

**Recommendation:** recheck the current connection hold immediately before the `/keys` transport call, finish loading state with the held problem, and avoid the send. Keep legitimate new-key resets: successful save currently resets balance, every retained activity resource and key paging, so demanded resources resume; public catalogue stays independent.

**Related agreed-contract gap:** the handoff specifies a shared 15-second manual gap, but `AccountPacing` tracks only rejection and Retry-After. `RemoteResource` enforces 15 seconds separately per resource, and successful key pages have no manual gap at all. A second manual action against another private scope/page can therefore send inside that shared interval. Complete the connection-level manual-action admission policy, coalescing the requests belonging to one refresh gesture rather than imposing 15 seconds between its key preflight and activity request. If root intends per-resource/manual-page behavior instead, record that as an explicit contract change; it is not demonstrated by pass2.

### S5 — P2: removing the last Credits widget can leave its key-list fetch alive

**Location:** `Sources/Sidelight/Widgets/OpenRouter/OpenRouterService.swift:159–168`, with demanded-service branch at `:145–155`. **Opus: Medium.** Unresolved cooling/data-retention path.

Start the first key-page request with no balance success/problem and no activity resources (for example hidden Credits, chart previously off, then explicitly enable the key picker). Remove the last Credits widget while that request is pending and a Models widget keeps the service enabled. Balance policy stops, but the guard in `forgetAccountData` sees no value/problem/activity/keys and returns before cancelling the key-list task. Its response can then publish private key metadata after account data should have been forgotten. An empty failed key-list result is also omitted from the guard.

**Recommendation:** cancellation and key-list clearing must cover pending work and problem/metadata states even when no successful private snapshot exists. Make forgetting idempotent without skipping an in-flight first page. Preserve the saved credential as specified. Tester should keep catalogue demand active and suspend the first key page across removal.

### S6 — P2: automatic details text resolves against solid cards that it never draws

**Locations:** `Sources/Sidelight/Details/DetailsPanelView.swift:15–37`; `Sources/SidelightCore/Configuration/DetailsPanelSettings.swift:43–48`; existing resolver `Sources/SidelightCore/Configuration/Appearance.swift:185–189`. **Opus: Medium.** Unresolved inherited/custom-style correctness.

Details inherits `appearance.cards`, then calls the shared color-scheme resolver. For automatic text, solid card fill of at least 0.6 takes priority over the background. Details draws a background and plain catalogue/chrome, not those solid cards. Configure a white opaque panel/details background with dark solid cards: automatic resolution picks light text for the dark cards, so details draws light text on white. A contrasting custom background has the same failure. This affects search, rows and close chrome, not cosmetic consistency.

**Recommendation:** automatic details text must resolve against the surface actually behind its content, preserving explicit light/dark overrides. Either resolve without the unused card layer or render the inherited card layer intentionally; avoid adding an unrelated text setting. Include inherited and custom backgrounds with opposing solid-card colors in isolated visual QA.

### S7 — P2: recording a refused shortcut loses the working fallback

**Locations:** `Sources/Sidelight/Hotkey/HotkeyCenter.swift:83–119`, especially local `previous` at `:98`; `Sources/Sidelight/Settings/HotkeyRecorder.swift:44,52–54,65`. **Opus: Medium.** R11's file-reload ordering is fixed; the promised fallback is incomplete.

With a working toggle A, the recorder calls `suspend()`. Reconciliation releases A and discards its local `previous` mapping. Record B, already owned by another app, then resume. `registered` is empty, so `previous` is empty in this reconciliation; if Carbon refuses B, fallback cannot reacquire A. The toggle stops working despite pass2's stated preservation policy. The source trace is conditional on a registration refusal; no Carbon refusal was induced here.

**Recommendation:** retain the last working shortcut across recorder suspension until replacement succeeds or the action is intentionally removed. Apply physical-key conflict checks when restoring it, and expose the actual working shortcut consistently. Test ordinary refusal, recording cancellation, reload swap and two-action collisions with an isolated registration harness/native check.

## Disposition of R1–R11 and prior behavior failures

“Addressed” below means the specific defect has a coherent source fix, not that a test or native check passed.

| Prior item | Independent source disposition |
|---|---|
| R1 unrestricted ordinary avoidance | Every mutation path now uses the public-evidence gate; reopening incomplete sibling evidence as S2. CG/AX and Space reliability remain native uncertainties. |
| R2 hidden-main demand / details clock | Addressed structurally: each surface owns `WindowVisibility`; details demand uses `isDetailsUnseen`, not main `unseenDisplays`; its clock uses `layout.isOnScreen`. Five-second cover and sixty-second unseen grace are distinct; global hide excludes demand immediately. |
| R3 mock money / private preview demand | Addressed: explicit `isWidgetPreview`; real cold panels use loading/setup/problem; previews always use example Credits and omit private demand. Models previews use cached public data or sample data and cannot open real details. Compact/minimal examples have tooltip/accessibility marking rather than a visible example caption; do not claim every size visibly labels the sample without QA. |
| R4 follow priority | The snapped/changed/new nil-baseline pure decision now follows first and retains far/vertical edges. The automatic-contact refinement is justified below. S3 remains in actual ledger population. |
| R5 bar handoff / layers | Unchanged old-role baseline is planned once against the new strip; bar reservation is freed while left details opens. Returning bar follow also keeps an unclipped main baseline. Main-to-main geometry uses this owner. User-changed frames discard old baselines; only necessary new-strip avoidance can move them. |
| R6 account cooldown/auth | Shared generation-scoped Retry-After and terminal rejection are present, manual balance/activity sends consult them, public catalogue is independent. S1 and S4 prevent closing this item. Successful explicit save resets all retained private resources. |
| R7 daily schedule / response anchor | Addressed: complete absolute next-UTC-day-plus-delay target is clamped; parser and resource success carry the post-response date. No midnight/live timing pass asserted. |
| R8 deletion result | Failure is now awaited/generation-checked and surfaced, but S1 replaces the prior silent-failure defect with unauthorized resume. |
| R9 pagination | Addressed: raw page entry count advances offset; decode and service dedupe separately; twenty-page cap is exposed. Mutable-provider offset consistency remains an API limitation. |
| R10 expired keys | Addressed: `include_expired=true` alongside disabled keys; hash/name selection survives missing pages. |
| R11 hotkeys | Two-phase release/acquire, physical identity, duplicate recorder rejection and problem retry are present; S7 reopens fallback across recorder suspension. Native Carbon behavior remains unverified. |

Prior tester failures: the app-side Models `summary` description was renamed `layoutSummary`, removing the identified stored-property/String-method collision in source. Formatting changes are present, but build/lint results belong exclusively to the tester. Cancellation during credential validation is checked before queueing a save; queued saves check change-generation before writing, and deletes preserve ordering. Strict decimal-string parsing replaces prefix parsing; reported BYOK distinguishes absent/null from malformed and rejects the latter. Hashes require 64 ASCII hex. Raw-count pagination and both dedupe layers address the prior key-page failures. Numeric decoding now clamps chart days to 7…30, Credits refresh to 5…60 and Models sync to 15…360. None of the prior test results are relabeled as passing by this review.

## Interpretation and feature-completeness assessment

**Automatic 8-point contact:** agree with pass2's distinction as a justified reconciliation of the user's restore rule and deliberate snap exception. Every automatic push ends at boundary+8; treating all unchanged pushed windows as deliberate snaps would expand previously unsnapped windows on close. Existing unchanged unsnapped windows should restore, while changed/new contact and unchanged previously snapped windows should follow. Keep regression cases for all four categories. This is an interpretation supported by the stated intent, not a new user decision. S3 is a provenance bug, not a reason to discard the distinction.

**Main-to-main changes:** applying the same conditional restoration ledger to width/edge changes is coherent. `ours` requires all four current frame components to match the accepted frame; user-moved windows do not revert to old main baselines. A new strip can still push a window it covers, which is necessary avoidance. No additional blanket edge-follow is applied to ordinary main resizing. This is source reasoning; actual dragging, readback and supersession need testing.

The fixed 360-point geometry, right-side mirroring, left-from-bars rule, originating display context, logical reservation independent of alpha, one-session cross-display handoff, explicit close/Escape/global shortcut, hidden retained session, content replacement identity and hosted-tree teardown all have production wiring. No outside-click or timed dismissal is introduced. Origin widget removal/hidden placement, panel disable and display disconnect close the session. Off/trust-loss paths drop the ledger; quit releases then stops avoidance and coordinator tasks. Geometry identity uses live AX equality, PID/launch date and display frame, not titles or persisted IDs. The AX readback is immediate and bounded, so asynchronous acceptance is not established.

The widget-kind/default/coding/view/editor/metadata/style/builder/service switches are wired. Models offers repeatable lists, summary, presets and all four layouts; hidden block options remain in the layout and dictionary. Top-level `details` defaults when absent and retains custom background when inheritance resumes; released fields stay required. Grouped gallery metadata is now implemented. Source presence cannot establish compile exhaustiveness or released fixture success.

Swift ownership is generally coherent: Core snapshots are Sendable, app observables/main-actor work follow package isolation, transport/normalization/Security work use concurrent boundaries, resource tasks use existing scheduling primitives and cancellation checks prevent ordinary late publication. Resource policy removal cancels wakeups while retaining successes/deadlines; browser search keys/orders are normalized per snapshot with lazy stable-ID rows. Remaining cooling defect is S5. `load` still decodes after transport returns before the caller's cancellation check, so cancellation can allow a bounded obsolete decode; its practical CPU impact is unmeasured. HTTP caps are post-download parse caps, not streaming memory limits. No idle/memory/latency budget is proven.

## Native/API boundaries and safe next validation

The legitimate `AppComposition` seam now supplies configuration URL, transport, key store and avoidance predicate. Debug arguments can select a temporary config, loopback transport, separate disposable Keychain service and restricted bundle ID; release uses standard composition. These controls are independent and default to real dependencies when omitted. A fresh config path alone is insufficient: absent/invalid config creates smart-avoidance/default widgets, and startup asks for AX access when avoidance is enabled. Tester must prepare valid temporary config with avoidance OFF, explicit fake/in-memory or disposable credential storage, and verified local transport; use only the permitted fixture app if already-granted AX access allows it. Do not use `make dev`, grant permissions or launch using guessed/missing isolation arguments. No isolated launch was attempted here.

Native-only open questions remain:

- Nonactivating text entry, keyboard editing/IME, Escape with marked text, VoiceOver and focus on reopen. Focus return captures **application** PID/launch date, not a prior window identity (`DetailsPanelController.swift:197–239`). It attempts app activation only when details was key and that app remains frontmost. Exact prior-window return is not demonstrated by this source or by the activation API; test two windows of the same app and switching apps before close. Do not call this an exact-window restoration implementation without evidence.
- Zero-duration animator retargeting (`DetailsPanelController.swift:244–249`) expresses settling intent but does not itself prove cancellation of a native entrance animation. Test rapid open/hide/show/close, display/edge changes and Reduce Motion. Logical reservation no longer depends on animation alpha.
- On-screen bounds matching, twins and failed AX reads, process/window disappearance, current Space changes, full-screen exclusions, accepted-frame timing/minimum-size refusal, self-generated notifications and drag deferral. A restriction predicate limits the apps affected; it is not a fake AX apply/readback adapter. Pure geometry cannot prove the live ledger.
- Occlusion on opening, screen lock/wake, sixty-second demand grace, immediate hidden rendering freeze, retained scroll after hide/resume, short cover grace, no-demand requests/wakeups, realistic catalogue decode/search/scroll latency and retained memory. No screenshot, timing, energy or memory result was collected.
- Authenticated financial reconciliation and paging under concurrent account changes are deferred under the prohibition on private-account calls. Fake tests establish app logic only. Public catalogue observations and documented contracts must not be described as authenticated validation.

Primary evidence rechecked without API calls: [OpenRouter activity](https://openrouter.ai/docs/api/api-reference/analytics/get-user-activity-grouped-by-endpoint) documents completed UTC days, account/workspace aggregation and SHA-256 key-hash filtering; [key list](https://openrouter.ai/docs/api/api-reference/api-keys/list-api-keys) documents offset/default-workspace and expired-key inclusion; [management keys](https://openrouter.ai/docs/guides/overview/auth/management-api-keys) supports the management capability and guide's 100-entry page convention. [Credits](https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits) and [Models](https://openrouter.ai/docs/guides/overview/models) were also rechecked. These contracts support the read-only app scope; no private query or inference was sent.

Apple web documentation supplied little readable contract text. Installed Xcode SDK primary evidence: `CoreGraphics.framework/Headers/CGWindow.h:137–145` defines on-screen enumeration; `AppKit.framework/Headers/NSWindow.h:184–189,982–984` defines occlusion/notification semantics; `AppKit.framework/Headers/NSRunningApplication.h:129–144` explicitly makes activation a non-guaranteed attempt. Public reference pages: [on-screen list option](https://developer.apple.com/documentation/coregraphics/cgwindowlistoption/optiononscreenonly), [window visibility](https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.struct/visible), [activation](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(from:options:)). None proves real CG/AX identity correlation, lock behavior, editing or focus return.

## Root handoff / stop point

Prioritize S1/S2 safety, then S3 restoration provenance. Route S4–S7 to Opus with the specified complexity. Tester owns meaningful regression traces and all `make`/native/performance evidence. Keep source-contract changes explicit, particularly automatic contact and shared manual pacing. Source-review readiness remains blocked; no final production acceptance is asserted. This review stops here with the immutable production snapshot preserved.
