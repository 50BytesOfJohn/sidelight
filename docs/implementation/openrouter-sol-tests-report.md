# Preliminary OpenRouter WIP testing report — 2026-10-13

## Production diagnostics first

This is feedback on **immutable partial production snapshot `438dd799fd2581e5ef93fc30b6395423542d7d57`**, relative to baseline `512173986c441629a4157e063fe520decbe2365f`. Opus stopped at quota without a completion handoff or validation. These findings are **not final acceptance**, and this report does not claim implementation completion.

### Build: fails in new production code

`make build` initially could not write the Swift/Clang user caches under the filesystem sandbox. A normal authorized escalation resolved that environmental blocker and reached production compilation. Captured compiler diagnostics:

| Location | Diagnostic |
|---|---|
| `Sources/Sidelight/Widgets/OpenRouter/OpenRouterModelsBuilder.swift:108:13` | `Picker` selection resolves to `@Sendable (Predicate<Character>) throws -> [Character]`, which cannot conform to `Hashable`. |
| Same file `108:50` | Cannot assign to `summary`: get-only property. |
| Same file `108:58` | Dynamic key-path member lookup cannot refer to instance method `filter`. |
| `Sources/Sidelight/Widgets/OpenRouter/OpenRouterModelsWidget.swift:138:91` | Cannot convert the `String.filter` function type to `OpenRouterModelFilter`. |
| Same file `138:57` | Same conversion failure for the count argument. |

The compiler also reported the two per-file compile commands and whole build as failed. The exact underlying lookup/isolation cause is not established by these diagnostics alone. The full log is `/tmp/openrouter-sol-build.log`. Core compiled; the full app did not. No source was changed to make it compile, and the same failed production invocation was not repeated.

### Lint: 11 production diagnostics

`make lint` exited nonzero. Captured locations:

```text
Sources/Sidelight/Panel/PanelRootView.swift:68:103: [AddLines] add 1 line break
Sources/Sidelight/Panel/PanelRootView.swift:104:103: [AddLines] add 1 line break
Sources/Sidelight/Services/RemoteResource.swift:136:9: [OnlyOneTrailingClosureArgument] revise call using both closure arguments and a trailing closure
Sources/Sidelight/Widgets/OpenRouter/OpenRouterCatalogueView.swift:279:1: [LineLength] line is too long
Sources/Sidelight/Widgets/OpenRouter/OpenRouterCatalogueView.swift:280:1: [Indentation] indent by 4 spaces
Sources/Sidelight/Widgets/OpenRouter/OpenRouterCatalogueView.swift:280:29: [AddLines] add 1 line break
Sources/Sidelight/Widgets/OpenRouter/OpenRouterCatalogueView.swift:281:1: [Indentation] unindent by 4 spaces
Sources/Sidelight/Widgets/OpenRouter/OpenRouterCatalogueView.swift:282:1: [Indentation] unindent by 4 spaces
Sources/Sidelight/Widgets/OpenRouter/OpenRouterCatalogueView.swift:283:1: [Indentation] unindent by 4 spaces
Sources/Sidelight/Widgets/OpenRouter/OpenRouterCreditsWidget.swift:142:111: [AddLines] add 1 line break
Sources/Sidelight/Widgets/OpenRouter/OpenRouterCreditsWidget.swift:143:1: [Indentation] unindent by 4 spaces
```

Full log: `/tmp/openrouter-sol-lint.log`. All named files belong to the production delta from the supplied baseline. I did not run source formatting. `make check` cannot pass these known lint/build gates; a redundant invocation was not made. Its full production test stage remains deferred.

## Executed behavioral failures and requests for Opus

Failures below are from compiled tests using unchanged production copies. They are unsuppressed assertions, not expected failures. Priorities are preliminary triage for the next production pass.

