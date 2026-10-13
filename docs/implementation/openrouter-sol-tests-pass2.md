# OpenRouter Sol validation pass2 — 2026-10-13

## Result for root

**Not accepted.** Production snapshot `e56132feb0e06ac4a90575bc68b9a4262f004b2d` compiles and lints, but the actual full `make check` fails one new credential-cancellation regression (two assertion issues). Native validation is partial, with explicit isolation incidents and deferred gates below. This is the tester's report, not the separately assigned source review.

Branch `test/openrouter-widgets-pass2`. **Local test-only commit: `4244e02dc506778d0c652a2d4a82d7a24b959d46`.** Eleven explicit paths under `Tests/`, 706 insertions / 3 deletions. This report and supplied planning/handoff docs remain untracked. No production `Sources/`, `Package.swift`, `Resources/`, historical release JSON fixture, push, PR, GitHub message, merge, or subagent change.

Authority read: AGENTS, CONTRIBUTING, both Swift/project skills, implementation handoff, production pass2 handoff, prior Sol test report/review, and proposal §2 “Decided by you (2026-10-13).” The fixed separate details window and final user decision governed validation; old popup sketches did not.

## Production items to route to Opus

### P1 — cancelling a validated save while it waits for the serialized writer still writes it

Executed regression: `OpenRouterServiceTests.cancellation while a validated save waits in the write queue prevents the write`, assertions at `Tests/SidelightTests/OpenRouterServiceTests.swift:414–415`.

1. Fake validation succeeds for `first`; its in-memory credential write is held.
2. Validation succeeds for `cancelled`; its save waits behind `first`.
3. Cancel that caller, then release the first write.
4. Observed write events: `["first", "cancelled"]`; observed stored credential: `"cancelled"`.
5. Required: only `first` reaches the store. This cancellation occurs before the second side effect starts, not during an already-started Keychain operation.

This failed in each full run containing it; it is neither disabled nor marked expected. The test uses fake transport/in-memory credentials, a held continuation for the first writer, and a 30 ms allowance after validation before cancellation. No real credential operation is involved.

Production request: propagate the originating save's cancellation into the queued writer's admission check as well as credential-change generation. `saveKey` currently guards caller cancellation before queueing; the queued `Task` at `OpenRouterService.swift:427–439` checks only `shouldWrite` after awaiting the preceding writer. Preserve the passing save/remove/save ordering, generation-overtaken-write, and failed-delete/new-save tests. Sol must rerun the unsuppressed regression after Opus changes source.

### P2 — accepted loopback launch URL can fall back to the real public endpoint

Direct native observation: launching with `-SidelightOpenRouterURL http://127.0.0.1:<port>` (no trailing slash) produced the public catalogue (662 models) and **no loopback request**, although configuration isolation was valid. After supplying `http://127.0.0.1:<port>/`, the app showed the synthetic 240-model catalogue and the loopback server recorded `/models?output_modalities=all`.

Source explanation supporting the reproduction: `AppComposition.swift` concatenates the base string with a suffix stripped from `OpenRouterAPI.baseURL` (which ends in `/`). With no separator, the resulting authority/port is invalid; redirect construction returns the original request. This is a debug composition/isolation defect, not a private-account response defect.

Production request: normalize/compose accepted loopback bases and fail closed if redirection fails. A launch explicitly requesting isolation must not silently send the original request. The corrected test harness supplies a trailing slash; it does not patch or hide this source behavior. No private OpenRouter endpoint or real credential was used in this incident.

### Native builder/gallery isolation gap — concrete validation blocker

`WindowCoordinator.previewsEveryWidget` becomes true for Widgets **or any builder**. `AppController.observeServiceDemand` responds through general `serviceDemand(previewsEveryWidget: true)`, starting unrelated usage/session services. `AppComposition` replaces OpenRouter transport/key store and config/AX eligibility, but cannot replace those other services. Opening the real Models builder in this otherwise isolated launch could read unrelated local user data.

Production seam request: allow a legitimate composition to replace/restrict non-OpenRouter preview services, or narrow preview demand to the surface's actual kinds. Do not add test-only diagnostic branches. I did not open the manager/builder under the corrected launch. Repeatable Models builder controls, gallery financial example rendering, and the connection editor remain concrete deferred native gates.

## Actual build/check evidence

Xcode selected by `make`: `/Applications/Xcode.app/Contents/Developer`, Swift tools 6.4 / macOS 27 SDK. Builds use `-warnings-as-errors`.

