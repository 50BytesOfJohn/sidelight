# OpenRouter widgets: research handoff

Research date: **2026-10-12**. Checkout: `/Users/tom/Developer/repos/sidelight-worktrees/research-openrouter-widget`, branch `research/openrouter-widget`, base `2d21e62b4d7b0ef9c9e760d1bd0cbff175d7152f`. Requested research model/effort: GPT-6.1-Sol / Medium. This is evidence and implementation constraints for a later Opus 5.5 Medium design proposal, **not an approved UI or production implementation**.

Only this worktree was used. The primary checkout and its untracked research were not inspected or changed. No agents, design sessions, app launches, sign-in, credential searches, Keychain access, paid inference, commits, pushes, issues, PRs or messages were made. Read AGENTS.md, CONTRIBUTING.md, docs/VISION.md and the sidelight-conventions skill including adding-a-widget.md. The user explicitly reserved issue/implementation planning for after design approval.

## Decision summary

Two distinct widget kinds are feasible: **OpenRouter Credits** (account money; optional scoped spending) and **OpenRouter Models** (a block-built public catalogue). Share fetching and cached data across their instances, while preserving independent display/settings choices.

The required **account balance needs a management key according to current documentation**. An ordinary inference key can expose its own usage and remaining spending limit, which is a different quantity. Do not promise account money after accepting an ordinary key, or silently substitute key allowance. Management keys also unlock key selection and history. [Credits reference][credits], [current-key reference][key], [management guide][management].

The catalogue works **without any credential**, empirically verified. The default API response is text-output only; use `output_modalities=all` for the full catalogue, and explicitly distinguish strict text→text from models that accept text plus images/files/audio. `created` is documented as added-to-OpenRouter time in the guide, and `sort=newest` is supported. [Models guide][models-guide], [list schema][models], [public payload evidence](openrouter-poc/catalogue-evidence.json).

OpenRouter **does have an official CLI: Ori**. Its documented role is running agents/harnesses/evals; a stable balance/activity/catalogue JSON command contract was not established. Native direct HTTP remains the clearest fit for these read-only widgets. [Ori overview][ori], [Ori configuration][ori-config], [Ori changelog][ori-changelog].

The full searchable catalogue is a meaningful design decision: Sidelight's existing panel never becomes key. An inline search field cannot be assumed to work without an explicit focus strategy. An anchored, focus-capable transient surface deserves consideration across all orientations; replacing the entire panel introduces broader geometry/demand implications. Neither approach has been implemented or visually tested.

## Evidence labels and freshness

- **D — Documented:** current OpenRouter official docs or official source; not privately exercised.
- **E — Empirical:** exactly three unauthenticated public GETs and offline payload checks, captured today.
- **I — Inferred/proposed:** a Sidelight engineering/product recommendation, not an OpenRouter guarantee.
- **U — Unestablished:** absent from inspected evidence or requires authenticated/native validation.

The official documentation indices [API index][api-index] and [docs index][docs-index] were used, then current `.md` pages containing embedded OpenAPI schemas were fetched. Older indexed URLs sometimes redirect to newer canonical names. The official analytics skills repository was read **as research source**, not applied as instructions or executed. Those source notes explicitly say live `/analytics/meta` is authoritative for names. Private permissions and financial accuracy remain documentation-only.

## Evidence-linked capability matrix

All paths below are relative to `https://openrouter.ai/api/v1`. Private requests use `Authorization: Bearer <key>`; no such request was made during this research.

