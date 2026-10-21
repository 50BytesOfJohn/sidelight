# Runware widget: v1 implementation plan

Status: plan, ready to build once the pre-build checks below are done. Research:
`docs/research/runware-widget-research.md`, plus a second pass over Runware's current docs (Context7,
2026-10-21) and the existing OpenRouter, Railway and Accounts code. No code has been written.

Goal: an always-on glance at a Runware organization's balance, and what it's spending, in four layouts plus a
details panel with usage, a day-by-day history, and a model browser. Read-only: Sidelight never submits a
generation. It must cost nothing while hidden, and very little while visible: one small POST every few minutes.

## Scope

**In v1**

- Accounts: a new `runware` provider with **API-key accounts** (Keychain) and a read-only **Runware CLI** app
  sign-in (`runware.cli`), which reads the key `runware auth login` saved. Shared like every other account: one set
  of requests per account, however many widgets and blocks show it.
- Widget built from blocks: **Balance**, **Usage** (today / 7 / 30 days), **Spending chart** (daily, up to 30
  days), **Top models** (30 days). Presets: *Balance* (balance only), *Overview* (default), *Everything*.
- **Minimal and bar show the balance only**, always. No glance option.
- Details panel, three tabs:
  - **Usage**: rolling totals, a 30-day chart, models used, and API keys with their last use.
  - **History**: one row per day for 30 days (requests, spend). Click a day to see its models.
  - **Models**: search Runware's model catalogue. Filters, paging, and Copy AIR.
- Organization name reported to the Accounts pane as the account's identity.

**Deferred** (don't build in v1)

- Per-task history (individual generations): no public endpoint lists tasks. See *Product decisions*.
- Looking up a task by its UUID (`getTaskDetails`). It's cheap to add later, but nobody has a UUID to paste
  without a list.
- Model thumbnails (`heroImage`), error-rate and latency views (`getUsageErrors`, `getUsagePerformance`), usage
  beyond 30 days, per-key spending charts, a low-balance threshold (see *Ideas*).
- Running the `runware` CLI for anything. See *Why we never run the CLI*.
- Runware Serverless apps and their tasks: a different product with its own usage.

## Product decisions (for Tom to confirm)

1. **"Generation/task history" means a day-by-day history in v1, not a list of generations.** Runware's public
   API can list usage by day, by model and by key, and can look up *one* task whose UUID you already have. It can't
   list tasks. The dashboard's usage log has no documented API. So:
   - The History tab shows what's real: each day's requests and spend, and that day's models when you open it.
   - Its footer says plainly: "Runware doesn't offer a list of individual generations to apps. See each one in
     the Runware dashboard." It links there.
   - Never call it "generations" or "images": a request can produce several results, or none. Rows say
     **requests**.
   - Ask Runware for a paginated task-log endpoint. If one appears, it becomes a fourth tab without touching the
     rest of this design (see *Extension points*).
2. **The CLI is a credential source, not a data source.** Sidelight reads the key from `~/.runware/config.yaml`
   and calls the HTTP API itself, exactly as for a key account. That gives CLI users every feature (usage, history,
   models) and costs no process launches.
3. **Days are UTC days**, like OpenRouter's. All requests send `timezone: "UTC"`, and labels say "UTC" where it
   matters (tooltips, the History header). This avoids a new day type and re-fetching when the Mac changes time
   zone. It probably matches `getDetails`'s "today" too (to verify). Local days are a possible follow-up, since
   Runware supports any IANA zone.
4. **Free credits are shown apart, never added**: "$2,450.75" with "+ $120.00 free" below it, until we know whether
   `amount` already includes `freeBalance`.
5. **Default refresh: every 5 minutes** while visible (choices 5/15/30/60 and Manual, as OpenRouter). That's one
   tiny request. Activity (chart, models, history) refreshes at most every 15 minutes, and when details opens.
6. **A signed-in Runware CLI is the default account** when no default was chosen, the same as Railway. An explicit
   default always wins.

## Second-pass findings: points missing from, or differing with, the research

1. **Docs moved.** Current pages live under `https://runware.ai/docs/platform/…` (account-management,
   model-search, task-details). The research links use `/docs/models-api/…`. Cite the new paths in code comments.
2. **`getDetails` shape.** `data` is an *array*. The fields are flat on its first element (`organizationUUID`,
   `organizationName`, `balance{amount, freeBalance, currency}`, `team[]`, `apiKeys[]`, `usage{today, last7Days,
   last30Days, total}{credits, requests}`). Each `apiKeys[]` entry has `name`, a masked `apiKey`, `enabled`,
   `createdAt`, `requests` and `lastUsedAt`, and **no UUID**. So per-key usage filters (which take key UUIDs)
   can't be driven from it. That's why per-key charts are deferred.
3. **Personal data.** `team[]` carries members' names and emails. **Don't decode it.** Don't keep the masked key
   strings either. Keep only what's shown: key name, enabled, requests, last used.
4. **`getUsageActivity` breakdowns are separate, not crossed.** `groupBy: ["date","model"]` returns a
   `timeseries` and a `model` breakdown, each over the whole window, not date × model. One day's models therefore
   need their own request (`startDate = endDate = day`, `groupBy: ["model"]`). That's the History drill-down, made
   on demand and cached.
5. **`modelSearch` docs disagree with themselves.** The reference marks `search` as required; the JSON schema marks
   it optional. `source` values are `featured`/`community` (the research said `official`). The response nests
   results: `data[0].results[]` plus `data[0].totalResults`. Each result has `name`, `air`, `version`, `category`,
   `architecture`, `type`, `tags`, `private`, `heroImage` and defaults (`defaultWidth`, `defaultSteps`, …).
   Decode leniently. Verify whether an empty `search` is accepted. If it isn't, the Models tab opens on "Used
   recently" (from activity), and catalogue results start with the first typed character.
6. **Requests are arrays of tasks.** One POST may carry several tasks, and answers are matched by `taskUUID`. Use
   that for exactly one thing in v1: turning model AIRs into names (up to 10 `modelSearch` tasks in one POST).
   Whether a batch counts as one request or N against the rate limit is unknown, so measure it.
7. **Partial success.** A 200 can carry an `errors[]` entry for one task and `data` for another. Read problems per
   `taskUUID`, never per HTTP status alone.
8. **Rate limits are per organization** and shared with the user's production traffic. Sidelight's few reads are
   negligible, but this is another reason never to poll faster than 5 minutes, and to honor `retryAfter`.
9. **Do Sidelight's reads show up in the user's request counts?** If `accountManagement` calls count as requests,
   "Today: 1,850 requests" includes Sidelight's own ~288 a day. Verify. If they do, subtract nothing (we can't know
   exactly), but say so in the Usage tooltip.
