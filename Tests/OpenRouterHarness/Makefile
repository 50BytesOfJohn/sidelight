# Test-only entry points; no app launch, AX writes or real credential operations.
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
.PHONY: test release-tests lint native-preflight native-measure

test:
	python3 run.py $(ARGS)

release-tests:
	cd ../.. && python3 -m unittest discover -s Tests/ReleaseTests

lint:
	cd ../.. && swift format lint --strict Tests/SidelightCoreTests/DecimalTextTests.swift Tests/SidelightCoreTests/NativeFixtureSafetyTests.swift Tests/SidelightCoreTests/OpenRouterAPITests.swift Tests/SidelightCoreTests/OpenRouterModelTests.swift Tests/SidelightCoreTests/OpenRouterConfigurationTests.swift Tests/SidelightCoreTests/ReservationTransitionTests.swift Tests/SidelightCoreTests/ReleasedConfigurationFixture.swift Tests/SidelightTests/OpenRouterSurfaceTests.swift Tests/OpenRouterHarness/native_measure.swift Tests/SidelightTests/RemoteResourceTests.swift Tests/SidelightTests/OpenRouterServiceTests.swift
	python3 -c 'import ast, pathlib; [ast.parse(p.read_text()) for p in [pathlib.Path("run.py"), pathlib.Path("native_fixture.py")]]'

# The config must decode before AppController can replace it with defaults.
native-preflight:
	cd ../.. && swift test -Xswiftc -warnings-as-errors --filter NativeFixtureSafetyTests

native-measure:
	swiftc -swift-version 6 -warnings-as-errors native_measure.swift -o /tmp/openrouter-pass2-native-measure
	/tmp/openrouter-pass2-native-measure $(PID)