| Capability | Endpoint/data | Authentication and constraints | Evidence / consequence |
|---|---|---|---|
| Account credits purchased/used | `GET /credits`: `data.total_credits`, `data.total_usage` | Management key required; 401/403/500 described | **D** [credits][credits]. Remaining = purchased − used (**I**, arithmetic); label USD account balance, not key budget. |
| Current key usage and allowance | `GET /key` | Authenticated current key; ordinary key supported by guide; does not require management in operation description | **D** [key][key], [limits][limits]. `usage`, UTC daily/weekly/monthly usage, nullable limit/remaining/reset, BYOK counters, expiry and key-type flags. |
| List/select other keys | `GET /keys`, `GET /keys/{hash}` | Management key; list supports offset, disabled/expired inclusion and workspace filtering | **D** [list keys][keys], [single key][single-key], [management][management]. Selection retrieves metadata, not the selected secret. |
| Recent completed-day spending | `GET /activity` | Management key; last 30 **completed UTC** days; single-date filter, key hash, org member and workspace filters | **D** [activity][activity]. Sum endpoint rows by date locally; no today/live chart claim. |
| More flexible spending time series | `GET /analytics/meta`; `POST /analytics/query` | Management key; metadata discovery; query metrics, dimensions, filters, granularity, UTC range | **D** [meta][meta], [query][query], [official schema source][analytics-schema]. Daily credit-spend metric avoids conflating external BYOK spend. |
| Public catalogue | `GET /models` | Generic schema shows Bearer auth; guide publishes keyless curl examples; three keyless requests succeeded | **D/E** [guide][models-guide], [schema][models], [sample](openrouter-poc/catalogue-evidence.json). Credential-free first experience possible. |
| Truly all model types | `GET /models?output_modalities=all` | Default is `text`; includes other outputs only explicitly | **D/E** [guide][models-guide]. Observed 459 default entries versus 662 all entries. |
| Sort/filter/page catalogue | `/models` query parameters | `sort=newest`; optional offset/limit, max limit 1000; modality, search and other filters | **D/E** [schema][models], [guide][models-guide]. First 3 sorted rows and next-link shape verified; second page not fetched. |
| Personalised catalogue | `GET /models/user` | Authenticated user preferences/privacy/guardrails | **D** [user models][user-models]. Later scope; public listing is discovery, not assurance your key can use every model. |
| Provider detail | `GET /models/{author}/{slug}/endpoints` | Endpoint data is separate from summary Model data | **D** [endpoint reference][endpoints]. Do not poll one endpoint per visible row. |
| Single model detail | `GET /model/{author}/{slug}` | Guide describes alias resolution and 404 for unavailable IDs | **D** [guide][models-guide]. Singular `/model`, unlike plural provider-endpoint path. |
| CLI integration | Official `ori`; official analytics scripts also exist | Ori supports account login/agents; no inspected contract for these widgets' data commands | **D/U** [Ori][ori], [official analytics source][analytics-source]. API integration recommended; do not read another CLI's credentials. |
| Read-only management credential | No documented narrowly scoped read-only key found in inspected management guide | Management key can create/update/delete keys, not just observe | **D/U** [management][management]. Sidelight can be read-only but the credential has broader authority. |
| Cache validators/quotas | Public catalogue cache headers observed; errors may expose retry hints | No stable ETag/Last-Modified or metadata-endpoint numeric quota contract found | **E/U** [payload](openrouter-poc/catalogue-evidence.json), [errors][errors], [limits][limits]. Preserve conditional-header support if later supplied, without promising 304. |

## Financial semantics and credentials

### Balance and key budgets

`/credits` returns two totals rather than an explicit remaining value. Their difference is the recommended displayed account credit balance. Display as USD, ideally using decimal arithmetic/formatting; a missing/error response is unknown, never `$0`. Do not subtract key limits or sum all key budgets to obtain account funds. The official FAQ identifies USD as the credit system's currency. [Credits][credits], [FAQ][faq].

`/key` describes `limit` and `limit_remaining` as the key's own USD spending allowance; both can be null. Unlimited allowance means **no key limit**, not unlimited money. `limit_reset` can be daily/weekly/monthly or null. `usage` is lifetime credit usage; the daily, weekly and monthly counters are current UTC windows (weeks Monday–Sunday). `include_byok_in_limit` controls whether external BYOK usage counts toward that key limit. Separate `byok_usage*` fields must retain their meaning. [Current key][key], [limits][limits].

Newer `/key` schema also includes `budgets` and `effective_budget` for additional member/key-guardrail/workspace/key-limit layers. Even positive key allowance does not guarantee requests will be permitted. `is_management_key` is the current flag; `is_provisioning_key` and `rate_limit` are deprecated. Use these flags to explain setup, not the key prefix alone. A management key cannot make completions. [Key schema][key], [limits][limits], [management][management].

**Proposed setup choices:** catalogue-only needs no key. Account credits requires explicitly adding a management credential to Sidelight's own Keychain storage. An optional ordinary-key mode may be called **Key usage / budget** and clearly show its reduced capability; it does not satisfy the required account balance. If offered, selecting among multiple locally saved ordinary keys is a local credential picker; listing account keys is a separate management-key permission. Do not auto-detect keys in shells, files or other apps.

### Selection, workspaces and multiple instances

`/keys` gives hashes, names/labels, usage, limits, disabled/expiry information and workspace metadata. Only key creation returns a raw secret; key list/get cannot recover it. A management connection can therefore inspect an ordinary key by hash without storing that inference key. [List keys][keys], [single key][single-key], [create-key schema][create-key].

The list's default workspace is **not every workspace**. Explicit `workspace_id` filtering is documented; listing workspaces is a separate management operation. The guide describes pages of the most recent 100 keys with offset pagination, while the list schema exposes offset but no configurable limit/count/cursor. Start with the default workspace; do not claim “all account keys” unless all relevant workspaces and pages have actually been traversed. Disabled and expired keys need visible unavailable states rather than silently changing a saved selection. [Keys][keys], [management][management], [workspace listing][workspaces].

Store only credential reference UUID, friendly label, selected key hash and optional workspace ID in widget configuration (**I**). Keychain owns secret material. Separate connection identity from a widget UUID: duplicates can share requests, while two accounts never share balance, retry state or cached spend. Renaming a remote key should retain hash-based selection. Credential rotation must invalidate the connection's financial data before publishing new results; deletion must remove its cached private data. Never store raw Bearer tokens in configuration, fixtures or logs.