| Priority | Reproduction / observed behavior | Production location and requested fix |
|---|---|---|
| P0 | Full app does not compile; production lint fails. | Resolve every compiler/style diagnostic above, then let Sol rerun the full gates. |
| P1 | Cancelling `saveKey` while fake validation is suspended still performs a credential save after its reply. | `OpenRouterService.swift:272–285`, `302–325`: check cancellation after validation and before queued writes/publication; preserve change-generation ordering. Test: `cancelled validation never saves a credential`. |
| P1 | A Credits-only config in `previewsEveryWidget` demands balance and account activity. | Core `OpenRouterSettings.swift:426–431`: Credits previews must use mock/placeholder data and avoid private demand. Test: `credits previews never demand private resources`. |
| P1 | A snapped unchanged window restores its old width, y and height when the baseline already touches the returning boundary. Example: before `(208,30,600,700)`, accepted/current `(368,100,600,500)`; close should follow to `(208,100,760,500)`, retaining current far edge `968`. | `ReservationTransition.swift:180–191`: apply edge-follow before whole-frame restoration per handoff priority. Test: `edge follow takes priority over whole frame restoration`. No AX operation was performed. |
| P1 | Balance string `12garbage`, activity usage `1oops`, and token price `0.5oops` are accepted as numbers. | `OpenRouterAPI.swift:225–230`, `OpenRouterModel.swift` token-price initializer: require full valid finite decimal strings. Tests: malformed balance/activity, invalid token price. |
| P1 | A present malformed `byok_usage_inference` becomes an absent amount and the activity answer succeeds. | `OpenRouterAPI.swift:284–298`: distinguish legitimately missing BYOK from an unreadable reported amount; do not claim complete financial ingestion from that answer. Test: `partial financial activity cannot claim a complete total`. |
| P2 | After balance returns 401, newly demanded automatic activity still sends another private request with the same rejected credential. | `OpenRouterService.swift` demand/fetch handling: coordinate 401/403 pause across the connection until credential generation changes. Test: `auth rejection pauses new automatic private scopes until credential changes`. |
| P2 | A 100-row key page containing the same hash 100 times produces 100 entries; the duplicate entries survive the next page. | `OpenRouterService.swift:399–400`: dedupe both within and across pages while advancing pagination by the provider's raw page count. Test: `key picker deduplicates within a page and loads additional pages explicitly`. |
| P2 | Hashes `nothex` and `123` are accepted and used by selected-key requests. | `OpenRouterAPI.swift:84–85`: align validation with the handoff's expected 64-hex shape. Test: `selected key hash must be 64 hexadecimal characters`. The shape is a documented/prep expectation, not authenticated empirical evidence. |
| P2 / contract interpretation | Hand-edited chart days `-10` become `1`. Credits/models cadence `0` becomes `1`, and `999999` becomes `10080` minutes. | `OpenRouterSettings.swift:18,45,78,296`: tests interpret AGENTS' clamp-to-UI-range rule as chart 7…30, Credits 5…60, Models 15…360. Current UI expands pickers to stored values. Root/Opus should align the ranges or explicitly resolve whether custom intervals outside the advertised options are intended; do not silently weaken tests. |

11 newly added test functions fail, producing **21 assertion issues** (some parameter cases or functions assert more than one invariant). These are partial-WIP findings, not claims of regressions in an already completed feature.

## Test changes and exact local commit

Branch: `test/openrouter-widgets`.

**Test-only commit: `bcc99a0f359d6e7406cb5dce4e46bda88151b914`.** Ten files under `Tests/`, 1084 added lines. This report and copied planning/research docs are deliberately untracked and not part of the commit. No push, PR, GitHub message or merge occurred.

Added **60 Swift test functions**, including parameterized cases, in six files / seven suites:

- `OpenRouterAPITests`: public/private request separation, explicit activity scope, key pagination query, signed decimal balance, partial/malformed financial answers, catalogue tolerance/deduplication, key disabled/expiry metadata, HTTP error/retry advice, response caps and bounded Retry-After.
- `OpenRouterModelTests`: exact token scaling, zero versus free variant, strict text modality filters, unknown modalities, stable sorting/unknowns-last, filtered limits, folded multiword search, safe links, UTC/DST/leap completed-day boundaries.
- `OpenRouterConfigurationTests`: approved defaults, unknown enum fallback, numeric-range interpretation, repeatable preset identity and hidden option retention, orphan options, old top-level config defaults, inherited/custom style retention, non-default config round-trip, advertised sync intervals, merged visible demand and no key-scope fallback.
- `DetailsGeometryTests` / `ReservationTransitionTests`: all four originating edges, fixed 360 pt and narrow-screen clamp, negative/translated display coordinates, one main→details decision, composed baseline/readback, unchanged versus changed frames, literal and 8 pt-gap edge following, mirrored right edge, bar return, cross-display skip, avoidance-off and tolerance.
- `RemoteResourceTests`: zero fetch without demand, initial Manual fetch, in-flight coalescing, cache retention/resume, minimum manual gap, cancelled/replaced responses and spinner ownership, stale-success retention, auth pause within one resource, Retry-After persistence and reset generation.
- `OpenRouterServiceTests`: fake public transport without key-store reads, shared credential read, late-answer cancellation, removal generation, inference-key rejection, cancellation and save/remove ordering, selected-key disappearance without account fallback, explicit key pages/deduplication and connection-wide auth pause.

Updated `ReleasedConfigurationFixture.swift` with non-default Credits, Models/repeatable lists, details style and close shortcut, using deterministic fixture IDs. **Historical released JSON fixtures were not rewritten.** No new file is presented as an already-published release. The future writer was exercised only in scratch storage.

## Commands, outcomes and evidence

