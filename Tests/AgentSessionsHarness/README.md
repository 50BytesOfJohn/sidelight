# Stage 3 test-only support

These helpers do not modify production Swift files. `service` and `routes` compile **the actual app sources** alongside small test entry points and the core object produced by root `make build`. They return nonzero on failed expectations. They are separate from the SwiftPM core tests because the executable app target is not a test dependency.

Use Xcode 27/Swift 6.4 and a fresh home under this worktree's ignored `build/` directory. Run from the worktree root:

```sh
make build
make -C Tests/AgentSessionsHarness config fixture-host service routes measure
build/agent-sessions-harness/config /tmp/agent-stage3-config.json
python3 Tests/AgentSessionsHarness/fixtures.py build/agent-sessions-fixture-home
CFFIXED_USER_HOME="$PWD/build/agent-sessions-fixture-home" build/agent-sessions-harness/routes
CFFIXED_USER_HOME="$PWD/build/agent-sessions-service-home-fresh" build/agent-sessions-harness/service
```

The service checks take approximately 2–3 minutes, including the real 120-second missing sweep. A fresh service home is required each run. The fixture seeder starts five inert `sleep` processes and an inert executable deliberately named `codex` for kernel-based writer-lock discovery. **This is not the vendor Codex CLI.** It only holds fixture files open/locked; it has no agent, network, prompt, credential or history operations. Their exact PIDs are stored in the fixture home's `fixture-processes.json`; terminate only those PIDs after testing.

`config` writes a session-only configuration to the explicit destination. Automatic updates and window avoidance are off. `--diagnose`, used with a fixture home, prints only fixture process/file metadata. `measure <exact-app-pid> <seconds>` reads CPU and wakeup counters; intervals are bounded to 60 seconds.

For real UI validation:

```sh
make app
make -C Tests/AgentSessionsHarness debug-app
```

The second target packages the genuine debug app using the repository build script, omitting `make dev`'s generic `pkill`. For synthetic UI/settings tests, use this task-local sandbox profile:

```scheme
(version 1)
(allow default)
(deny network*)
(deny process-exec (subpath "/opt/homebrew") (subpath "/usr/local"))
```

Then launch the **real app executable** with `CFFIXED_USER_HOME` set to the fixture home and `sandbox-exec -f <profile> build/Sidelight.app/Contents/MacOS/Sidelight`. Record its exact PID and quit only that PID. This prevents installed CLIs and network usage requests while opening the Widgets gallery, which normally requests all usage services as well as all session services. Do not grant new OS permissions for fixtures.

`CFFIXED_USER_HOME` controls Foundation's home and application-support directories; setting `HOME` alone is not equivalent. Foundation normalizes `/private/tmp` to `/tmp`, while kernel file paths use `/private/tmp`. The existing Codex lock reader strips the unresolved prefix after matching resolved paths, so scratch homes under `/tmp` miss lock holders. A home under this worktree's `build/` avoids that existing path-alias limitation.

Use Computer Use for UI interactions/screenshots. Capture only synthetic content. Never dispatch fabricated session IDs to vendor session routes. Read [TESTING.md](../../research/agent-sessions/TESTING.md) for observed results and cleanup.

## Post-fix contracts and environment diagnosis

After `make build`, run `make -C Tests/AgentSessionsHarness contracts fsevents-probe`.
Run `contracts-runner` with `CFFIXED_USER_HOME` set to a fresh worktree `build/` home;
run `fsevents-probe <empty-scratch-directory>` in the **same execution sandbox** as
`service`. A probe reporting `stream_started=0` identifies an event-delivery limitation;
it does not turn timed-out service assertions into passes. Do not widen the sandbox to
manufacture an event result. Registration-dependent route checks print `NOT TESTED`
when Launch Services registrations are unavailable in their execution context.

`prepare-contracts.py` copies current production declarations into ignored
`build/agent-sessions-harness/contracts/` and records source SHA-256 hashes. It changes
only private access, the named AppKit/host/sound boundaries in the openers, and the
Cursor service's asynchronous read call. Production files are never patched. The
complete decision/publication/SwiftUI conditional bodies are compiled, rather than
reimplemented in tests. Claude/Codex service fields and list/logo leaves have small
stand-ins; real source readers, assets, layout, AX and destinations still need separate
validation. SwiftUI conditional-leaf inspection uses reflection and may need harness
maintenance with a future SwiftUI update.

The contract runner covers missing/usable/deleted/file/empty/root Cursor paths,
folder/app failure fallback, host/app routing, source availability and retained rows,
both Claude unknown labels, bar visible-target/help identity, and controlled old/new
read completion overlaps. Every external dispatch is mocked; no synthetic session ID
reaches a vendor app. Controlled-read barriers have a three-second setup timeout.
The genuine app is still built with `debug-app` and launched by its exact executable
with the documented synthetic home/profile. `make app` leaves a RELEASE bundle;
never infer its config directory from a previous test launch.

For the final narrow verification, `make -C Tests/AgentSessionsHarness contracts-check`
compiles and runs the current-source mocked contracts from the worktree root with an
isolated home under ignored `build/agent-sessions-harness/`. This does not launch the
packaged app or any vendor app. The editor-help matrix also checks absent/empty
working directories for both Codex and Claude. See the dated final-validation report
for the separate core timestamp-precision results; a passing mocked contract runner
does not establish timestamp correctness or any real vendor destination.