### CLI finding

The official Ori overview states that one `ori` CLI signs in to OpenRouter and supports Harness, Code and Eval tools. Configuration documents `ori auth` / `ori doctor`, regional/admin policies, credential storage and updater controls. This establishes official CLI availability; it does **not** establish widget-ready `credits --json`, `activity --json` or `models --json` commands. No binary was installed, located or executed. Public release/source/doc review cannot rule out additional live commands. [Ori overview][ori], [configuration][ori-config], [changelog][ori-changelog], [official release repo][ori-release].

Official analytics skill scripts wrap the management API with TypeScript tooling; they are useful evidence, but do not provide a dependency-free macOS CLI integration. Community `openrouter` CLIs found in search were not used as official capability evidence. Direct `URLSession`/`HTTP.send` avoids external process/updater/auth-file dependencies and works with Sidelight's existing cancellation/lifecycle architecture (**I**).

## Spending history: two supported paths

### Simple completed-day activity

`GET /activity` returns endpoint aggregates over the last 30 completed UTC days. A row has date, model, permanent model slug, endpoint UUID, provider name, request/token counts, `usage`, and `byok_usage_inference`. Optional `date` selects one UTC day; `api_key_hash` selects a key; `user_id` is for org accounts. Default rows aggregate across workspaces by date/model/endpoint. `workspace_id` scopes, and `group_by=workspace` adds a workspace split. Historical rows from before workspace resolution are permanently attributed to the default workspace, with no backfill. No start/end range, cursor or page limit is exposed for this operation. [Activity][activity].

For a 7/14/30-day **credit spending** series, group all returned rows by UTC date and sum `usage`; preserve external `byok_usage_inference` separately. Do not sum it into “credits consumed.” Official analytics source explicitly distinguishes billed credits from total including external BYOK inference. [Activity schema][activity], [analytics metric definitions][analytics-schema]. The arithmetic is inferred; authenticated reconciliation with credits/account dashboard is still needed.

Do not fetch 30 separate dates when one call returns the full supported window. Do not mark today's absent row as `$0`. After a complete, successful response one may choose zero filling for omitted completed days, but the empty-bucket contract was not established; empty/partial/error data must not manufacture zero spend. UTC bins should remain labelled UTC even if the user lives in another time zone. A sampled balance difference cannot reconstruct spending because credit purchases/refunds may change it (**I**).

### New analytics query API

The richer path is `POST /analytics/query` with `metrics: ["credits_usage"]`, `granularity: "day"`, explicit UTC start/end including seconds, optional key filter `{field: "api_key_id", operator: "eq", value: <hash>}`, and `order_by: {field: "date", direction: "asc"}`. Use `/analytics/meta` once per connection/schema TTL to verify available names. The schema resolves 64-character key hashes server-side; key/user/workspace dimensions in output can be human labels, so do not use output labels as stable selection IDs. [Query schema][query], [meta][meta], [official query notes][analytics-query]. No authenticated query was made.

Official metric source defines:

| Metric | Meaning | Documented source constraint |
|---|---|---|
| `credits_usage` | All charges billed to OpenRouter credits, including BYOK platform fees | Up to 367 days with suitable daily/coarser query |
| `total_usage` | Credit usage plus external BYOK inference cost | Up to 367 days; not account credit drawdown |
| `byok_usage` | External BYOK inference cost | Up to 367 days |
| `openrouter_usage`, `byok_fees` | Non-BYOK inference / platform fee breakdown | 31-day range |

These are **D from official source, not E**. Most volume/cost metrics and dimensions such as model, key, workspace support the longer range. Provider/raw-generation dimensions, performance metrics, classifier data and hourly granularity narrow it to 31 days. These are supported query-range limits; do not turn them into a promise of indefinite financial-record retention. [Official analytics schema][analytics-schema], [query notes][analytics-query].

`data.data` contains rows; count metrics can be strings while cost metrics are numbers. `metadata.truncated` matters: never report a capped result as a complete financial total. Schema exposes row limit (default 1000), optional group limit, max two dimensions and 20 filters; no offset/cursor appears in the inspected query schema despite source prose mentioning pagination. Split bounded time windows or increase limit only within documented limits if needed. A 7/30-day daily total without dimensions avoids multiplicative row growth. Cache responses can include `cachedAt` (milliseconds); warnings may report an unresolved key hash while the query still returns data. Treat a scope-resolution warning as an unavailable scoped chart, not a chart for the whole account. [Query][query], [query source][analytics-query].

Official query notes describe 64 RPM analytics throttling, but this is not a blanket quota for credits, catalogue or key endpoints. Freshness/ingestion latency, exact time-range end inclusivity, server cache TTL, blank-day semantics and authenticated visibility remain **U**. The query supports recent time buckets; a live/current-day graph should still say “partial” and needs private validation. Start with completed days; the richer API is a feasible later path, not a required dependency of the first widget.

## Catalogue semantics, controls and edge cases