| Command / run | Result |
|---|---|
| `make build` | Initial sandbox cache failure; normal escalation then captured the production compile failures above. |
| `make lint` | 11 production diagnostics above. |
| `make -C Tests/OpenRouterHarness lint` | Pass: strict Swift format lint for all changed Swift test files plus Python AST parse. |
| `make -C Tests/OpenRouterHarness test ARGS='--directory /tmp/openrouter-sol-validation-complete'`, followed by `make -C /tmp/openrouter-sol-validation-complete test` after final test-only updates | Isolated sources/tests compile with warnings as errors. Final runner reports **447 Core tests in 81 suites**, 17 issues; **15 service tests in 2 suites**, 4 issues. Total 462 runner-reported tests, 21 issues. The ordinary full run skips the opt-in release-fixture writer. All failures are in new feature tests; all existing Core test suites passed. Existing full app test suites are not covered by this service slice. |
| `SIDELIGHT_RELEASE_FIXTURE=openrouter-validation make -C /tmp/openrouter-sol-validation-complete test TEST_ARGS='--filter ReleasedConfigurationFixture'` | Pass: one opt-in writer test; non-default configuration round-trip succeeded. Output JSON exists only in the disposable package. |
| `make -C Tests/OpenRouterHarness release-tests` | Pass: all 13 existing Python release tests. The first direct sandboxed Python attempt failed on Swift cache access / wrong SDK selection; the make-based Xcode-selected escalation resolved it. This was an environment issue, not an observed release regression. |
| `git diff --check` | Pass. |
| Byte comparison of scratch production copies | **74 Core Swift files and six app/service files identical** to source in this worktree. |
| `git diff 438dd799fd2581e5ef93fc30b6395423542d7d57 -- Sources Resources Package.swift` | Empty after the test commit. Production snapshot preserved. |

The test-only package copies Core, existing Core tests/fixtures and selected unchanged service files into a disposable directory. It uses Swift 6.4, macOS 26 and the same concurrency/main-actor settings through `make` selecting Xcode 27. It excludes SwiftUI views/composition root; it cannot prove full-module name resolution, linkage or app behavior. It introduces no test branch into production.

An initial harness run forgot `Tests/Fixtures`, producing eight unrelated missing-fixture errors. The harness was corrected and those existing OpenCode tests passed. Those eight errors are **not production findings**. Final authoritative test log: `/tmp/openrouter-sol-tests-complete.log`; earlier corrected full-copy log: `/tmp/openrouter-sol-tests-final.log`. Release log: `/tmp/openrouter-sol-release-final.log`; fixture-writer log: `/tmp/openrouter-sol-fixture.log`. Scratch package/artifacts remain `/tmp/openrouter-sol-validation-complete`; temporary paths are local evidence, not durable CI artifacts.

## Native limits, remaining seams and deferred acceptance

**No app launch, native screenshot or product performance measurement was performed. No native E2E pass is claimed.** `make dev` was not used because it kills the installed app and would not isolate config, Keychain or AX effects. New service tests use only fake transport and in-memory credential adapters; private financial APIs, management capability, real balances, paging consistency and real-account reconciliation remain empirically unvalidated. Catalogue fixtures are synthetic rather than a live capture.

Precise production seam request for a later safe app pass: `AppController.init()` at lines 22–48 constructs `ConfigurationStore()`, `OpenRouterService()` and unrestricted `WindowAvoider()` directly. Support an ordinary composition injection for a temporary configuration URL, fake service transport/key store and restricted avoider. `WindowAvoider(includes:)` already supports narrowing to a disposable application's PID/launch identity; use it rather than adding a second window mover. I did not add source seams or fabricate that they are available at app launch.

Deferred gates:

1. Opus completes/fixes production, then Sol reruns actual `make build`, `make lint`, full `make test` and **`make check` with zero warnings**. Re-run contract tests after changes; cherry-pick/rebase the test commit rather than altering the frozen production snapshot here.
2. In an isolated native launch: generic close button, focused Escape, configurable global close shortcut/conflicts, toggle hide/resume preserving session/query/scroll, no outside/timer close, originating display, fixed width, inherited/custom styling, titleless and all four widget layouts, keyboard search/edit/copy/paste/undo, focus return, VoiceOver/IME/dictation.
3. Only restricted disposable windows: trust-off behavior without changing permissions, accepted AX frame readback/refusal/minimum-size fallback, exact transition count, composed restore layers, drag/supersession, vanished/PID-reused windows, display removal/orientation, full-screen and current-Space safety. Pure geometry tests do not establish the live ledger, window identity, OS acceptance or active-Space matching.
4. Lifecycle and performance: five-second underlying-panel grace, immediate global-hide stop, sleep/lock grace, hidden rendering/coarse clocks, idle request/wake-up counts, decode/filter latency with a realistic full catalogue, retained memory, cached open latency and native scrolling/animation. Real-clock service tests observe bounded behavior only; they do not exhaustively simulate multi-day monotonic/UTC transitions. A controllable monotonic scheduling seam would help deterministic deadline coverage if further production work introduces it.
5. Authorized private-account reconciliation is a separate future empirical gate; nothing in mock tests proves current private endpoint contracts or complete financial ingestion.

No real windows were moved; no permissions granted/revoked; no user config, account or credential was changed. The primary worktree was not edited. Independent source review remains separate from this tester report. Root should route the production diagnostics and failing contract tests to Opus when available.