10. **Default-account policy is hard-coded to Railway** (`Accounts.swift:197`). Generalize it with a provider
    property, not a second `if`.
11. **"Shown but no account yet" demand.** Railway keeps looking for the CLI sign-in while a widget is visible even
    when no account resolves (`RailwayDemand.isShown`). Runware needs the same, or a widget saying "Add an account"
    never notices `runware auth login`.
12. **CLI key replaced.** `runware auth login` with another key silently switches organizations. The service must
    notice the key changed and forget the old organization's data, as `keyChanged()` does for Keychain keys.
13. **Environment-only auth.** `RUNWARE_API_KEY` set in a shell never reaches a Finder-launched app. Sidelight
    ignores the environment on purpose, so the CLI account means exactly "the key in config.yaml". The Accounts copy
    tells env-only users to add their key as a key account.
14. **"Never makes paid requests."** The Accounts pane promises this. Enforce it in code: `RunwareAPI` builds only
    `accountManagement` and `modelSearch` tasks, and a test asserts that every request builder's `taskType` is in
    that allowlist.
15. **Brand assets.** Railway has a logo in `ProviderLogos.xcassets`. Check Runware's brand terms before adding
    theirs (`docs/BRAND_ASSETS.md`). Ship with an SF Symbol until then.

## Pre-build checks (with an authorized test key; record results in the PR)

Don't start the service code before 1–4; the decoders depend on them.

1. `getDetails`: the real `balance` shape (object vs number), whether `amount` includes `freeBalance`, the currency,
   which day "today" is (UTC?), and how `usage` looks for a brand-new org (missing vs zero).
