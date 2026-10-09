# Common tasks. Everything also works with plain `swift build` / `swift test` given DEVELOPER_DIR points at Xcode.

ifeq ($(origin DEVELOPER_DIR), undefined)
ifneq ($(wildcard /Applications/Xcode.app/Contents/Developer),)
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif
endif

SWIFT_SOURCES := Sources Tests Package.swift

.PHONY: build test app run dev format lint check clean

## Compile all targets (debug).
build:
	swift build

## Run the unit tests.
test:
	swift test

## Build and sign build/Sidelight.app (release).
app:
	scripts/build-app.sh release

## Build the app and (re)launch it.
run: app
	@pkill -x Sidelight && sleep 0.5 || true
	open build/Sidelight.app

## Debug build, run in the foreground with the app's logs in this terminal. Ctrl-C quits.
dev:
	scripts/build-app.sh debug
	@pkill -x Sidelight && sleep 0.5 || true
	@log stream --level debug --style compact --predicate 'subsystem == "app.getsidelight.Sidelight"' & \
		trap "kill $$! 2>/dev/null" EXIT; \
		build/Sidelight.app/Contents/MacOS/Sidelight

## Format all Swift sources in place.
format:
	swift format --in-place --recursive $(SWIFT_SOURCES)

## Fail on any formatting or style violation.
lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)

## What CI runs.
check: lint build test

clean:
	swift package clean
	rm -rf build
