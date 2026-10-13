# Frozen-WIP validation harness

Run from the repository root:

```sh
make -C Tests/OpenRouterHarness test
make -C Tests/OpenRouterHarness test ARGS='--directory /tmp/openrouter-validation-new'
make -C Tests/OpenRouterHarness test ARGS='--filter RemoteResourceTests'
make -C Tests/OpenRouterHarness lint
make -C Tests/OpenRouterHarness release-tests
```

The script creates a disposable Swift 6.4/macOS 26 package, copies all Core sources/tests and their fixtures,
and compiles selected unchanged service sources with the app's actor/concurrency settings. Swift commands
run through `make`, selecting Xcode. A persistent directory must be new; without it, scratch artifacts are
removed on exit. Test failures return a nonzero exit code and are not marked expected or suppressed.

The service tests inject memory-only credentials and fake transport. The harness never launches the app or
moves windows. It deliberately excludes SwiftUI views and the composition root. Passing this harness would
not establish that the full production app builds, passes `make check`, or meets native E2E gates.

Historical released JSON fixtures are unchanged. The updated release-fixture writer includes non-default
OpenRouter and details options for a future release; do not regenerate already-published fixture files.


For a native pass, first `make build`, then launch the debug product with:

```sh
python3 Tests/OpenRouterHarness/native_fixture.py --directory /tmp/openrouter-native-new
make -C Tests/OpenRouterHarness native-measure PID=<printed-disposable-pid>
```

The directory must be new and empty. The script runs the actual Core decoder safety test before launching:
invalid configs must never silently start default widgets. The fixture uses only Models, a loopback URL with
its required trailing slash, a fresh credential namespace, avoidance OFF, and an app predicate allowing no
real apps. No signing identities are discovered or changed. It copies the built binary and resources to a
disposable app. Ctrl-C terminates only that process and its fixture server. Public metadata measurement
prints only that PID's on-screen window bounds and display geometry, with no AX writes or recording grant.

Do not open Widgets or a builder in that launch: their production preview demand starts unrelated services,
which AppComposition currently cannot replace. Defer that E2E path or use a future appropriately isolated
composition. Synthetic API results and snapshots never establish private-account reconciliation or native
Space/AX safety. Use `make check` as the authoritative app/Core gate, even if it reports an intentional,
unsuppressed production regression from these tests.
