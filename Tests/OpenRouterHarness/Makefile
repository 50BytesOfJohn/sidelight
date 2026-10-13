# Test-only entry points; no app launch, AX writes or real credential operations.
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
.PHONY: test release-tests lint

test:
	python3 run.py $(ARGS)

release-tests:
	cd ../.. && python3 -m unittest discover -s Tests/ReleaseTests

lint:
	cd ../.. && swift format lint --strict Tests/SidelightCoreTests/OpenRouterAPITests.swift Tests/SidelightCoreTests/OpenRouterModelTests.swift Tests/SidelightCoreTests/OpenRouterConfigurationTests.swift Tests/SidelightCoreTests/ReservationTransitionTests.swift Tests/SidelightCoreTests/ReleasedConfigurationFixture.swift Tests/SidelightTests/RemoteResourceTests.swift Tests/SidelightTests/OpenRouterServiceTests.swift
	python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("run.py").read_text())'