The official model guide defines `created` as when added to OpenRouter; the embedded schema says when created. Prefer the user label **Latest added**, sorting by `created` descending (stable ID tie-break locally). Do not call it model release date, latest updated, provider launch date or a notification feed. `canonical_slug` is documented permanent; display IDs may be variants/aliases. Observed base/batch models can share timestamps. `knowledge_cutoff` is unrelated to sort recency. [Guide][models-guide], [schema][models].

`output_modalities` defaults to text; `all` includes embeddings, rerank, decisions, speech, transcription, image/video and other models. Input/output arrays are safer filters than parsing the display `modality` string. Offer explicit meanings: **Text-only** = input set and output set both exactly `{text}`; **Text output** = output contains text, including multimodal inputs; **All** = no modality filter. Unknown/new modalities should remain browseable in All, not fail decoding. [Guide][models-guide], [schema][models].

The current schema supports free-text `q` (name or slug), `input_modalities`, server sort, category, supported parameters, author/provider, context, pricing and age filters (plus privacy/region/benchmark options outside minimal scope). Server sorts include newest, price, context, throughput, latency and popularity. The guide and schema disagree on the exact composite price sort formula: guide mentions weighted prompt/completion/request/search, schema says average prompt/completion. Therefore label a local sort specifically **Input price** or **Output price**, or use server **Price** without claiming an exact formula. First-scope recency/name/context/local token-price sorts can share a full cached public dataset; performance/popularity sorts need server data. [Guide][models-guide], [schema][models].

Pagination is optional. Omit both offset/limit for full list; paginated requests default to 500, maximum 1000. `total_count` and `links.next` are present. Never assume default response is all modalities or a paginated page is the complete search universe. Server paging can avoid a large download for a glance-only view; a shared full catalogue is attractive for instant local search/multiple independent blocks. This is a bounded engineering tradeoff for Opus, not a demand to refactor all widgets. [Guide][models-guide], [schema][models].

Pricing is a map of decimal strings. Prompt/completion/cache/reasoning token rates are per token: multiply by 1,000,000 to show USD/M tokens. Request, image and search prices have other units; audio/image-output fields also exist. Model-level pricing is from the top provider, not a guaranteed bill or a cheapest-provider comparison. Conditional long-context/time-window overrides exist; avoid overly precise total-cost claims from two headline prices. Context length is tokens, with provider-specific context/output ceilings separate; input and output share the context window. [Guide][models-guide], [pricing schema][models], [provider endpoints][endpoints].

**Empirical anomaly:** seven router entries have prompt/completion `"-1"`; the inspected schema does not explain that sentinel. Interpretation as dynamic/unavailable price is **I**, presence is **E**. Auto-router docs say actual billing uses the routed model. Display “Varies” only for established router semantics, otherwise “—”; sort unavailable prices last, never as negative money. The initial offline nonnegative-price assertion caught this and was corrected. [Evidence](openrouter-poc/catalogue-evidence.json), [Auto Router][auto-router].

Free variants can have `:free` IDs; routing suffixes such as `:nitro` do not necessarily have separate catalogue entries. Zero input/output rates alone do not establish every modality/request/auxiliary operation is free: in the all sample, 105 entries have zero prompt/completion but only 22 have `:free`. A text-only zero-token-rate badge can be narrowly phrased, and known free variants distinctly marked. Free inference rate limits are not catalogue GET limits; no inference is part of this widget. [Variant guide][variants], [guide][models-guide], [limits][limits], [evidence](openrouter-poc/catalogue-evidence.json).

`expiration_date` is documented deprecation/expiration date. Null means no announced expiration, not permanent availability. The live sample contains 19 non-null dates. Do not remove a still-listed model solely because a date is near; show an optional retiring badge. Missing saved IDs should show unavailable and retain the selection, not silently substitute another. A current catalogue is not an archival list of every retired model; a lookup can return 404. [Model schema][models], [guide][models-guide].

## Real Sidelight architecture to reuse

All links here point to files in this checkout/base; observations are source inspection, not runtime UX verification.

