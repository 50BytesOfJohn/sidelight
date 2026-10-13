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