| Gate | Actual result |
|---|---|
| `make build` | First sandbox invocation failed on normal Swift/Clang caches. Authorized cache/nested-sandbox escalation reached the compiler and **passed**, including the actual app. `/tmp/openrouter-pass2-build.log`. |
| `make lint` | **Pass** on the source snapshot. `/tmp/openrouter-pass2-lint.log`. |
| Final `make check` | Lint and actual app build **pass**; Swift test stage **fails** the cancellation regression. No compiler warnings in the final log. |
| Actual Core target | Runner reports **458 tests in 83 suites passed**. Includes old Core suites, config/round-trip checks, all historical released configuration fixtures, previous feature failures, and new pass2 cases. |
| Actual app test target | Runner reports **68 tests in 10 suites**, one failing test / **2 issues**. All other app tests, including old ConfigurationStore/service/session-index suites, pass. |
| Release tests, run separately because failing Swift tests stop `make test` before Python | `make -C Tests/OpenRouterHarness release-tests`: **13 passed**. `/tmp/openrouter-pass2-release.log`. |
| Test/harness lint | **Pass**: strict Swift formatting for focused tests/native measurement, Python AST checks. `/tmp/openrouter-pass2-harness-lint.log`. |
| Corrected native fixture preflight | Actual Core decoder + safety test **passes**; final `--prepare-only` also passed without launching. `/tmp/openrouter-pass2-prepared-final/preflight.log`, `/tmp/openrouter-pass2-native-preflight-final.log`. |
| `git diff --check` / production and historical-fixture comparison | **Pass / empty production diff** against `e56132…`. |

Authoritative final full log: `/tmp/openrouter-pass2-check-final.log`. Initial `/tmp/openrouter-pass2-check.log` had 457 Core / 61 app tests; intermediate `/tmp/openrouter-pass2-tests-final.log` contains a **test-author compile mistake** constructing `Display` with a nonexistent memberwise initializer. That test-only mistake was corrected using the actual `Display(NSScreen,isMain:)` API; it is not a production finding. Final actual modules compile. Copied-slice harness results were **not substituted** for actual app/Core suites in this pass.

No historical JSON was rewritten or fixture writer aimed at a release filename. The opt-in native preflight is test-only, not a released config fixture.

## Added pass2 coverage

All existing OpenRouter tests were retained. Compatible production wrappers preserved their legitimate call sites; no invariant was weakened to accommodate pass2. New tests cover:

- Whole valid decimal fractions/exponents, localized/partial/nonfinite rejection, exact financial parsing; null BYOK remains absent while malformed reported BYOK rejects the financial answer.
- Raw key page counts despite unreadable/duplicate entries; include-expired query, dedupe across pages, explicit offset progression, and visible 20-page traversal limit.
- Connection-wide 401/403 pause through new activity scopes, key paging and manual refresh; credential re-save resumes admission. Retry-After from credits **and key pages** gates all new private scopes. Scoped-key lookup rejection stops its activity request and subsequent paging.
- Cancellation during validation, late replies, queued write generations, the newly failing queued-cancellation case, failed deletion truth/retry, and stale failed deletion versus a newer save.
- Overdue UTC daily resume fetches once immediately; explicit response timestamps survive delivery across midnight; the service parser and resource share the answer-time day anchor.
- Details-only public demand when main contributes none; no private preview demand; browser replacement/reset; clock visibility state; real `NSEvent` special-key/modifier conversion, physical shortcut identity independent of labels, rejection of typing-only shortcuts.
- Main/details restore layers, accepted readback, main resize using the original layer, bar-axis release/reapplication in one decision, later hide, changed/new contact following, literal/8-point spacing, mirrored/translated geometry, and unchanged automatic unsnapped contact restoring.

### Edge-follow interpretation assessment

The handoff's exception is justified as a design interpretation, not newly confirmed user wording: automatic avoidance creates +8-point contact for nearly every pushed window, whereas the user describes deliberate snapping and unchanged restoration. Executed tests distinguish an unchanged unsnapped x=250 window pushed to x=368 (restores x=250) from a changed window contacting x=368 (follows to x=208, preserving the far edge). The previously snapped unchanged example still follows first and retains its current vertical frame/far edge. All these tests pass. This reconciles deliberate contact with unchanged restoration; it does not prove the live AX ledger, tiler intent, or minimum-size acceptance.

## Native observations — corrected isolated launch only

The built **actual debug executable** and its resources were copied to `/tmp/openrouter-pass2-native-final/SidelightPass2.app`. No production binary/source patch or signing identity discovery was used. Temporary config, loopback synthetic API, disposable key-store service namespace, avoidance OFF, and a movement predicate matching no real apps. Native PID was **72083**. Computer-use interactions and screenshots targeted this app only. The process is no longer running; no fixture child/server remains.

Directly observed:

- Actual Models widget listed 240 fixture models. “View all” replaced main with a separate details panel. Search initially took focus; typed `model-123` returned **1 of 240**. Clicking the match expanded context/modalities/pricing with its cost-scope caveat.
- Search/expansion caused no requests. Cached reopening after **Escape** used the retained catalogue and a **fresh closed-session query**. This checks close/reopen reset, not global hide/resume retention.
- Focused Escape and the generic close button each restored the main surface (close button tested with a top bar).
- Details stayed present through a long idle period (no timeout). Clicking the app's Edit menu outside details did not dismiss it; cancelling only that menu left details visible. PID-filtered on-screen bounds also confirmed its continued presence.
- A manual refresh from visible details after the main was hidden well beyond 60 seconds reached the loopback server and updated “synced just now.” This supports the fixed independent details demand on this single display.
- Read-only public window metadata: left details **x=0, y=30, 360×1662 pt**; right-origin reload **x=2648, y=30, 360×1662 pt**; top-bar-origin reload **x=0, y=30, 360×1662 pt**. Screen frame **3008×1692 pt**, visible frame **3008×1662 pt**, scale **2×**. Actual details width is fixed despite main widths 200/300. These are native metadata observations, not screenshot-pixel guesses.
- Native screenshots in the conversation show the inherited dark background, long-name clipping without row overflow, and the separate purple custom background after the temporary config changed. These screenshots were emitted by computer use; no standalone PNG file was saved.
- Adding Credits to the temporary config showed **“Add an OpenRouter management key”** with no fabricated balance. Only the disposable namespace was read; no key was entered, saved or deleted. The final server log has exactly **two Models GETs** (initial + explicit refresh), no private request.