| Existing primitive | What it supplies / constraint |
|---|---|
| [Widget settings](../../Sources/SidelightCore/Configuration/WidgetSettings.swift), [instance Codable](../../Sources/SidelightCore/Configuration/WidgetInstance+Codable.swift) | Kind switches and per-instance settings. New options need defaults/lenient decoding and clamped UI ranges. Released config must stay readable. |
| [BlockLayout](../../Sources/SidelightCore/Configuration/BlockLayout.swift) | Ordered shown/hidden blocks, repeatable instances, stable raw IDs. Hiding retains options; new fixed blocks load hidden; unknown blocks drop safely. |
| [Block builder](../../Sources/Sidelight/Builder/BlockBuilder.swift), [Railway editor](../../Sources/Sidelight/Widgets/Railway/RailwaySettingsEditor.swift) | `BlockBuiltWidget`, presets, whole-widget options, per-block inspector, repeatable blocks, live four-layout previews. Builder is currently wired for Railway/Codex Sessions, so adding Models is explicit wiring. |
| [Railway settings](../../Sources/SidelightCore/Configuration/RailwaySettings.swift) | Local precedent for account/scope/refresh, fixed and repeatable blocks with per-block options and derived data needs. Reuse pattern, not its GraphQL/CLI assumptions. |
| [AppEnvironment](../../Sources/Sidelight/App/AppEnvironment.swift), [AppController](../../Sources/Sidelight/App/AppController.swift) | Own long-lived services, inject observations, start/stop by demand. No new singleton or per-view poller. |
| [ServiceDemand](../../Sources/SidelightCore/Configuration/AppConfiguration.swift) | Union of visible instances; panels hidden or unseen for a minute stop demand. Manager/builder preview every widget. Railway avoids credential loading for unplaced preview-only widgets. Follow that precedent. |
| [RailwayService](../../Sources/Sidelight/Widgets/Railway/RailwayService.swift) | Shared connections per credential source, merged needs, one token load, serialised writes, generation checks for rotation. OpenRouter needs reference-indexed credentials if multiple accounts are offered; Railway has only CLI/token slots. |
| [FetchSchedule](../../Sources/Sidelight/Services/FetchSchedule.swift), [PacedTask](../../Sources/Sidelight/Services/PacedTask.swift), [DelayedTask](../../Sources/Sidelight/Services/DelayedTask.swift) | Cancellable schedule, backoff, manual gap, preserving attempt time across stop/start; paced scheduling useful for Retry-After/UTC boundaries. FetchSchedule alone has no HTTP-header retry deadline API. |
| [HTTP](../../Sources/SidelightCore/Support/HTTP.swift) | Off-main `@concurrent` requests; status/headers/body preserved. Ephemeral session keeps no cookies and **no URLCache**, so catalogue caching needs explicit service state. |
| [RailwayTokenStore](../../Sources/Sidelight/Widgets/Railway/RailwayTokenStore.swift), [Keychain helper](../../Sources/SidelightCore/Support/Keychain.swift) | Own Security-framework saved token pattern vs helper for other apps' secrets. Copy the own-store concept; do not use the cross-app reader for OpenRouter. No Keychain operations occurred. |
| [RefreshButton](../../Sources/Sidelight/DesignSystem/StatusRow.swift), [WidgetMessage](../../Sources/Sidelight/Widgets/Framework/WidgetMessage.swift) | Small icon-only refresh with help text; shared empty/setup/problem messaging. Existing refresh buttons are mainly settings controls; new panel placement still needs UX approval. |
| [Sparkline](../../Sources/Sidelight/DesignSystem/Sparkline.swift), [UsageFormat](../../Sources/Sidelight/Widgets/Framework/UsageFormat.swift), [Motion](../../Sources/Sidelight/DesignSystem/Motion.swift) | Existing static **bar** sparkline, not a line chart; unit formatting and event-driven motion. A line chart needs a small new rendering piece if approved. |
| [WidgetLayout](../../Sources/Sidelight/Widgets/Framework/WidgetLayout.swift), [WidgetCard](../../Sources/Sidelight/Widgets/Framework/WidgetCard.swift) | Regular/compact/minimal/bar; minimal and bar are glanceable. Cards own optional headers/padding/chrome; no header accessory hook currently. Avoid a duplicated permanent header or controls that vanish with hidden titles. |
| [PanelColumns](../../Sources/SidelightCore/Configuration/PanelWidth.swift), [PanelMetrics](../../Sources/Sidelight/Panel/PanelMetrics.swift) | Regular ≥260pt column, compact ≥120pt, smaller minimal; max column width 420pt. Horizontal bar thickness 44pt. Available inner content is less after margins/padding. |
| [PanelRootView](../../Sources/Sidelight/Panel/PanelRootView.swift), [PanelController](../../Sources/Sidelight/Panel/PanelController.swift) | Vertical masonry/scrolling and horizontal section chips; fitted content changes native window length. Panel never becomes key/main, is borderless/nonactivating/floating/fullscreen auxiliary. |
| [StylePicker](../../Sources/Sidelight/Manager/StylePicker.swift), [WindowCoordinator](../../Sources/Sidelight/Windows/WindowCoordinator.swift) | Searchable style-browser popover exists **in the manager**, not in the panel. Manager/settings/builder have explicit activation/key-window/edit-menu handling and tear down views on close. No general expanded widget/full-catalogue panel route was found. |

Swift/macOS explanation: observation can keep the native view static between published changes; parsing and network work must stay off the main actor so a catalogue refresh does not stall hover/scroll. Sidelight's app target is main-actor-default; pure data/parser/filtering belongs in Sendable SidelightCore types, with `@concurrent` work or explicit actor ownership as appropriate. Do not schedule network work in SwiftUI body computation.

Later production checklist is already in [adding-a-widget.md](../../.agents/skills/sidelight-conventions/adding-a-widget.md): both kinds/settings/Codable/metadata/views, builder switch for Models, services/environment/demand wiring and non-default released fixture values. No broad framework rewrite is justified by this research.

