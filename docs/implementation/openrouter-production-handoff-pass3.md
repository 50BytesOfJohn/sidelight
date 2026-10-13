# OpenRouter production handoff — pass 3

2026-10-13, Opus 5.5 High, production code only. Branch `feature/openrouter-widgets`.

- Previous production head: `e56132feb0e06ac4a90575bc68b9a4262f004b2d`
- **This pass (source-only commit): `a8da7d18a60021ecdc28535c52072956f4ef9b12`**. 9 files under `Sources/`, nothing in `Tests/`, fixtures, scripts, `Package.swift`, resources or docs.

**Nothing was built, linted, formatted, tested, launched or measured.** Everything below is source reasoning. I didn't touch the Sol tester's worktree and don't assume its results.

## S1–S7 disposition

| # | Disposition | What changed |
|---|---|---|
| S1 P1 | Fixed | `OpenRouterService` now separates *stored* (`hasKey`) from *authorized* (`isKeyWithdrawn`). `removeKey()` withdraws the key at once: `managementKey()` returns nil while withdrawn and never reads the keychain or updates `hasKey`. It clears private data via `forgetKeyData()` (generation bump, resources reset, key list and pending clicks dropped) but **keeps `AccountPacing`**, so a rejection or Retry-After still applies. On a failed delete (still the latest change) it sets `keyRemovalFailed = true` and `hasKey = true`. There's no `keyChanged()` and no reread. Only another `removeKey()` or a validated, written `saveKey()` (which resets pacing) changes state. Write queueing and change-generation checks are unchanged. Settings shows the failure as its own branch above the read state, with **Remove Again** and the key field to replace it (`OpenRouterKeyForm`). |
| S2 P1 | Fixed | `AccessibilityElement.readableWindows` returns `nil` when the window list can't be read. The shared `mayMove` gate now refuses when the list is unreadable, when the candidate isn't in it, or when **any** other window's frame is unreadable. The transition loop skips an app whose list can't be read; its claims on changed displays expire as before. Every mutation path still goes through this gate. |
| S3 P2 | Fixed | `WindowAvoider.remember` (everyday avoidance) never creates a `details` baseline. Only the takeover transition (`ReservationTransition.decide` with `kept[new.role]`) does that. A window that's unchanged since Sidelight last moved it keeps its existing layers with the new accepted frame, so a valid main layer is preserved. A new or changed window only gains a `main` baseline from main-panel avoidance (the existing hide/show rule). With no layer left there's nothing to remember, so the window can still follow its current contact on close (nil baselines). The reviewer's x=250 example now follows to x=208 and keeps its far edge. No second ledger. |
| S4 P2 | Fixed | `loadKeys` rechecks `pacing.hold` right after reading the key, immediately before the `/keys` send. New connection-level manual pacing: `AccountPacing.manualWait/manualActionTaken`, `manualActionGap` 15 s. `refreshAccount` (balance, plus that scope's activity in one click), `loadMoreKeys` and the new `retryKeys` go through `performManualAction`. Clicks inside the gap are queued and run together when it ends. The scope pre-check and activity request inside one fetch aren't separated. Per-resource freshness, backoff and 15 s gaps stay. Rejection and Retry-After still hold sends. Showing the picker again no longer retries a failed first page automatically; that needs **Try Again**. The old per-list `keyListRetryGap` is removed in favour of the shared gap. |
| S5 P2 | Fixed | `forgetAccountData()` always cancels key-page work, bumps `keyListGeneration` (checked after every await in `loadKeys`), clears list problem/loading/metadata, drops pending clicks, and resets the balance when it has a value, a problem or a fetch in flight. Each step is guarded, so repeated calls from `apply()` don't churn observation. The credential stays saved. |
| S6 P2 | Fixed | `Appearance.resolvedText(imageLuminance:onCards:)` and `colorScheme(system:imageURL:onCards:)` take a new `onCards` parameter, default `true`. The details panel passes `false`, so automatic text goes by the background it actually draws. Explicit light/dark is unchanged, and no new setting was added. |
| S7 P2 | Fixed | `HotkeyCenter.lastWorking` records each action's last successful registration and survives `suspend()` and refusals. Only `unregister` (deliberate removal) clears it. When the requested shortcut is refused, the action re-acquires its last working one, unless it's the one just refused or another action wants it or has it. `workingHotkey(for:)` still reports the live registration, so the Settings message matches the real state. |

## Assumptions and limits to note

- **S1 across relaunches:** withdrawal is in memory only. If the keychain delete failed and the app restarts, the item is read and used again. Persisting a "withdrawn" marker would need a new config field or a second keychain write. I didn't add either; root/user can decide.
- **S2 conservatism:** a single window with an unreadable frame (some apps' utility windows) now blocks avoidance and restoration for all of that app's windows. This is deliberate fail-closed behaviour; it needs native validation of how often it happens.
- **S4:** clicks inside the gap are delayed rather than dropped, and there's no visible "waiting" cue beyond the spinner when the request goes. The first key page on picker appear isn't treated as a manual action.
- **S7:** if another action now claims the old shortcut, it wins and the refused action is left without one; the problem stays visible.

## Possible compile issues and native checks for Sol

- Compile: `OpenRouterKeyList: Equatable` synthesis; nested `isCurrent()` closure capturing main-actor state in `loadKeys`; `[() -> Void]` stored in the main-actor service and run from a `DelayedTask` closure.
- Native: AX window-list and frame read failures in real apps (S2), Carbon refusal and fallback re-acquire (S7), and the rendered contrast of details text over inherited and custom backgrounds with opposing solid cards (S6).
- Test API notes: `OpenRouterService.retryKeys()` is new; `loadMoreKeys()` is now paced (the first call is immediate); `keyListRetryGap` is gone; `resolvedText` and `colorScheme` gained a defaulted parameter.

Stopped here for root to integrate the tester's results and rerun both Sol gates.