2. `getUsageActivity` with `groupBy: ["date","model"]`, `timezone: "UTC"`, a 30-day window ending today: row
   fields (`date`, `count`, `spend`; the model breakdown's AIR field name), whether today is included and partial,
   days with no use (missing or zero?), and `meta` totals.
3. `modelSearch`: an empty `search`, `search` set to an exact AIR (does it return that model first?),
   `visibility: "owned"`, `totalResults`, and the max `limit`.
4. Errors: a bad key (status, `code`), a key without permission (if keys have roles), 429 with `retryAfter` (from
   docs if it can't be triggered safely), and a malformed request. Capture each as a **sanitized fixture**.
5. Do `accountManagement` reads raise the org's request count?
6. CLI: install it (Homebrew cask), `runware auth login`, and capture `~/.runware/config.yaml` with the key
   replaced by `rw_TEST`. Also run `runware auth logout`: does it delete the file or blank the key?
7. Does a batch of N tasks count as 1 or N against the rate limit?

Never use a generation call to test connectivity.

## Architecture

```
SidelightCore/Runware/            pure, Sendable, tested
  RunwareAPI.swift                requests, answers, problems, retry advice
  RunwareAccount.swift            account details, rolling usage, activity, keys
  RunwareModel.swift              catalogue models, pages, queries
  RunwareCLIConfig.swift          ~/.runware/config.yaml: where, and its api_key
SidelightCore/Configuration/
  RunwareSettings.swift           blocks, presets, options, demand
  Accounts.swift                  + .runware, .runwareCLI, signed-in preference
SidelightCore/Support/
  ReportedAmount.swift            moved out of OpenRouterAPI.swift, shared

Sidelight/Services/
  AccountPacing.swift             moved out of OpenRouterAccount.swift, generic over the problem
Sidelight/Widgets/Runware/
  RunwareService.swift            DataService: accounts, CLI discovery, key check
  RunwareAccount.swift            one account's resources, pacing, credentials
  RunwareWidget.swift             metadata, widget view, glance
  RunwareBlocks.swift             balance, usage, chart, top-models blocks
  RunwareBuilder.swift            BlockBuiltWidget conformance, block and widget options
  RunwareDetailsView.swift        RunwareBrowser + the three tabs
  RunwareFormat.swift             money, counts, problem titles and advice
```

### Data flow

```
AppController.observeServiceDemand
  configuration.runwareDemand(panels:previewsEveryWidget:previewing:signedIn:)
  + coordinator.details?.runwareDemand(in:)        (when not hidden and not unseen)
  → runRunware: environment.runware.demand = demand; setRunning(demand.isShown || !demand.isEmpty)

RunwareService ── one RunwareAccount per AccountID in demand.keptAccounts
   lookAround(): locate `runware`, read config.yaml → reportAppSignIn(.runwareCLI, found, signedIn)
   FileWatcher(~/.runware/config.yaml) while running → lookAround(); key fingerprint changed → account.keyChanged()

RunwareAccount
   details   RemoteResource<RunwareAccountDetails>  ← accountManagement/getDetails      (balance, usage, keys, org)
   activity  RemoteResource<RunwareActivity>        ← getUsageActivity 30 d, date+model (chart, top models, history)
   dayModels [UTCDay: …]                            ← getUsageActivity 1 d, model       (History drill-down, on demand)
   modelNames [AIR: name]                           ← batched modelSearch (≤10 tasks)   (names for AIRs, on demand)
   searchModels(query) async                        ← modelSearch, paged                (Models tab, on demand)
   all share one AccountPacing (Retry-After, rejected key, manual-click gap) and one key generation

RunwareWidgetView(settings, layout)
   isWidgetPreview → RunwareAccountDetails.example / RunwareActivity.example, marked "Example"
   else AccountGate(reference: settings.account, provider: .runware) { id in service.account(id) … }
```

### SidelightCore

`Runware/RunwareAPI.swift`

```swift
public enum RunwareProblem: Error, Equatable, Sendable {
    case noKey                    // key account without a saved key
    case cliNotSignedIn           // no config.yaml, or no api_key in it
    case cliConfigUnreadable      // config.yaml there, but not in a shape we read safely
    case invalidKey               // 401 / auth error code
    case notPermitted             // 403 / permission error code
    case rateLimited              // 429 / rate-limit code
    case unavailable(status: Int) // 5xx
    case badRequest(code: String?, message: String?)  // anything Runware rejected; asking again won't help
    case unreadable, tooLarge, unreachable, keychain
    public var accountStatus: AccountStatus? { … }   // invalidKey/notPermitted → .expired; noKey/cliNotSignedIn → .needsSignIn
    public var needsKey: Bool { … }
}

public enum RunwareAPI {
    public static let endpoint = URL(string: "https://api.runware.ai/v1")!
    static let timeout: TimeInterval = 30
    public static let sizeLimit = 2 * 1024 * 1024
    /// The only task types Sidelight ever sends. A test asserts every request uses one of them.
    public static let readOnlyTaskTypes: Set<String> = ["accountManagement", "modelSearch"]

    public static func detailsRequest(key: String, taskUUID: UUID, userAgent: String) -> URLRequest
    public static func activityRequest(key: String, window: ClosedRange<UTCDay>, groupBy: [ActivityGrouping],
                                       taskUUID: UUID, userAgent: String) -> URLRequest   // timezone "UTC"
    public static func modelSearchRequest(key: String, query: RunwareModelQuery, taskUUID: UUID,
                                          userAgent: String) -> URLRequest
    /// One POST with one modelSearch task per AIR (limit 1 each), to name the models usage lists.
    public static func modelNamesRequest(key: String, airs: [String: UUID], userAgent: String) -> URLRequest

    public static func details(_ response: HTTP.Response, taskUUID: UUID, fetchedAt: Date) -> Result<RunwareAccountDetails, RunwareProblem>
    public static func activity(_ response: HTTP.Response, taskUUID: UUID, window: ClosedRange<UTCDay>, fetchedAt: Date) -> Result<RunwareActivity, RunwareProblem>
    public static func modelPage(_ response: HTTP.Response, taskUUID: UUID, query: RunwareModelQuery) -> Result<RunwareModelPage, RunwareProblem>
    public static func modelNames(_ response: HTTP.Response, airs: [String: UUID]) -> [String: String]  // best effort
    public static func retryAdvice(for: RunwareProblem, response: HTTP.Response?, now: Date) -> RetryAdvice
}
```

- Body: `[{"taskType": …, "taskUUID": <fresh UUID v4>, "operation": …}]`. `Authorization: Bearer`,
  `Content-Type`/`Accept: application/json`, Sidelight's `User-Agent`. Never send the key in the body.
- Reading an answer: first the HTTP status (401 → `invalidKey`, 403 → `notPermitted`, 429 → `rateLimited`, 5xx →
  `unavailable`, >size → `tooLarge`). Then the `errors[]` entry whose `taskUUID` is ours (map `code` →
  problem; unknown codes → `badRequest(code, message)`, message capped at 200 characters). Then the `data[]`
  entry whose `taskUUID` is ours; missing → `unreadable`. Fill the exact `code` strings from the pre-build
  fixtures.
- Retry: `rateLimited`/`unavailable` honor `retryAfter` in the error body (seconds or a date: verify) or the
  `Retry-After` header via `RetryAfter.date(in:now:)`, else `.backoff`. `invalidKey`, `notPermitted`, `noKey`,
  `cliNotSignedIn`, `cliConfigUnreadable` and `badRequest` → `.onRequest`. The rest → `.backoff`. This mirrors
  `OpenRouterAPI.retryAdvice`.
- Money goes through `ReportedAmount` (number or decimal string, never via `Double`). Move it from
  `OpenRouterAPI.swift` into `Support/ReportedAmount.swift` (internal), unchanged.

`Runware/RunwareAccount.swift` (Core value types)

```swift
public struct RunwareBalance: Equatable, Sendable {
    public let amount: Decimal?        // nil: Runware didn't say; never shown as 0
    public let freeBalance: Decimal?
    public let currency: String        // "USD" when missing
}
public struct RunwareUsageTotal: Equatable, Sendable { public let spend: Decimal?; public let requests: Int? }
public struct RunwareRollingUsage: Equatable, Sendable {
    public let today, last7Days, last30Days, total: RunwareUsageTotal?
}
public struct RunwareAPIKeySummary: Identifiable, Equatable, Sendable {
    public let name: String; public let isEnabled: Bool; public let requests: Int?
    public let createdAt: Date?; public let lastUsedAt: Date?
    public var id: String { name + (createdAt?.description ?? "") }   // no UUID in the answer
}
public struct RunwareAccountDetails: Equatable, Sendable {
    public let organizationName: String?
    public let organizationID: String?
    public let balance: RunwareBalance
    public let usage: RunwareRollingUsage
    public let apiKeys: [RunwareAPIKeySummary]
    public let fetchedAt: Date
}
```

- `balance` decodes **both** the documented object and a bare number (the inspected CLI's `float64`). With a bare
  number, `freeBalance` is nil and the currency is "USD". With neither, the whole answer is `unreadable`: a
  balance widget without a balance is a failure, not a zero.
- Rolling usage and keys decode leniently (`LenientDecoding.swift`): one odd field loses one value.
- `team[]` and the masked `apiKey` strings are never decoded (finding 3).

```swift
public struct RunwareDay: Identifiable, Equatable, Sendable {
    public let day: UTCDay; public let requests: Int?; public let spend: Decimal?   // nil: nothing reported
    public var id: UTCDay { day }
}
public struct RunwareModelUsage: Identifiable, Equatable, Sendable {
    public let air: String; public let requests: Int?; public let spend: Decimal?
    public var id: String { air }
}
public struct RunwareActivity: Equatable, Sendable {
    public static let windowDays = 30                    // Runware's maximum window
    public let window: ClosedRange<UTCDay>               // today-29 … today
    public let days: [RunwareDay]                        // every day of the window, oldest first; gaps unreported
    public let models: [RunwareModelUsage]               // by spend, then requests
    public let totalRequests: Int?; public let totalSpend: Decimal?
    public let fetchedAt: Date
    public func days(last count: Int) -> [RunwareDay]    // clamped 1...30
    public func isBehind(at now: Date) -> Bool           // window ends before today (UTC)
}
public struct RunwareDayModels: Equatable, Sendable {
    public let day: UTCDay; public let models: [RunwareModelUsage]; public let fetchedAt: Date
}
```

- The window includes **today**, which is partial. The chart draws today's bar hatched, labelled "so far". This
  differs from OpenRouter, which only reports completed days. Verify (pre-build check 2).
- Unlike OpenRouter, a single unreadable row doesn't fail the activity. Usage isn't money owed, and losing one day
  is better than losing the chart. That day just shows as unreported. A row with an unreadable **spend** still
  keeps its request count.

`Runware/RunwareModel.swift`

```swift
public struct RunwareModel: Identifiable, Hashable, Sendable {
    public let air: String                    // "civitai:305149@392545", "runware:101@1"
    public let name: String                   // falls back to the AIR
    public let version: String?; public let category: String?; public let architecture: String?
    public let type: String?; public let tags: [String]; public let isPrivate: Bool
    public let heroImage: URL?                // kept for later; not loaded in v1
    public var id: String { air }
}
public struct RunwareModelQuery: Hashable, Sendable {
    public var search: String
    public var category: String?              // checkpoint, lora, lycoris, vae, embeddings, + unknown
    public var source: String?                // featured, community
    public var visibility: String?            // public, private, favorite, owned
    public var sort: String?                  // nil: Runware's default (popularity / relevance)
    public var offset = 0
    public static let pageSize = 50           // ≤ 100
}
public struct RunwareModelPage: Equatable, Sendable {
    public let models: [RunwareModel]; public let total: Int?; public let query: RunwareModelQuery
    public var nextOffset: Int? { … }         // nil once offset + count ≥ total, or a short page
}
```

Filters are free strings with known values offered in menus, so values Runware adds later still pass through, as
`OpenRouterModality` does. Results without an `air` are skipped; duplicates by AIR are kept once.

`Runware/RunwareCLIConfig.swift`

```swift
public enum RunwareCLIConfig {
    public static var configFile: URL           // ~/.runware/config.yaml
    public static var executableDirectories: [URL] { ExecutableLocator.standardDirectories }  // brew, ~/.local/bin
    public enum Reading: Equatable, Sendable { case signedIn(String), signedOut, unreadable }
    /// The `api_key` the CLI saved. Description never includes the key.
    public static func read(yaml: Data) -> Reading
}
```

**Parsing without a YAML dependency.** The package has one dependency (Sparkle), and a whole YAML library for one
key is out of proportion. The CLI writes this file with Go's `yaml.Marshal` of a flat struct, so its shape is
predictable. The reader is deliberately narrow and **refuses rather than guesses**:

- It accepts UTF-8 with an optional BOM, LF or CRLF line endings, comments (`# …`) and blank lines, and other
  top-level keys (ignored). Only a top-level `api_key:` line counts, and it must have no indentation.
- The value may be plain, `'single'` quoted (`''` escape) or `"double"` quoted (`\"` and `\\` escapes only; any
  other escape → `unreadable`). A trailing ` # comment` after a plain value is stripped. The value is trimmed.
- `api_key` missing, empty, `""` or `null`/`~` → `.signedOut`.
- These → `.unreadable`: block scalars (`|`, `>`), anchors and aliases (`&`, `*`), tags (`!`), flow
  mappings/sequences, a document marker after content (`---` with more than one document), `api_key` twice, or a
  plain value with a space or a `:` in the middle.
- The widget says "Runware CLI's settings can't be read. Run `runware auth login` again, or add an API key in
  Settings." Sidelight never writes the file.

If the pre-build capture shows a different file shape (nested `auth:` section, profiles), revisit: the narrow parser
stays only if the shape stays flat.

`Configuration/RunwareSettings.swift`

```swift
public enum RunwareBlock: String, WidgetBlockKind, CaseIterable, Identifiable {
    case balance      // balance, free credits, freshness
    case usage        // today / 7 days / 30 days: spend and requests
    case chart        // daily spending or requests, 7/14/30 days
    case models       // top models by spend over 30 days
    public static let fixedBlocks: [RunwareBlock] = [.balance, .usage, .chart, .models]
    public var isShownByDefault: Bool { true }
    public var needsActivity: Bool { self == .chart || self == .models }
}

public enum RunwarePreset: String, CaseIterable, Identifiable, Sendable {
    case balance      // [.balance]: the small, balance-only card
    case overview     // [.balance, .usage, .chart] (default)
    case everything   // [.balance, .usage, .chart, .models]
    public var blocks: [RunwareBlock]
}

public enum RunwareChartMetric: String, Codable, CaseIterable, Identifiable, Sendable { case spend, requests }

public struct RunwareBalanceOptions: Codable, Hashable, Sendable {
    public var title: String?            // replaces "Runware · <org>" above the figure
    public var showsFreeCredits = true
}
public struct RunwareChartOptions: Codable, Hashable, Sendable {
    public static let dayChoices = [7, 14, 30]; public static let dayRange = 7...30
    public var days = 7
    public var metric = RunwareChartMetric.spend
}
public struct RunwareModelsOptions: Codable, Hashable, Sendable {
    public static let rowCountRange = 1...10
    public var rowCount = 3
}

public struct RunwareSettings: Codable, Hashable, Sendable {
    public static let refreshMinuteChoices = [5, 15, 30, 60]
    public static let refreshMinuteRange = 5...60
    /// Activity (chart, top models, history) is fetched at most this often, whatever `refresh` says.
    public static let activityMinimumMinutes = 15

    public var account: AccountID?                       // nil: the provider's default
    public var refresh = RefreshCadence.minutes(5)
    public var blocks = BlockLayout<RunwareBlock>(shown: RunwarePreset.overview.blocks)
    public var balance = RunwareBalanceOptions()
    public var chart = RunwareChartOptions()
    public var models = RunwareModelsOptions()
    // init(from:): decode(_:or:) everywhere; account and enums decodeLeniently; refresh clamped to the range,
    // chart.days and models.rowCount clamped; CodingKey for account is "accountID", as OpenRouter's.
    public var showsActivity: Bool { blocks.shownBlocks.contains(where: \.needsActivity) }
}
```

Demand (same file), shaped like `OpenRouterDemand` because it needs the panel's density:

```swift
public struct RunwareAccountDemand: Equatable, Sendable {
    public var details: RefreshCadence?     // balance + rolling usage + keys
    public var activity: RefreshCadence?    // the 30-day activity
    public var isEmpty: Bool
    public mutating func merge(_ other: Self)
}
public struct RunwareDemand: Equatable, Sendable {
    public var accounts: [AccountID: RunwareAccountDemand]
    /// Accounts any Runware widget in the configuration resolves to, shown or not: their data is kept.
    public var keptAccounts: Set<AccountID>
    /// A Runware widget is on screen, even one without an account yet: the service watches for the CLI sign-in.
    public var isShown: Bool
    public var isEmpty: Bool { accounts.isEmpty }
    public func limited(to kinds: Set<WidgetKind>) -> Self
    public mutating func merge(_ other: Self)
    public mutating func add(_ widget: WidgetInstance, on panel: ShownPanel, in configuration: AppConfiguration,
                             signedIn: Set<AccountID>)
}
extension AppConfiguration {
    public func runwareDemand(panels: [ShownPanel], previewsEveryWidget: Bool = false,
                              previewing: Set<WidgetInstance.ID> = [], signedIn: Set<AccountID> = []) -> RunwareDemand
    public func runwareAccounts(signedIn: Set<AccountID>) -> Set<AccountID>
}
```

- On a bar or minimal panel (`!panel.showsBlocks`), a widget needs `details` only.
- Otherwise it needs `details` if `.balance` or `.usage` is shown, and `activity` if `.chart` or `.models` is
  shown.
- Previews (`previewsEveryWidget`, `previewing`) **add nothing**. Previews show examples, and never read a key or
  call Runware, the same rule as OpenRouter balances.
- `signedIn` is required. Unlike OpenRouter, Runware has an app sign-in that decides the default.

`Configuration/Accounts.swift`

- `AccountProvider.runware`: title "Runware", `acceptsKeys = true`, `acceptsAppProfiles = false`, and
  `appSignIn = Account(id: .runwareCLI, provider: .runware, name: "Runware CLI", kind: .appSignIn)`.
- `AccountID.runwareCLI = "runware.cli"`.
- New `AccountProvider.prefersSignedInAppSignIn: Bool` (true for `.railway` and `.runware`). `defaultAccount` uses it
  in place of `provider == .railway`. That's a behavior-preserving refactor for Railway.
- `WidgetSettings.accountReferences`: `.runware(let s) → [(.runware, s.account)]`. `forgetAccount`: the
  `.runware` case.

Other Core wiring (the compiler lists every switch):

- `WidgetKind.runware` ("Runware organization balance, usage and models. Built from blocks.").
  `WidgetSettings.runware(RunwareSettings)`, its default, and both switches in `WidgetInstance+Codable.swift`.
- Add `.runware` to the exhaustive lists in `AppConfiguration.swift` (`sessionProviders`,
  `UsageServiceDemand.init`) and to `Accounts.swift`.
- `Log.runware` (category `runware`).

### App target

`Services/AccountPacing.swift`: **extract** `AccountPacing` from `OpenRouterAccount.swift` and make it generic.

```swift
struct AccountPacing<Problem: Equatable> {
    init(rateLimited: Problem, isRejection: @escaping (Problem) -> Bool)
    func manualWait(gap: Duration) -> Duration
    mutating func manualRequestSent()
    mutating func record(_ problem: Problem, retry: RetryAdvice, at now: Date)
    func hold(at now: Date) -> (problem: Problem, retry: RetryAdvice)?
}
```

OpenRouter moves to it in the same PR, with no behavior change; `OpenRouterServiceTests` must still pass. This is
the "redesign rather than copy" step: a second provider needs the same rules, and a copy would drift.

**`RunwareService.swift`**: `@Observable final class RunwareService: DataService`

```swift
typealias Transport = @Sendable (URLRequest) async throws -> HTTP.Response   // injected via AppComposition
private(set) var accounts: [AccountID: RunwareAccount]
private(set) var cliExecutable: URL?
private(set) var cliReading: RunwareCLIConfig.Reading?   // nil until looked; never exposes the key to views
var cliIsSignedIn: Bool
var demand = RunwareDemand() { didSet { if demand != oldValue { apply() } } }
func account(_ id: AccountID) -> RunwareAccount?
func refreshNow()                                          // lookAround + each shown account's refresh
func checkKey(_ candidate: String) async -> RunwareProblem? // one getDetails with the candidate
```

- `apply()`: create a `RunwareAccount` for each kept account (secret closure below), drop ones no longer kept,
  then `update(demand:isKept:isEnabled:)` each, as `OpenRouterService.apply()` does. Call `lookAround()`.
- `lookAround()` (only while enabled): `ExecutableLocator.find("runware", in: RunwareCLIConfig
  .executableDirectories)`, then read the config `@concurrent`. Then
  `access.reportAppSignIn(.runwareCLI, found: exe != nil || signedIn, signedIn: signedIn)`. Signed-out reports
  `.needsSignIn`; unreadable reports `.failed("Can't read the Runware CLI's settings")`.
- Watch the config with `FileWatcher(file: RunwareCLIConfig.configFile, onMainActor:)` from `start()` to `stop()`,
  coalesced through a `CoalescedReload` (an editor's save is several events). If the folder doesn't exist,
  `FileWatcher` returns nil; then rely on `lookAround()` at demand changes and Refresh, as Railway does.
- **CLI key fingerprint**: keep a SHA-256 of the last key read, in memory only. When it differs from the previous
  one, call `accounts[.runwareCLI]?.keyChanged()`. The old organization's balance must never show under the new
  key.
- Credentials: `.runwareCLI` reads the config off the main actor on each fetch (a few hundred bytes), giving
  `cliNotSignedIn` or `cliConfigUnreadable` when there's no key. Any other ID reads `access.secret(id)` (`noKey`
  when empty, `keychain` when it throws). `access.observeChanges` → `accounts[id]?.keyChanged()`.
- `checkKey`: trims, then makes one `getDetails` request with the candidate. A success returns nil. A failure
  returns the problem, which the sheet shows as "title. advice".

**`RunwareAccount.swift`**: `@Observable final class RunwareAccount`, closely following `OpenRouterAccount`.

```swift
let id: AccountID
let details: RemoteResource<RunwareAccountDetails, RunwareProblem>
let activity: RemoteResource<RunwareActivity, RunwareProblem>
private(set) var dayModels: [UTCDay: DayModelsState]        // .loading, .loaded(RunwareDayModels), .failed(problem)
private(set) var modelNames: [String: String]               // AIR → name, filled on demand
func update(demand: RunwareAccountDemand, isKept: Bool, isEnabled: Bool)
func refresh(includingActivity: Bool)                       // a click: queued behind the manual gap
func loadDayModels(_ day: UTCDay)                           // History drill-down
func nameModels(_ airs: [String])                           // batched, ≤10 per POST, each AIR asked once a session
func searchModels(_ query: RunwareModelQuery) async -> Result<RunwareModelPage, RunwareProblem>
func keyChanged()                                           // forget everything, new generation, new pacing
```

- `details.policy = demand.details.map(RefreshPolicy.init)`.
- `activity.policy = demand.activity.map { .every(.seconds(max($0.minutes ?? 0, 15) * 60)) }`, and `.manual`
  for manual widgets.
- Every fetch does the following, in this order (as `OpenRouterAccount.fetchBalance` does). Read the key. Check
  `pacing.hold`. Send through `RunwareClient` (`@concurrent`, decode off the main actor). Drop the answer if
  `Task.isCancelled` or the key generation changed. Then record it in pacing and report the account status.
- A successful `details` reports `.connected` and `access.reportIdentity(details.organizationName, id)`.
- `dayModels`: a completed day is fetched once and kept until `keyChanged()` or the account is forgotten. Today is
  re-fetched when it's older than 5 minutes. At most 31 entries.
- `searchModels` is called by the browser, which owns the debounce and cancellation. Here it checks the hold and the
  key generation only. Results aren't cached in the account. The browser keeps them for the panel's life, and
  private models stay with the account that asked.
- `modelNames` match a result only when its `air` equals the requested AIR exactly; otherwise the row shows the
  AIR. Names are never persisted.

`RunwareClient`: the same 40-line shape as `OpenRouterClient` (send, timestamp, `Answer` with `RetryAdvice`),
typed to `RunwareProblem`. Don't generalize it now; two short copies are fine.

**`RunwareWidget.swift`**

```swift
extension WidgetMetadata {
    static let runware = WidgetMetadata(
        title: "Runware", systemImage: "photo.stack", tint: .pink,
        summary: "Balance, spending and models",
        details: "Your Runware organization's balance and what it's spending, by day and by model, with a model "
            + "browser in details. Uses an API key or the Runware CLI's sign-in. Sidelight only reads: it never "
            + "runs a generation.",
        isBeta: true)
}
```

- Category `.cloud`, next to OpenRouter. Add `.runware` to `WidgetStyle.swift`'s "no styles" lists. Add it to
  `WidgetSettings.blockBuilt` and `WidgetBuilderWindow`, and to the content and settings-editor switches in
  `WidgetViews.swift`.
- `RunwareSettings.layoutSummary`: "Overview · every 5 minutes", "Balance · manual", "2 blocks · every 15
  minutes".

**`RunwareBuilder.swift`**: `extension RunwareSettings: BlockBuiltWidget`; `RunwareBlock: DescribedBlock`.

- Presets: `.overview` (first, the default), `.balance`, `.everything`.
- Widget options (shared with the Widgets window): `AccountPicker(provider: .runware, selection: $settings
  .account)`, then a status row, then `ExpandableRow("Advanced")` with the Refresh picker. The status row is a
  `StatusRow` like `RailwayWidgetOptions.signInText`: "Acme Corporation" (green) / "Runware CLI signed in" (blue) /
  "Runware CLI not signed in" (orange) / "Runware CLI not found" (secondary) / the problem's title, with Refresh.
  Its `InfoLabel` explains: "Activity refreshes at most every 15 minutes. Sidelight's reads count against your
  organization's rate limit, shared with your apps."
- Block options: Balance (title field, "Show free credits" toggle). Chart (days 7/14/30, Spending/Requests). Top
  models (rows stepper). Usage has none.
- `addableBlocks`: none. Blocks are fixed.

**`RunwareBlocks.swift`**: the block views and the glance, all drawn through `WidgetClock` (ages).

**`RunwareDetailsView.swift`**: `RunwareBrowser` (the session state) and `RunwareDetailsView`.

**`RunwareFormat.swift`**: `money(_:currency:)` (two decimals; minimal/bar abbreviate ≥ 10,000 as "$12.4K"),
`requests(_:)` ("1,850 requests"), `RunwareProblem.title/advice`, and `RunwareBalance.accessibilityText`.

Changes outside the folder:

- `AppEnvironment`: `let runware: RunwareService`, in `dataServices` and `environment(_:)`.
- `AppController`:
  - Create `RunwareService(transport: composition.runwareTransport, accounts: accountAccess)`.
  - Add `runware: RunwareDemand` to the private `Demand`, computed with `configuration.runwareDemand(panels:
    shown, previewsEveryWidget: previews, previewing: previewed, signedIn: accounts.signedInAppSignIns)`, and
    merged with `details.runwareDemand(in:)` beside OpenRouter.
  - Add `runRunware(for:)`. Make `case .runware: break` in `runServices`, as OpenRouter has.
- `AppComposition`: `var runwareTransport: RunwareService.Transport = { try await HTTP.send($0) }`, and in DEBUG
  `-SidelightRunwareURL <loopback URL>` through the existing `loopbackTransport`. That allows a fake server for
  `make dev` and for idle measurements.
- `DetailsSession.swift`:
  - `DetailsRequest.runware(account: AccountID, tab: RunwareDetailsTab)` and `DetailsContent.runware
    (RunwareBrowser)`, with title "Runware" and kind `.runware`.
  - `adopts`: the same account → switch the tab, keeping the search. `handlesKey`: false.
  - `runwareDemand(in:)`: for Runware content, `[browser.account: details + activity]` at the opening widget's
    `refresh` (or the default cadence if the widget is gone). Empty otherwise.
- `DetailsPanelView.DetailsContentView`: a `.runware(let browser)` case.
- `AccountViews.swift`:
  - `systemImage` "photo.stack", tint `.pink`, `keyTitle` "Runware API key".
  - `keyExplanation`: "Sidelight reads the organization's balance, usage and models with it, and never runs a
    generation."
  - `keyLink`: Runware's API Keys page (exact URL to confirm in pre-build check 1).
  - `managedBy`: "Managed by the Runware CLI".
  - `signInAdvice`: "Run runware auth login, or add an API key in Settings, under Accounts. A key set only in
    RUNWARE_API_KEY isn't visible to Sidelight: add it here instead."
- `AccountKeySheet`: `@Environment(RunwareService.self)`, and `case .runware: await runware.checkKey(key)…`.
- `AccountsSettingsPane`'s footer stays true (no paid requests), with no wording change needed.

## Layouts

Every layout first goes through `AccountGate(reference: settings.account, provider: .runware, layout:)` (add
account / choose account / sign in again), except previews.

| State | What shows |
|---|---|
| No account / account not found / needs sign-in | `AccountGate`'s messages, unchanged. For the CLI: "Runware CLI not signed in. Run runware auth login, or add an API key." with "Open Accounts". |
| `cliConfigUnreadable` | "Can't read the Runware CLI's settings", plus advice and "Open Accounts". |
| No details yet, fetching | "Connecting to Runware…", `hourglass` |
| No details, a problem | The problem's title and advice; "Try Again", or "Open Accounts" when `needsKey`. |
| Details, then a later problem | The content dimmed to 0.6, with an orange stale dot, and "<problem> · 12m ago" in place of "Updated…". |
| `balance.amount == nil` | "Balance unavailable": never "$0.00". |

Connected:

- **Bar**: `creditcard.fill` (secondary) + the balance at 12.5 pt rounded semibold, plus a stale dot. The tooltip
  says: "Runware · Acme Corporation: $2,450.75 (+ $120.00 free). Today: $35.80 · 1,850 requests. Updated 2m ago".
  Click → details, Usage tab (real panels only).
- **Minimal**: the balance at 12.5 pt with `minimumScaleFactor(0.6)` (abbreviated ≥ 10,000), a stale dot below,
  the same tooltip, and the same click. Nothing else: balance only, as asked.
- **Compact**:
  - Balance: the figure at 18 pt, and "+ $120 free" trailing in secondary at 9.5 pt when shown.
  - Usage: one line, "Today $35.80 · 1,850 req".
  - Chart: 18 pt bars and no caption.
  - Top models: up to `min(rowCount, 3)` rows, name and spend.
  - Click the balance → details.
- **Regular**:
  - Balance: the label "RUNWARE · ACME CORPORATION · USD" (or the block's title), the figure at 26 pt (red when
    below zero), "+ $120.00 free" when `showsFreeCredits` and > 0, and "Updated 2m ago ⟳".
  - Usage: three columns, Today / 7 days / 30 days. Spend over requests, monospaced digits, with "—" for unknown.
  - Chart: one bar per UTC day (`days`), spend or requests. Today's bar is hatched ("so far"), the latest
    completed day is accent-colored, and days with nothing reported get a hairline, as in OpenRouter's
    `SpendBars`. Caption: "$412.25 · last 7 days (UTC)". Hovering a bar shows that day's value.
  - Top models: "TOP MODELS · 30 DAYS", then `rowCount` rows: name (or AIR, middle-truncated), a thin share bar,
    and spend. Footer: "Browse models ›" → the Models tab. Previews disable it: "Opens from the panel".
  - Clicking the chart → the History tab; clicking the balance or usage → the Usage tab.

Previews (`isWidgetPreview`) draw `RunwareAccountDetails.example(at:)` and `RunwareActivity.example(at:)`, labelled
"Example balance". Nothing is fetched, no key is read, and nothing opens.

## Details panel

`RunwareBrowser` (`@Observable`, forgotten on close): `account`, `tab` (`.usage`, `.history`, `.models`),
`expandedDay`, `modelQuery`, `modelPages`, `modelsTask`, and a `DelayedTask` debounce.

- **Header controls**:
  - A segmented "Usage | History | Models".
  - An account menu trailing, only when Runware has more than one usable account. Switching it changes
    `browser.account`, which changes the details demand.
  - The org name and "Updated 2m ago ⟳" under the tabs.
- **Usage**:
  - Balance (with free credits).
  - A rolling-totals grid: Today / 7 days / 30 days / All time, each with spend and requests.
  - The 30-day chart, with a Spending/Requests toggle local to the browser.
  - **Models used**: every model in the 30-day breakdown, with name, AIR, requests, spend and a share bar. Right-click
    → Copy AIR.
  - **API keys**: name, enabled/disabled, requests, "last used 3h ago". Sorted by last use.
  - A footnote: "Requests, not images: one request can return several results."
- **History**:
  - Header: "Last 30 days · UTC".
  - One row per day, newest first: "Today (so far)", "Mon 20 Oct", requests and spend, and a hairline for days
    with nothing reported.
  - Clicking a day expands it in place: `loadDayModels(day)` → that day's models (name, requests, spend), with a
    small spinner while loading and "Couldn't load this day · Try Again" on failure.
  - Footer: the no-task-list sentence and a link to the dashboard.
- **Models**:
  - A search field, focused when the tab opens, debounced 300 ms; a new query cancels the old task.
  - Filter menus: Category, Source (Featured/Community), Visibility (Public/Mine = owned/Private/Favorites), and
    Sort (Popular/Newest/Relevance, sent only when Runware accepts it: verify).
  - With an empty search, the tab shows "Used recently" (from activity) above the catalogue. It shows the
    catalogue's first page only if an empty `search` is accepted (finding 5).
  - Rows: name, version, then `architecture · category` and the AIR in monospaced secondary text.
  - Click → expand: tags, type, defaults (size, steps, CFG), "Copy AIR", and "Copy as JSON"
    (`{"model": "<AIR>"}`). That's handy for developers pasting into code.
  - Paging: "Load more (50 of 1,284)" at the end. No infinite scroll: every page is one request, and a click
    keeps that visible.
  - Empty and failed states as in `OpenRouterCatalogueView`. With a rejected key, the message plus "Open
    Accounts".
- Opening and closing:
  - Opening details triggers `activity.refreshNow()` when the activity is older than 5 minutes (still paced).
  - Closing cancels the models search and any day load. The demand drops, so the account goes back to the widget's
    cadence.

## Refresh, pacing and cost

| Data | When | Cost |
|---|---|---|
| Details (balance, rolling usage, keys) | Widget cadence (default 5 min) while any widget or details shows it; manual widgets fetch once, then on click | 1 POST |
| Activity (30 days, date + model) | max(cadence, 15 min) while a chart/models block or details shows it; on details open if > 5 min old | 1 POST |
| A day's models | On click in History; completed days once per session | 1 POST |
| Model names | When usage lists AIRs without names; ≤ 10 per POST; each AIR once per session | 1 POST per batch |
| Model search | Typing (300 ms debounce), filter change, Load more | 1 POST each |
| CLI config | FileWatcher events, demand changes, Refresh, and each fetch of the CLI account | local read |

- `RemoteResource` provides backoff (2 min, doubling to 60 min), keeps the value through failures, and resumes the
  schedule where it left off after hiding.
- `AccountPacing` makes one hold per account: `retryAfter` stops *every* request with that key, and a rejected key
  stops all of them until it's replaced. Clicks are at least 15 s apart.
- Hidden panels, sleeping/locked screens and an unseen details panel drop demand, as every service does. With no
  demand, nothing runs except the FileWatcher, and that only while the service is enabled.

## Configuration compatibility

- New kind, new provider, new settings: everything decodes with `decode(_:or:)` / `decodeLeniently`, clamps
  hand-edited numbers, and needs no migration.
- `defaultAccounts` already skips unknown providers, and `accounts` drops unknown ones leniently. So a
  configuration with Runware accounts opened in an older Sidelight loses only those, not the file.
- `ReleasedConfigurationFixture.swift`:
  - Add a Runware key account ("Studio"), `defaultAccounts[.runware] = .runwareCLI`, and a widget with
    non-default settings: `account: studio.id, refresh: .minutes(15), preset .everything, balance.title
    "Studio", showsFreeCredits false, chart.days 30, metric .requests, models.rowCount 5`.
  - Add a default Runware widget too.
  - Don't regenerate an existing release file.

## Privacy and security

- Keys: key accounts live in the Keychain via `AccountSecrets`. The CLI key is read into memory per fetch and kept
  only as a SHA-256 fingerprint between reads. It is never logged (the `RunwareCLIConfig.Reading` and
  `RunwareProblem` descriptions omit it), never written, and never passed to a process.
- Logs: status changes at `.notice` with `privacy: .public` for problem kinds only. Org names, model AIRs and key
  names go at `.debug` or not at all.
- Minimal data: no team roster, no masked keys, no thumbnails in v1.
- Read-only enforcement: the `readOnlyTaskTypes` allowlist test (finding 14).

## Tests

`Tests/SidelightCoreTests/RunwareAPITests.swift`: sanitized fixtures inline, as in `OpenRouterAPITests`.

- `getDetails`: the object balance; a numeric balance; free balance absent / present; currency missing → USD;
  balance missing → unreadable (not 0); usage periods partly missing; `team` ignored; keys without dates.
- Envelope: data for another `taskUUID` → unreadable. An `errors[]` entry for ours with HTTP 200 → its problem.
  A mixed batch → per-task results. 401/403/429/5xx/oversize. `retryAfter` in the body and in the header.
  Unknown code → `badRequest`, message capped.
- Activity: a 30-day window ending today; gaps → unreported; an unreadable spend keeps its requests; models sorted;
  `days(last:)` clamps; `isBehind`.
- Model search: nested `results`, `totalResults`, `nextOffset` (full page, short page, total reached), missing
  AIR skipped, duplicates kept once, unknown category passes through.
- Requests: method POST, endpoint, Bearer header, a body that is an array with a fresh UUID each time,
  `timezone: "UTC"`, `limit` ≤ 100, **every builder's `taskType` ∈ `readOnlyTaskTypes`**, and the key never in
  the body or URL.
- `retryAdvice` table, parameterized.

`Tests/SidelightCoreTests/RunwareCLIConfigTests.swift`: plain, single- and double-quoted values; a comment after a
plain value; CRLF; BOM; other keys around it; indented `api_key` (nested) ignored; empty/`null`/missing →
signedOut; block scalar, anchor, tag, flow map, duplicate key, bad escape → unreadable; the description doesn't
contain the key.

`Tests/SidelightCoreTests/RunwareConfigurationTests.swift`:

- Settings: `{}` → defaults; refresh 1 → 5 and 999 → 60; days 99 → 30; rowCount 0 → 1; unknown metric → spend;
  an unreadable account → nil; presets ↔ blocks.
- Demand:
  - A minimal panel → details only. A regular panel with the Balance preset → details only. Overview → details +
    activity. Two widgets on one account → one entry with the faster cadence.
  - Previews add nothing. A hidden widget → kept but not demanded. `isShown` with no account. `limited(to:)`.
  - A CLI signed in with no default → the CLI. An explicit default → that one. A widget naming a removed account →
    nothing fetched.

`Tests/SidelightCoreTests/AccountTests.swift` (additions):

- `prefersSignedInAppSignIn` keeps Railway's behavior and gives Runware the same.
- `references`/`uses`/`forgetReferences`/`removeAccount` with Runware widgets.
- `suggestedAccountName` ("Runware", "Runware 2", considering "Runware CLI").

`Tests/SidelightTests/RunwareServiceTests.swift`, with a fake transport and `AccountSecrets.memory`, as
`OpenRouterServiceTests`:

- `start` twice → one details fetch. Two widgets on one account → one request. Stopping during a fetch → nothing
  published.
- A key replaced → old values gone before the new answer. An answer with the old key dropped. The CLI fingerprint
  changes → reset.
- 401 → no further requests until the key changes. `retryAfter` holds the details *and* the activity.
  Clicks are at least the gap apart.
- Activity only while a chart, models block or details needs it; never below 15 min.
- Day models: a completed day is fetched once; today again after 5 min.
- Search: a new query cancels the old one; results with an old key generation are dropped.
- Identity reported from `organizationName`; `.connected` after success; `.expired` after 401.

## Build order (each step passes `make check`)

1. **Refactors**: `AccountPacing` generic + OpenRouter on it; `ReportedAmount` to Support;
   `prefersSignedInAppSignIn`. No behavior change.
2. **Core**: `RunwareAPI`, value types, `RunwareCLIConfig`, `RunwareSettings` + demand, the `AccountProvider` /
   `WidgetKind` / `WidgetSettings` cases, `Log.runware`, and all Core tests.
3. **Service**: `RunwareService`, `RunwareAccount`, `RunwareClient`, wiring (`AppEnvironment`, `AppController`,
   `AppComposition`), the Accounts views and key sheet, and service tests.
4. **Widget**: metadata, blocks, glance, builder, previews, and the released-configuration fixture.
5. **Details**: `DetailsRequest`/`DetailsContent`, the browser, and the three tabs.
6. **Verification**: manual checks, screenshots of all four layouts and three tabs (light/dark, a custom
   background), idle measurement.

Steps 1–2 can land as their own PR. Step 1 alone is a safe, reviewable refactor.

## Manual checks (record in the PR)

1. `make check`; all four layouts and the three presets in the Widgets window (`make dev`) with examples. The
   gallery preview reads no key: check `log stream --predicate 'category == "runware"'`.
2. Key account: add (check passes), wrong key (sheet shows why), replace, remove (widgets fall back to default).
3. CLI: install, `runware auth login` → widget with no account picks it up without restart (FileWatcher), Accounts
   shows "Runware CLI · Acme Corporation". `runware auth login` with another org's key → old balance disappears
   first. `runware auth logout` → "not signed in". A hand-broken config → "can't read".
4. Minimal and bar show the balance only; the tooltip has today's spend.
5. Details: History drill-down, model search paging, Copy AIR, account switch; close → the activity cadence returns
   to the widget's.
6. Hide panels with the hotkey → no requests (log). Wake after sleep → one catch-up fetch, not several.
7. Idle cost: Activity Monitor ~0% CPU between fetches. With `-SidelightRunwareURL` against a local fake, count
   requests over 30 minutes: 6 details + 2 activity for one Overview widget.

## Extension points (so later features don't force a redesign)

- **Task list**: if Runware ships a listing endpoint, add `RunwareTaskPage`, a `tasks` on-demand loader on
  `RunwareAccount` like `searchModels`, and a fourth tab. Demand and blocks don't change.
- **Task lookup**: `getTaskDetails` builder + a "Look up task…" field in History; `readOnlyTaskTypes` gains
  `getTaskDetails` (read-only).
- **Thumbnails**: `heroImage` is already decoded. Add a bounded image cache owned by the browser, loading visible
  rows only.
- **Per-key charts**: needs key UUIDs, which `getDetails` doesn't expose today. Ask Runware.

## Ideas (not in v1, Tom decides)

- **Low-balance warning**: an optional threshold on the Balance block. Below it, the figure (and the minimal/bar
  glance) turns orange. It's the most useful thing a balance widget can do at a glance, and costs nothing extra.
- **Spend-rate projection**: "≈ 18 days left at this week's pace", from balance ÷ 7-day average. Cheap, but label it
  an estimate.
- **AI Usage widget**: Runware doesn't fit there (it has no rate windows). Keep it out rather than force-fitting.
- The **Cloud** category is getting crowded (OpenRouter, Railway, Noodle, Docker, Runware). Revisit its name and
  split when the gallery feels long.

## Open questions

1. Is a day-level History an acceptable answer to "generation history" for v1? (Recommended: yes, with the honest
   footer, and ask Runware for a task-log API.)
2. Default refresh 5 minutes, or 15 like OpenRouter? (Recommended: 5; balance moves with every generation.)
3. Should the low-balance threshold be in v1? (Recommended: yes if cheap after step 4, otherwise first follow-up.)
4. If the CLI's config turns out to be more than a flat `api_key` (pre-build check 6), accept a small YAML
   dependency, or keep CLI support to key-account parity only? Decide then.
