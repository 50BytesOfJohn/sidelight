# Runware widget research

Researched 2026-10-21. Research only; no widget implementation or configuration changes.

## Recommendation and feasibility

Use the existing shared Accounts system with two credential sources: a saved API key and a read-only **Runware CLI** app sign-in. Prefer native HTTP requests for monitoring, including when using the CLI's saved key. This matches Railway's credential reuse and OpenRouter's balance/usage architecture, and avoids spawning a process for every refresh.

A balance-only minimal widget, rolling usage, usage charts, and a searchable models details view are feasible from documented interfaces. **A complete account-wide generation/task history is not established:** public documentation provides lookup of a known task UUID, not enumeration of past tasks. Do not describe a daily usage chart as generation history. Resolve this gap with Runware before promising the full requested history view.

Evidence levels below distinguish documented API behavior, inspected CLI implementation, and design recommendations. No authenticated requests were made, no generations were submitted, no CLI was installed, and no local credential files were read. `runware` was not on this research process's PATH; that does not establish whether it is installed elsewhere on the Mac.

## API surface

### Connection and authentication

[Authentication documentation](https://runware.ai/docs/models-api/authentication) specifies `POST https://api.runware.ai/v1`, JSON content type, and an array of task objects. Send `Authorization: Bearer <key>`; payload authentication is also supported. WebSockets use `wss://ws-api.runware.ai/v1` and authenticate first. HTTP is the better fit for Sidelight's occasional reads; a permanent socket is unnecessary.

Create separate keys through Runware's API Keys page. No separate OAuth/refresh-token flow is needed for the inspected CLI. Whether every organization role/key may read account management still needs an authenticated permissions check; do not import OpenRouter's “management key” requirement into this provider.

### Balance and usage

The [account management reference](https://runware.ai/docs/models-api/account-management) documents `taskType: accountManagement` with a fresh UUID v4:

| Operation | Data |
| --- | --- |
| `getDetails` | Organization identity; `balance.amount`, optional `freeBalance`, `currency`; team/key metadata; `usage.today`, `last7Days`, `last30Days`, `total`, each with `credits` and `requests`. |
| `getUsageActivity` | Request counts and spend grouped by `date`, `model`, and/or `apiKey`; `usage.timeseries`, `usage.model`, `usage.apiKey` hold `data` and `meta`. |
| `getUsagePerformance` | Per-model average/p90/p99 inference time. |
| `getUsageErrors` | Client/server errors and error-rate summaries. |

Usage windows are inclusive dates, at most 30 days; optional model AIR/key UUID filters allow up to 100 entries each. Day bucketing accepts an IANA timezone, default UTC. Activity rows contain bucket counts/spend, not task UUIDs. Rollups include total requests/results/spend and estimated average/projected spend. Longer views would require multiple nonoverlapping windows, subject to retention verification.

The [pricing reference](https://runware.ai/docs/models-api/pricing) says monetary amounts are USD and `includeCost` returns a task's charged cost. It also exposes model schema pricing via `info["x-pricing"]`. Preserve currency from a structured balance response. Show free credits separately until Runware confirms whether `amount` includes them; adding the two could double-count. Counts should be labelled “requests,” not “images” or “generations”: tasks can produce multiple results.

### Individual tasks and history

[Task Details](https://runware.ai/docs/models-api/task-details) documents `getTaskDetails` with the **existing task UUID**, returning original request/response payloads. Its UUID identifies the inspected task, unlike the fresh correlation UUID used by most reads. Payloads vary by original task type; missing content must remain representable.

[Task Polling](https://runware.ai/docs/models-api/task-polling) documents `getResponse` for a known async task UUID, with per-generation `processing`, `success`, and `error` states and partial results. Neither interface discovers unknown task IDs. The researched account API operations and CLI command tree did not reveal an account-wide task-list/history operation. This is a research limitation, not proof that no private or future endpoint exists.

The [ZDR reference](https://runware.ai/docs/models-api/zero-data-retention) confirms that the dashboard has a usage log with UUID/model/date/cost metadata. That is evidence of a web feature, not a supported listing API. Under ZDR, request/response payloads are not retained; ordinary output URLs last seven days, while ZDR output TTL defaults to 60 seconds. A recovered metadata entry therefore does not guarantee a preview or reusable request.

Recommended product handling: provide **Usage** with daily spending/request history now; reserve **Tasks** for a verified listing source. A manual UUID lookup could be offered separately, but cannot satisfy automatic history. Ask Runware for a supported paginated task-log endpoint, filters, retention, and permission requirements. Avoid scraping dashboard sessions, shell history, or arbitrary output folders. Webhooks would require generation callers to opt in and a receiver; they cannot recover previous account-wide activity.

### Models

[Model Search](https://runware.ai/docs/models-api/model-search) documents `taskType: modelSearch`: optional search, source (`official`/`community`), category, architecture, capabilities, visibility, sorting, and offset/limit pagination (20 default, 100 maximum). Results carry model name/AIR, version, architecture, metadata and `totalResults`. Empty-search API sorting defaults to popularity; nonempty search defaults to relevance. Newest-added sorting is available. The examples and parameter tables disagree on some older fields/visibility values, so begin with the current parameter table and validate responses.

A details browser can therefore search and page on demand, copy AIRs, and distinguish “Models used” (usage breakdown) from “Available models” (catalogue). Prices and thumbnails should be optional enrichment, not prerequisites for listing. Do not assume a single uniform per-generation price across modalities.

## CLI: inspected behavior and compatibility risks

Inspected the official repository at commit [`093cdef75732f0729d5b127baeb36b791157eb06`](https://github.com/runware/runware-cli/tree/093cdef75732f0729d5b127baeb36b791157eb06), committed 2026-10-19. Links below are pinned to that revision; installed releases can differ.

The [CLI overview](https://runware.ai/docs/tools/cli) documents table/JSON/YAML output, WebSocket default transport and an HTTP option. For a monitoring subprocess always choose JSON and HTTP explicitly, capture stdout separately from progress/log stderr, impose a timeout, and cancel it when demand disappears.

| Command/source | Confirmed behavior |
| --- | --- |
| [`account details`](https://github.com/runware/runware-cli/blob/093cdef75732f0729d5b127baeb36b791157eb06/internal/cmd/account/details.go) | Calls `accountManagement/getDetails`; JSON is a flattened object with `organization_name`, `organization_uuid`, numeric `balance`, `usage`, `team`, `api_keys`. It is not the raw API `data` envelope. Usage period names remain camelCase. |
| [`account` command registration](https://github.com/runware/runware-cli/blob/093cdef75732f0729d5b127baeb36b791157eb06/internal/cmd/account/account.go) | Registers only `details`. The API docs' `runware account getUsageActivity`, `getUsagePerformance`, and `getUsageErrors` examples are not implemented here. |
| [`model search`](https://github.com/runware/runware-cli/blob/093cdef75732f0729d5b127baeb36b791157eb06/internal/cmd/model/search.go) | Requires `--search`; supports category, architecture, type, tags, conditioning, visibility, limit/offset. JSON stdout is a model array; total count is printed to stderr. Does not expose current API source/capability/sort fields. |
| [`result <taskUUID>`](https://github.com/runware/runware-cli/blob/093cdef75732f0729d5b127baeb36b791157eb06/internal/cmd/run/result.go) | Polls an existing task through `client.Poll`, with a default two-second interval; automatically downloads unless `--no-download` is supplied. Not a history list. Despite the Task Details page's CLI example, this code does not call `getTaskDetails`. |
| [`auth login`](https://github.com/runware/runware-cli/blob/093cdef75732f0729d5b127baeb36b791157eb06/internal/cmd/auth/login.go), [`auth status`](https://github.com/runware/runware-cli/blob/093cdef75732f0729d5b127baeb36b791157eb06/internal/cmd/auth/status.go) | Login verifies an API key and saves it. Status performs a network check and reports a masked key plus `valid`/`invalid`/`unreachable`/`not configured`; this need not be polled separately from fetching data. |

Read-only command examples for later validation:

```sh
runware account details --format json --transport http
runware model search --search flux --limit 20 --offset 0 --format json --transport http
runware result <known-task-uuid> --no-download --format json --transport http
```

**Balance schema mismatch:** the CLI's [`AccountResult`](https://github.com/runware/runware-cli/blob/093cdef75732f0729d5b127baeb36b791157eb06/internal/api/types.go) declares `balance` as `float64`, while current API documentation specifies an object. If the server sends that documented object, this CLI decoder will fail. Native Sidelight decoding should deliberately support both shapes and preserve unknown/missing values rather than showing zero. Confirm actual server behavior and release versions before treating subprocess output as reliable fallback.

**Credentials:** [`internal/config/config.go`](https://github.com/runware/runware-cli/blob/093cdef75732f0729d5b127baeb36b791157eb06/internal/config/config.go) uses `~/.runware/config.yaml`, top-level `api_key`, with `RUNWARE_API_KEY` taking precedence. It saves the directory/file with 0700/0600 permissions. This is an API key on disk, not a Keychain token or renewable session. Config/status displays mask it and cannot export the credential for native API calls. No named account profiles appear in the inspected config type.

Read the CLI config only through the provider's credential adapter, never a view, and never write it. Use a real YAML parser if reading it natively: this repo has no established YAML credential parser to copy, and line splitting would mishandle quoting/comments. Alternatively retain subprocess support for the baseline and require a Sidelight key for API-only features; that reduces feature parity and should be an explicit product tradeoff. A native parser plus common HTTP client is the stronger recommendation.

A Finder/login-launched app normally will not inherit an API key exported in an interactive shell. Do not source shell startup files to obtain one. Explain saved CLI login versus environment-only authentication in account setup. When executing the CLI, control inherited overrides so its credential/endpoint matches the account selected in Sidelight.

The official [README](https://github.com/runware/runware-cli/blob/093cdef75732f0729d5b127baeb36b791157eb06/README.md) offers a macOS Homebrew cask; the [installer](https://github.com/runware/runware-cli/blob/093cdef75732f0729d5b127baeb36b791157eb06/public/install.sh) supports arm64 and defaults direct downloads to `~/.local/bin`, with an install-directory override. Sidelight's existing executable locator covers Homebrew and that default directory. Installation is optional: API-key accounts must work without it.

Runware Serverless has separate app task/usage interfaces. The CLI's [`apps tasks`](https://github.com/runware/runware-cli/blob/093cdef75732f0729d5b127baeb36b791157eb06/internal/cmd/serverless/apps_tasks.go) explicitly describes a bounded recovery window, not persisted history. Do not use it as evidence for Models API generation history, or silently combine different usage products.

## Existing Sidelight patterns to follow

All paths below refer to the current working tree. The repository's conventions and widget checklist are in [SKILL.md](../../.agents/skills/sidelight-conventions/SKILL.md) and [adding-a-widget.md](../../.agents/skills/sidelight-conventions/adding-a-widget.md).

| Concern | Existing implementation and implication |
| --- | --- |
| Balance, charts, models | [OpenRouter widget](../../Sources/Sidelight/Widgets/OpenRouter/OpenRouterWidget.swift), [balance block](../../Sources/Sidelight/Widgets/OpenRouter/OpenRouterBalanceBlock.swift), [catalogue details](../../Sources/Sidelight/Widgets/OpenRouter/OpenRouterCatalogueView.swift). Closest UI precedent, including preview samples and stale values. |
| Shared fetch state | [OpenRouterService](../../Sources/Sidelight/Widgets/OpenRouter/OpenRouterService.swift) owns shared catalogue and per-account objects; [OpenRouterAccount](../../Sources/Sidelight/Widgets/OpenRouter/OpenRouterAccount.swift) shares resource state, pacing and credential invalidation across widgets. Mirror the ownership, not OpenRouter-specific API rules. |
| CLI plus keys | [RailwayService](../../Sources/Sidelight/Widgets/Railway/RailwayService.swift) discovers the executable/sign-in, reports it to Accounts, resolves keys per account, and fetches natively. [RailwaySignIn](../../Sources/SidelightCore/Railway/RailwaySignIn.swift) is the pure credential-decoding precedent. Runware needs no Railway token-renewal machinery. |
| Account identity | [Accounts.swift](../../Sources/SidelightCore/Configuration/Accounts.swift): `AccountProvider`, `AccountKind`, fixed app-sign-in IDs, defaults and reference removal. Add a Runware provider accepting keys and a fixed `runware.cli` identity. Widgets store `AccountID?`, never credentials. |
| Secrets and setup | [AccountStore](../../Sources/Sidelight/Accounts/AccountStore.swift), [AccountSecrets/AccountAccess](../../Sources/Sidelight/Accounts/AccountSecrets.swift), [AccountViews](../../Sources/Sidelight/Accounts/AccountViews.swift), [Accounts pane](../../Sources/Sidelight/Settings/AccountsSettingsPane.swift). Key accounts use Sidelight Keychain items; CLI sign-in stays externally owned and read-only. Use `AccountPicker`/`AccountMessage`, and report status/organization identity from real fetches. |
| Layouts | [WidgetLayout](../../Sources/Sidelight/Widgets/Framework/WidgetLayout.swift) has regular, compact, minimal and bar; the last two show one glanceable value. Support all four. |
| Details lifecycle | [DetailsSession](../../Sources/Sidelight/Details/DetailsSession.swift) holds request/content and computes resource demand; [DetailsPanelView](../../Sources/Sidelight/Details/DetailsPanelView.swift) renders shared chrome. Open using `DetailsPresenter` and placement. A details view must keep its own demand alive when it replaces the originating panel. |
| Service lifecycle | [AppController](../../Sources/Sidelight/App/AppController.swift) constructs services and computes visible demand; [AppEnvironment](../../Sources/Sidelight/App/AppEnvironment.swift) injects them. Use `DataService`, `RemoteResource`, `FetchSchedule`/other existing scheduling primitives; stop on hidden/sleep/lock demand loss. No singletons or new timer loops. |
| Process discovery | [ExecutableLocator](../../Sources/SidelightCore/Process/ExecutableLocator.swift) checks `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, independent of GUI PATH. A custom CLI installation location remains a future setup consideration. |

One important trap: default account resolution currently gives signed-in CLI preference specifically to Railway. Adding an `appSignIn` case alone will not give Runware that behavior. Extend/test the policy deliberately: explicit default first, then the intended CLI/key precedence; a widget naming a missing account must not silently switch identities. Include account references in use counting, removal, and default resolution.

Keep HTTP request/response types, problems, credential parsing and demand/settings logic in `SidelightCore`; observable service/UI stay in `Widgets/Runware/`. HTTP/file/process work belongs off the main actor. Drop cancelled and old-account responses. Do not share private model results across unrelated accounts, even when catalogue-like data looks public.

## Proposed widget and details behavior

These are recommendations, not implemented features:

- **Minimal/bar:** balance only, compact currency formatting and provider identity. No chart/model/task fetches. Zero balance is valid; absent/failed data is not zero. Keep freshness/error information available without expanding the glance.
- **Compact:** balance plus today's spend/request count and entry to details.
- **Regular:** balance and optional usage chart/summary. If customization expands into independently shown pieces, follow the existing block builder rather than accumulating unrelated switches.
- **Details / Usage:** selectable account, 7/30-day spending/request chart and models-used breakdown. Do not add independent error/performance polling unless those sections are actually visible.
- **Details / Models:** search/filter/page results on demand, optional private/owned scope, copy AIR and open model documentation. Load images only for visible rows if previews are added.
- **Details / Tasks:** requirement remains open pending discovery API. If shipped before then, explain the limitation and link to the dashboard rather than showing a misleading empty history. Known-UUID lookup can be a separate optional tool.

Recommended initial refresh policy: one shared account snapshot every five minutes while visible, manual refresh with pacing, usage refreshed when details opens and at most every five minutes while its current-day view is visible; completed-day data can be cached longer. Catalogue queries should be debounced and paged on demand, with bounded per-account cache. These intervals are product choices, not Runware requirements. Do not scan CLI files or launch commands continuously; recheck on demand/manual refresh, or use the existing file-watcher/coalescing primitives while active.

[Error documentation](https://runware.ai/docs/models-api/errors) defines a task-scoped `errors` envelope alongside HTTP status and optional `retryAfter`. Handle partial batch success, invalid key, permission denial, insufficient balance, rate limiting and network failure separately. Preserve a last successful value with stale state; rejected credentials should wait for replacement. Honor server retry advice and existing backoff. The [rate-limit reference](https://runware.ai/docs/models-api/rate-limits) describes organization-level REST limits; do not assume each key has an independent request budget.

## Before implementation is considered complete

1. With an authorized test key, verify the actual balance shape, free-credit semantics, permissions, rolling-period timezone, activity units/latency and date-boundary behavior. Capture sanitized fixtures, including missing optional fields. Confirm whether usage reads themselves affect request counts.
2. Check supported CLI release versions against the pinned source, numeric/object balance mismatch, JSON shapes and model pagination. Check sign-out/replacement, malformed YAML, executable missing, and environment-only auth. Do not use generation calls as connectivity probes.
3. Obtain a supported task-list interface or explicitly agree on the reduced history scope. Verify task lookup retention, errors, ZDR, expired media and whether cost is available when callers omitted `includeCost`.
4. Add provider/settings/widget/metadata switches, account references/default policy, app/environment/service wiring, and details demand. Keep released settings decodable with defaults and add non-default Runware settings to `Tests/SidelightCoreTests/ReleasedConfigurationFixture.swift`.
5. Test shared-account deduplication, credential invalidation, cancellation, stale data and retry pacing; use sanitized API/CLI fixtures for meaningful decoding/error coverage. Verify all four layouts, details replacement and preview behavior, and measure idle cost.
6. Build and validate through `make check`, as required by the repository; no raw `swift build`. Implementation UI work also needs real-app screenshots per `CONTRIBUTING.md`.

The immediate implementation path is clear for account-backed balance, usage and models. The outstanding product decision is how to meet generation-history expectations without an established public task-discovery interface.