Apple's installed primary SDK documents that `kCGWindowListOptionOnScreenOnly` enumerates on-screen windows; see [CGWindow.h](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/CoreGraphics.framework/Headers/CGWindow.h:137). The helper filters output to the disposable PID and prints public bounds plus `NSScreen` geometry. That contract is **not** evidence of reliable CG/AX identity correlation across Spaces.

Artifacts: `/tmp/openrouter-pass2-native-final/requests.jsonl`, `geometry.log`, `right-geometry.log`, `bar-geometry.log`, `outside-geometry.log`, `credits-geometry.log`, `native-unified.log`, config and preflight logs. The helper performs no AX mutation or screen-recording request.

### Idle evidence and limits

With Models-only main visible after Escape, Manual sync, static solid background/grain off, no user input and no unrelated services demanded: PID CPU time changed **2.46→2.47 seconds over 93 seconds**; sampled `%cpu` stayed 0.0. RSS changed **71,632→41,408 KiB**. Files: `idle-before.txt`, `idle-after.txt`. This is coarse `ps` evidence, roughly 0.01% average CPU at hundredth-second resolution. It measures the whole disposable process, not catalogue incremental memory, wakeups, hidden/sleep energy, or a before/after feature comparison. It does not establish the <5 MB retained-catalogue or <16 ms stall goals. No cached-open latency claim: native automation calls themselves took seconds to minutes.

## Isolation incidents — excluded from valid E2E evidence

1. **Tester harness mistake:** the first config used `length: "full"` instead of the actual `"fill"`. Production moved that temporary file aside, loaded defaults, and displayed local Codex information. I stopped the controlled process immediately after noticing. This was an unintended local-data read and a failure of the initial isolation procedure; I cannot honestly claim the entire pass avoided all live local data. No user config was edited. The movement predicate still matched no real apps, so it did not authorize real-window movement; no permission grant/revoke or credential entry occurred. Temporary fallback/trust behavior is not a native acceptance result. Evidence remains `/tmp/openrouter-pass2-native-live/`.
2. **Debug redirect fallback:** the next, valid-config launch omitted the URL trailing slash and fetched the real **public** catalogue rather than the fake API, as described in P2. It was stopped and excluded from fixture results. No private API/paid inference was called. Evidence `/tmp/openrouter-pass2-native-safe/`.
3. Final harness now fails before launch on decoder/safety errors, requires a new empty directory, and supplies the trailing slash. The final valid launch's request log and native text both confirm synthetic data. These corrections do not erase the incidents.

## Deferred gates and stop point

- Global close shortcut, live conflicts/swapping/fallback, and toggle hide/resume retaining query/scroll/expanded state. One `alt+super+s` native tool attempt did not visibly hide the panel; native input calls took up to several minutes. There was no isolated-app hotkey-registration failure in the inspected log. That attempt cannot distinguish tool event delivery from Carbon behavior and is **inconclusive**, not a proven source defect or pass. Physical recorder mappings passed tests; actual global delivery still needs a controlled native session.
- Models builder controls/repeated lists/presets, gallery example labels in every financial layout, and real connection editor: blocked by unrelated preview-service isolation above. Their Core options and demand tests pass; that is not native rendering evidence.
- Financial loading/error/stale-success/preview scopes are parser/service/demand-test evidence, plus native no-key setup only. Native fake-saved-money/error/preview rendering remains deferred; no real credential/private account or paid request may substitute.
- AX movement, accepted-frame/minimum-size/refusal behavior, self-notification suppression, drag supersession and real ledger safety; active Spaces/twin identities, display disconnect/multiple displays/fullscreen; sleep/lock/wake and focus return/IME/dictation/VoiceOver. No permission was granted to enable these; no real windows were moved. Pure geometry and one-display metadata do not prove them.
- Complete keyboard copy/paste/undo, stable scroll across refresh/toggle, accessibility navigation, motion/animation cancellation, hidden wakeup/energy measurements and incremental retained memory. No browser mock was used as native evidence.
- Private API page size/hash/expiry/BYOK completeness and real-account reconciliation remain documentation-contract assumptions exercised with synthetic answers, not authenticated validation.

Root should consolidate this report with the separate review, route the concrete production items to Opus Medium/High, and return revised source for Sol's failing-regression/full-check rerun and deferred safe native gates. **No acceptance claim while `make check` fails.**