## Proposed minimal scope versus later scope

These are scope recommendations for design approval, not approved implementation.

**Minimal Credits:** one explicitly saved management connection; show account USD balance, source/last-updated/error states and quiet refresh. A 7-day completed-UTC-day credit-spend block is feasible with `/activity` if user wants it initially; no polling-based reconstruction. Account scope remains the balance source even when a chart later selects a key. Support layout-specific glance behaviour. One account is a scope choice, not an API limitation.

**Minimal Models:** credential-free, built with existing builder. Proposed block families: catalogue summary/count; one configurable model-list block (repeatable only if useful); optional pinned-model detail later. Whole-widget sync setting; per-list row count, Latest added/name/context/input or output price sort, Text-only/Text output/All filter and lean/standard/detail density. Preview presets could be Latest, Text-only and Rich list. A full catalogue affordance and native focus-capable search surface are part of the design work. Do not hide the builder requirement behind dozens of global toggles.

**Later feasible:** multiple saved account credentials; management key metadata selection/workspaces; ordinary-key budget mode; analytics `credits_usage` for longer windows and optional partial today; separate BYOK total; personalized catalogue; performance/popularity sorts; selected provider details on demand; pinned models and retirement badges. Keep inference/chat, key CRUD, top-ups, credential auto-discovery and notifications outside this widget scope unless separately requested.

## Proposed refresh, caching and performance budgets

All numbers below are **I: recommended budgets**, not measured results or provider requirements. They should be validated on native implementation with Instruments/Activity Monitor before and after.

| Resource | Default / user options | Coalescing/cache | Traffic budget while continuously visible |
|---|---|---|---|
| Public full catalogue | Default 60 min; manual-only, 15/30/60/180/360 min | One public snapshot for all catalogue instances; in-flight deduplication; process-memory initially | Default ≤24 requests/day plus bounded manual actions; no row detail fan-out |
| Account balance | Default 15 min; 5/15/30/60 min or manual-only | Per credential; use shortest requested visible cadence | Default ≤96/day/account |
| Completed-day activity | Daily while needed, with one request after UTC date changes when visible | Separate freshness from balance; aggregate 30 days once; retain prior snapshot | ~1/day/scope; manual refresh may ask once more |
| Key metadata/list | On picker opening if stale, 15–60 min TTL | One page/request; lazily follow offset for picker; selected-key GET only when needed | No full key listing on every balance refresh |
| Analytics metadata / query | Meta ~24h; completed-day query daily; partial today later ~15 min | Separate cache keyed by credential, metric, range and scope | Only for shown chart; stop querying when block hidden |
| Provider details | Open-on-demand | Cache model detail separately ~1h | No background per-model loop |

Visible manual refresh should be disabled/coalesced during fetch, use a ~15-second local minimum gap, and respect server cooldown across instances. Catalogue manual refresh is global; balance refresh targets the selected connection; chart refresh targets its scope. A spinner animates only while a fetch is in flight. Tiny visual controls still need useful hit targets, VoiceOver labels and keyboard access; never nested buttons across a clickable card.

Lifecycle:

- **Start:** publish cached state immediately. Fetch once if stale/missing, never once per widget. No automatic private network/Keychain reads for an unplaced catalogue preview. Manual-only needs an explicit first-fetch policy: recommend one initial fetch on placement, then only user refresh.
- **Hidden/occluded:** follow existing service demand (immediate shortcut hide, screen unseen grace about one minute). Cancel schedule and outstanding work on stop; check cancellation after every await. No hidden idle animations, search indexing loop, Keychain polling or process keepalive. An independently visible catalogue popup must hold its own narrow demand lease if the panel is hidden.
- **Stop/resume:** retain cached data and last attempt/deadline. Resume stale resources once, avoid burst catch-up of missed intervals. Blocks no longer shown should remove their data demand; no currency fetching for Models-only.
- **Offline/error:** retain last successful snapshot with stale/offline cue and timestamp; cold empty state gets retry. Never replace valid money with zero or erase lists on a transient failure. 401/403 needs credential/permission explanation, with automatic auth retries paused until credentials change. 400 is a schema/query error, not something to loop on.
- **Rate limiting:** honour Retry-After, back off transient failures, with shared per-connection cooldown; manual action cannot bypass it. Use native timing primitives, not a new Timer/Combine/handwritten sleep loop.
- **Credential changes:** cancel old work and invalidate private cache; generation/identity checks prevent old-account results overwriting new-account views. Public catalogue remains separately reusable.

The observed default `/models` headers were `Cache-Control: public, max-age=120, stale-while-revalidate=3600, stale-if-error=3600`, `CF-Cache-Status: HIT`, `Age: 34`, and a `Vary` list. No ETag/Last-Modified was present. These are **E from one response**, not a contract; manual refresh can still receive an edge-cached result. Sidelight HTTP drops cookies/caches, which is suitable for privacy, but retaining its own public snapshot is needed. Persist a public snapshot only if cold offline catalogue is desired; private spend should remain memory-only initially. [Evidence](openrouter-poc/catalogue-evidence.json), [models guide][models-guide].

