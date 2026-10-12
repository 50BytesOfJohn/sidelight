# Agent session validation harnesses

These test-only helpers compile current app source with Xcode 27 / Swift 6.4, linking
SidelightCore built by root `make`. No production source is patched. Run from the worktree root:

```sh
make check
make -C Tests/AgentSessionsHarness contracts-check opencode-environment opencode-service service fsevents-probe fallback
python3 Tests/AgentSessionsHarness/opencode-policy-checks.py
python3 Tests/AgentSessionsHarness/opencode-environment-checks.py
CFFIXED_USER_HOME="$PWD/build/opencode-testing/fresh-opencode-home" build/agent-sessions-harness/opencode-service
CFFIXED_USER_HOME="$PWD/build/agent-sessions-service-home-fresh" build/agent-sessions-harness/service
build/agent-sessions-harness/fsevents-probe build/opencode-testing
CFFIXED_USER_HOME="$PWD/build/opencode-testing/fresh-fallback-home" build/agent-sessions-harness/fallback-runner
# Only when the same-context raw probe reports created=1, started=0:
CFFIXED_USER_HOME="$PWD/build/opencode-testing/fresh-actual-fallback-home" build/agent-sessions-harness/fallback-runner --actual-fallback
```

Use a fresh owned home each service/fallback run. Timed checks take several minutes.
Service event timeouts remain failures when FSEvents cannot start; never widen permissions
or disable a failure to manufacture event delivery. The fallback harness separately proves
successful initial reads retain their real 120-second sweep and read later writes.

`prepare-contracts.py` generates copies under ignored build/, with source hashes. It
exposes private declarations, mocks named AppKit/host/sound/process boundaries and controls
only the session index's asynchronous reader calls, through the read closure its initializer
takes (Cursor and OpenCode share one `WatchedSessionIndex`). All actual decision/publication
bodies stay.
SwiftUI conditional leaves (the shared `WidgetMessage`, or the list) are reflected with small
source-service/list/logo stand-ins;
row/menu/help/glance bodies compile too. Layout and OS AX still require real app validation.

OpenCode policy is metadata only. Exactly two verbatim plaintext copies are offered; no
session-opening route, command, CLI discovery or Terminal transport. Former command-builder
tests are replaced by refusal/clipboard contracts for wrong store/default environment,
underlying V1 override, stale/deleted model, no installation, removed executable and hostile
ID/path/control inputs. OpenCodeCommandHarness and its shell/Terminal driver are retired.
The structural policy checker adds privacy, row/AX/menu and packaging tripwires. Existing
Claude/Codex/Cursor routing and help contracts remain. Core metadata/schema/config/demand/WAL
checks remain in Swift Testing.

`prepare-fallback.py` copies the exact shared FileEventStream wrapper and the actual
`WatchedSessionIndex` (the one class behind both services) with `CoalescedReload`,
`RepeatingTask` and `DataService`, exposing private state and renaming the wrapper to avoid
the core module symbol.
Only C Start/Stop/Invalidate/Release calls are observed; allocation, context release callback,
readers and timers are real. Start's Boolean is injected deterministically for lifecycle
checks, with real C invalidation/release. CoreServices may release its callback asynchronously
on the assigned queue; ownership checks allow that queue to drain. Success cleanup still
requires Stop → Invalidate → Release once. In `--actual-fallback`, Start passes through to
CoreServices for the service phase; this mode requires an environment where Start fails.
The headless event delivery gap is distinct from mocked failure-branch coverage.
`fallback-asan` builds the same wrapper boundary with AddressSanitizer; run its binary
with `--lifecycle-only` and a fresh synthetic home for the seven short ownership checks.

Synthetic licensed native DDL is packaged in `Tests/Fixtures/OpenCodeV2/`, with upstream
pin, provenance and full MIT notice. Neither core tests nor UI fixture creation depend on
research files. Include that directory in the intended commit.

For real UI validation:

```sh
make -C Tests/AgentSessionsHarness debug-app config
python3 Tests/AgentSessionsHarness/opencode-fixtures.py build/opencode-testing/fresh-ui-home
```

`debug-app` packages the genuine DEBUG executable with the repository script, avoiding the
root dev/run targets' generic pkill. Verify successful fresh packaging, debug build UUID and
exact owned PID before binding Computer Use. Launch that exact executable with HOME and
CFFIXED_USER_HOME set only in its child environment to the synthetic home. Clear inherited
OPENCODE_DB/OPENCODE_BIN_PATH/XDG overrides. Use the seeder's `ui.sb` profile, denying network
and vendor executables in /opt/homebrew and /usr/local. Usage widgets are absent, updates and
window avoidance off. Gallery previews can request usage services, so keep the restrictive
profile. No credentials, registration, vendor CLI, real session dispatch or new OS grants.

Use Computer Use for menu/layout/screenshots, capturing only this synthetic app. The optional
`clipboard` target compiles ClipboardHarness.swift; run it before copying in a context able
to access the system pasteboard (`changeCount >= 0`). It snapshots all original types/data
only in memory, compares `id`/`folder` commands against the fixture, and `restore` restores
only if the clipboard has not changed externally. Never print/store private clipboard data.
A negative changeCount means the shell sandbox cannot access the pasteboard: stop that helper
before copying; don't mistake a nil read for a product copy failure.

`config` writes only the explicit destination. `fixture-host`, `measure`, and `routes` are
legacy helpers: routes never dispatches, measure takes one exact PID, fixture-host is an
inert file/lock holder, not a vendor CLI. Legacy fixtures.py starts owned inert processes;
terminate only recorded exact PIDs. No OpenCode fixture seeder starts a process.

See [REVALIDATION.md](../../research/opencode-sessions/REVALIDATION.md) for dated results and
honest runtime limitations. Earlier TESTING.md records the now-retired resume policy.
