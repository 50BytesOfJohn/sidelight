# Test-only helpers link the core built by the repository Makefile; no production files are patched.
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
ROOT := ../..
PRODUCTS := $(ROOT)/.build/out/Products/Debug
OUT := $(ROOT)/build/agent-sessions-harness

.PHONY: config
config:
	mkdir -p $(OUT)
	xcrun swiftc -module-cache-path $(abspath $(OUT)/module-cache) -swift-version 6 -warnings-as-errors -I $(PRODUCTS) Config.swift $(PRODUCTS)/SidelightCore.o -lsqlite3 -o $(OUT)/config

# Package the real debug app without the root dev target's generic process termination.
.PHONY: debug-app
debug-app:
	cd $(ROOT) && scripts/build-app.sh debug

.PHONY: fixture-host
fixture-host:
	mkdir -p $(OUT)
	xcrun clang -Wall -Wextra -Werror FixtureHost.c -o $(OUT)/codex

.PHONY: measure
measure:
	mkdir -p $(OUT)
	xcrun clang -Wall -Wextra -Werror Measure.c -o $(OUT)/measure

.PHONY: service
service:
	mkdir -p $(OUT)
	xcrun swiftc -module-cache-path $(abspath $(OUT)/module-cache) -parse-as-library -swift-version 6 -warnings-as-errors -default-isolation MainActor \
		-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
		-I $(PRODUCTS) ServiceHarness.swift $(ROOT)/Sources/Sidelight/Widgets/AgentSessions/CursorChatsService.swift \
		$(PRODUCTS)/SidelightCore.o -lsqlite3 -o $(OUT)/service

.PHONY: routes
routes:
	mkdir -p $(OUT)
	xcrun swiftc -module-cache-path $(abspath $(OUT)/module-cache) -parse-as-library -swift-version 6 -warnings-as-errors -default-isolation MainActor \
		-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
		-I $(PRODUCTS) RouteHarness.swift $(ROOT)/Sources/Sidelight/Widgets/AgentSessions/AgentSessionOpener.swift \
		$(ROOT)/Sources/Sidelight/Widgets/ClaudeSessions/ClaudeSessionOpener.swift \
		$(ROOT)/Sources/Sidelight/Widgets/CodexSessions/CodexSessionOpener.swift $(ROOT)/Sources/Sidelight/Support/SessionHost.swift \
		$(ROOT)/Sources/Sidelight/Widgets/AgentSessions/OpenCodeSessionsService.swift \
		$(PRODUCTS)/SidelightCore.o -lsqlite3 -o $(OUT)/routes

# Test-only copies expose private decisions and replace external dispatch; see README.
.PHONY: contracts
contracts:
	python3 prepare-contracts.py
	xcrun swiftc -module-cache-path $(abspath $(OUT)/module-cache) -parse-as-library -swift-version 6 -warnings-as-errors -default-isolation MainActor \
		-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
		-I $(PRODUCTS) ContractHarness.swift ContractSupport.swift $(OUT)/contracts/*.swift \
		$(ROOT)/Sources/Sidelight/DesignSystem/CountBadge.swift $(ROOT)/Sources/Sidelight/DesignSystem/Motion.swift \
		$(ROOT)/Sources/Sidelight/Widgets/Framework/WidgetLayout.swift \
		$(PRODUCTS)/SidelightCore.o -lsqlite3 -o $(OUT)/contracts-runner

.PHONY: fsevents-probe
fsevents-probe:
	mkdir -p $(OUT)
	xcrun clang -Wall -Wextra -Werror -framework CoreServices FSEventsProbe.c -o $(OUT)/fsevents-probe

# Run mocked contracts from the worktree root with an isolated, test-only home.
.PHONY: contracts-check
contracts-check: contracts
	cd $(ROOT) && CFFIXED_USER_HOME="$(abspath $(OUT)/final-contract-home)" build/agent-sessions-harness/contracts-runner

.PHONY: opencode-service
opencode-service:
	mkdir -p $(OUT)
	xcrun swiftc -module-cache-path $(abspath $(OUT)/module-cache) -parse-as-library -swift-version 6 -warnings-as-errors -default-isolation MainActor \
		-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
		-I $(PRODUCTS) OpenCodeServiceHarness.swift $(ROOT)/Sources/Sidelight/Widgets/AgentSessions/OpenCodeSessionsService.swift \
		$(PRODUCTS)/SidelightCore.o -lsqlite3 -o $(OUT)/opencode-service

.PHONY: opencode-environment
opencode-environment:
	mkdir -p $(OUT)
	xcrun swiftc -module-cache-path $(abspath $(OUT)/module-cache) -parse-as-library -swift-version 6 -warnings-as-errors -default-isolation MainActor \
		-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
		-I $(PRODUCTS) OpenCodeEnvironmentHarness.swift $(ROOT)/Sources/Sidelight/Widgets/AgentSessions/OpenCodeSessionsService.swift \
		$(PRODUCTS)/SidelightCore.o -lsqlite3 -o $(OUT)/opencode-environment

.PHONY: fallback
fallback:
	python3 prepare-fallback.py
	xcrun swiftc -module-cache-path $(abspath $(OUT)/module-cache) -parse-as-library -swift-version 6 -warnings-as-errors -default-isolation MainActor \
		-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
		-I $(PRODUCTS) FallbackHarness.swift $(OUT)/fallback/*.swift \
		$(PRODUCTS)/SidelightCore.o -lsqlite3 -o $(OUT)/fallback-runner

.PHONY: clipboard
clipboard:
	mkdir -p $(OUT)
	xcrun swiftc -module-cache-path $(abspath $(OUT)/module-cache) -swift-version 6 -warnings-as-errors \
		ClipboardHarness.swift -lsqlite3 -o $(OUT)/clipboard

.PHONY: policy-check environment-check
policy-check:
	python3 opencode-policy-checks.py

environment-check: opencode-environment
	python3 opencode-environment-checks.py

.PHONY: fallback-asan
fallback-asan:
	python3 prepare-fallback.py
	xcrun swiftc -module-cache-path $(abspath $(OUT)/module-cache) -parse-as-library -swift-version 6 -warnings-as-errors -default-isolation MainActor \
		-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances -sanitize=address \
		-I $(PRODUCTS) FallbackHarness.swift $(OUT)/fallback/*.swift \
		$(PRODUCTS)/SidelightCore.o -lsqlite3 -o $(OUT)/fallback-asan