Official errors docs permit Retry-After on 429/503 (and some inference-specific 402 cases). Limits documentation describes X-RateLimit headers on platform-limit errors and no successful inference quota headers; do not generalize that to a fixed metadata quota. Parse headers case-insensitively, reject invalid delays and use bounded backoff; observed successful public GET had no retry/limit headers. [Errors][errors], [limits][limits].

Suggested acceptance budgets: zero recurring work with no demand; one suspended scheduler per active resource class/connection rather than per widget; no frame clock for stale-age labels; retain 30–367 daily values, not generations. Public sample all-body is ~0.99MB uncompressed: cap future bodies (e.g. 5MB), keep only needed decoded fields, and measure live model-memory growth (target incremental retained data under 5MB; unmeasured). Search/filter/sort should operate on a cached snapshot only after changes; cache normalized search strings, use a lazy full-catalogue list and stable row identities. Target no input stall (>16ms main-actor work) during reload/search; this is a measurement goal, not a verified guarantee.

## Questions Opus should settle in the proposal/sketches

1. Account balance with optional key-scoped chart: how does the UI keep account money and key allowance visibly distinct? Should ordinary-key mode be offered in first scope at all?
2. Spend visual: existing bar sparkline versus line; 7/14/30 days; completed UTC days versus clearly partial today; minimal meaningful legends, currency precision and stale cues.
3. Catalogue wording/default: Latest added; Text-only versus Text output versus All; treatment of aliases/batch/free variants and retiring entries. Is the glance newest model name or catalogue count?
4. Builder: one configurable repeatable list block versus fixed list plus summary; row count/density options; global sync setting; useful presets without redundant content.
5. Tiny refresh/view-all placement with titles visible/hidden. Minimal card (<120pt) and 44pt top/bottom chip cannot carry a vertical header/list toolbar. Should the chip open the catalogue, with refresh on the expanded surface/menu?
6. **Popover versus temporary panel replacement:** anchored popup can preserve other widgets/avoidance geometry, but must take typing focus deliberately and clamp inward from left/right/top/bottom. Replacement needs a back affordance, focus, scroll restore, multi-display ownership and potentially changed fit-content sizing/window avoidance. Neither has a ready-made panel implementation. Assess a focus-capable transient catalogue surface as well as both requested alternatives; do not simply make every panel key-capable.
7. Catalogue opening should use cached rows instantly and refresh in the background if stale. Define animation, cancellation, query persistence, Escape/outside-click dismissal, focus return and what happens if the originating widget is removed or panel orientation changes.
8. Sketch all four layout densities and edges, including narrow/fitted panels, multi-column side panels, titleless cards, loading/stale/no-key/permission/retry states and long model names. A clickable compact affordance must remain discoverable without permanent clutter.
9. Decide whether cold-start offline catalogue needs disk persistence; whether multiple accounts are essential first scope; and the maximum acceptable freshness/traffic. These change setup complexity more than the basic API plumbing.

HTML sketches should label mock account money/history as mock and use the sample catalogue facts below; they cannot validate AppKit focus/window behaviour. Native follow-up after UI approval should test popup keyboard focus, edit commands, Escape, anchoring on all edges, fullscreen/multi-display, hiding/occlusion and idle energy. No such native interaction testing was performed here.

## Sample catalogue facts for sketches

**E, captured 2026-10-12**, not evergreen product copy. Default text-output list: 459 entries / 769,477 bytes. Explicit All: 662 entries / 989,077 bytes. Strict text→text: 149. All response had `links.next: null`; paged newest request returned three entries, total 662 and next offset 3. Full selected fields are in [catalogue-evidence.json](openrouter-poc/catalogue-evidence.json).

| Sample ID | Added UTC | Context tokens | Input/output example | USD/M input / output |
|---|---|---:|---|---:|
| `~perplexity/pplx-decider-27b-latest` | 2026-10-12 | 262,144 | text + image → decisions | 0.02 / 0 |
| `nace-ai/drex-v2.0` | 2026-10-12 | 131,072 | text → decisions | 0.06 / 0 |
| `meta/muse-wonder` | 2026-10-12 | 1,048,576 | text/image/file/audio/video → text | 4 / 20 |
| `stepfun/step-5-preview` | 2026-10-08 | 1,000,000 | text/image/video → text | 1 / 2.70 |
| `anthropic/claude-haiku-5.5` | 2026-10-07 | 1,000,000 | text/image/file → text | 0.10 / 0.50, conditional pricing exists |
| `apodex/apodex-1.1-mini:free` | 2026-10-01 | 262,144 | text → text | 0 / 0 |
| `openai/gpt-4.1` | 2025-04-14 | 1,047,576 | text/image/file → text | 2 / 8 |

All-model latest entries are **not** necessarily chat models; this matters to sketches. `openrouter/auto` in the sample has `-1` token pricing; `openrouter/free` has null top-provider context/output ceilings. `poolside/laguna-s-2.1:free` has an announced 2026-10-31 expiration. These illustrate unknown/dynamic price, optional provider data and retirement states. Dollar conversion is computed from sample decimal strings, not an inference-cost test. [Public all endpoint][public-all], [evidence](openrouter-poc/catalogue-evidence.json).

## Validation and remaining blockers

- Confirmed clean initial worktree, correct branch/base. No production source/configuration changes. Added only this report and minimal files in `docs/research/openrouter-poc/`.
- **Three API calls only:** unauthenticated default `/models`, explicit All, and All/newest/limit=3. No next-page request, private endpoint request or conditional-cache test. Documentation/source browsing adds read-only requests separately.
- Offline parser completed **8 shape checks**: unique IDs, integer created timestamps, finite decimal token prices, default text-output inclusion, default subset of All, complete All response, newest first page matches timestamp ordering, next-page link present. It caught/corrected a nonnegative pricing assumption; negative fields remain recorded, not normalized away.
- Saved trimmed selected model fields, body sizes/hashes and allowlisted headers. Cookies/raw full responses not stored in repository. Mock credits/activity file is clearly invented and proves no authenticated semantics.
- `make check` **passed**: strict Swift lint, shell syntax checks, warnings-as-errors build, **402 Swift Testing tests in 76 suites**, **13 Python release tests**. Initial sandboxed attempt failed on Swift module-cache access; rerun with approved standard-cache access passed. Make resolved the repository's existing pinned Sparkle 2.10.0 from cache; no new dependency was added or separate package installation requested. XCTest wrappers reported zero tests before Swift Testing ran; the actual 402 count is from Swift Testing.
- **Not tested:** credentials/management access, real account balance formula reconciliation, private activity completeness/ingestion, analytics meta/query, workspace/key paging, Retry-After handling, ETag/304, retired-model lookup, native search focus/popover placement, start/stop/hidden energy, Instruments/Activity Monitor, app UI or visual smoothness. `make dev` was deliberately not run under the research-only/app-change restriction.

No blocker prevents a design proposal. Account money/history cannot be empirically validated without a later authorized management key test; read-only credential scoping was not established. The searchable expanded surface needs an approved native focus design. User UI/UX approval is the production-implementation gate. Root can now hand this evidence to Opus; research stops here.

## Primary source links

[api-index]: https://openrouter.ai/docs/_llms/api-reference.txt
[docs-index]: https://openrouter.ai/docs/_llms/docs.txt
[credits]: https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits
[key]: https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key
[keys]: https://openrouter.ai/docs/api/api-reference/api-keys/list-api-keys
[single-key]: https://openrouter.ai/docs/api/api-reference/api-keys/get-a-single-api-key
[create-key]: https://openrouter.ai/docs/api/api-reference/api-keys/create-a-new-api-key
[management]: https://openrouter.ai/docs/guides/overview/auth/management-api-keys
[activity]: https://openrouter.ai/docs/api/api-reference/analytics/get-user-activity-grouped-by-endpoint
[query]: https://openrouter.ai/docs/api/api-reference/analytics/query-analytics-data
[meta]: https://openrouter.ai/docs/api/api-reference/analytics/get-available-analytics-metrics-and-dimensions
[analytics-source]: https://github.com/OpenRouterTeam/skills/blob/main/skills/openrouter-analytics/SKILL.md
[analytics-query]: https://github.com/OpenRouterTeam/skills/blob/main/skills/openrouter-analytics-query/SKILL.md
[analytics-schema]: https://github.com/OpenRouterTeam/skills/blob/main/skills/openrouter-analytics-schema/SKILL.md
[models]: https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties
[models-guide]: https://openrouter.ai/docs/guides/overview/models
[user-models]: https://openrouter.ai/docs/api/api-reference/models/list-models-filtered-by-user-provider-preferences-privacy-settings-and-guardrails
[endpoints]: https://openrouter.ai/docs/api/api-reference/endpoints/list-all-endpoints-for-a-model
[public-all]: https://openrouter.ai/api/v1/models?output_modalities=all
[variants]: https://openrouter.ai/docs/guides/routing/model-variants/overview
[auto-router]: https://openrouter.ai/docs/guides/routing/routers/auto-router
[limits]: https://openrouter.ai/docs/api_reference/limits
[errors]: https://openrouter.ai/docs/api_reference/errors-and-debugging
[faq]: https://openrouter.ai/docs/faq
[workspaces]: https://openrouter.ai/docs/api/api-reference/workspaces/list-workspaces
[ori]: https://openrouter.ai/docs/guides/ori/overview
[ori-config]: https://openrouter.ai/docs/guides/ori/configuration
[ori-changelog]: https://openrouter.ai/docs/guides/ori/changelog
[ori-release]: https://github.com/OpenRouterLabs/ori-releases
