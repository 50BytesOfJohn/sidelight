#!/usr/bin/env python3
"""Compile unchanged Core and service slices when the WIP app target cannot build.

This does not launch Sidelight, send network requests, or use real credentials.
The disposable package is intentionally not evidence that the full app compiles.
"""
import argparse
import pathlib
import shutil
import shlex
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SERVICES = [
    "Services/DataService.swift", "Services/PacedTask.swift", "Services/RemoteResource.swift",
    "Services/DelayedTask.swift", "Support/AppInfo.swift", "Accounts/AccountSecrets.swift",
    "Accounts/AccountStore.swift", "Configuration/ConfigurationStore.swift", "Widgets/OpenRouter/OpenRouterFormat.swift",
    "Widgets/OpenRouter/OpenRouterAccount.swift", "Widgets/OpenRouter/OpenRouterService.swift",
]
MANIFEST = '''// swift-tools-version: 6.4
import PackageDescription
let concurrency: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]
let package = Package(name: "OpenRouterValidation", platforms: [.macOS(.v26)], targets: [
    .target(name: "SidelightCore", swiftSettings: concurrency),
    .target(name: "Sidelight", dependencies: ["SidelightCore"],
            swiftSettings: concurrency + [.defaultIsolation(MainActor.self)]),
    .testTarget(name: "SidelightCoreTests", dependencies: ["SidelightCore"],
                resources: [.copy("ReleasedConfigurations")], swiftSettings: concurrency),
    .testTarget(name: "SidelightTests", dependencies: ["Sidelight", "SidelightCore"],
                swiftSettings: concurrency + [.defaultIsolation(MainActor.self)]),
], swiftLanguageModes: [.v6])
'''
MAKEFILE = '''export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
.PHONY: test
test:
\tswift test -Xswiftc -warnings-as-errors $(TEST_ARGS)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=pathlib.Path,
                        help="Use a new persistent scratch directory to keep build logs/artifacts")
    parser.add_argument("--filter", help="Swift Testing filter")
    args = parser.parse_args()
    directory = args.directory or pathlib.Path(tempfile.mkdtemp(prefix="openrouter-validation-"))
    if args.directory:
        directory.mkdir(parents=True, exist_ok=False)
    print(f"Test-only package: {directory}", flush=True)
    shutil.copytree(ROOT / "Sources/SidelightCore", directory / "Sources/SidelightCore")
    shutil.copytree(ROOT / "Tests/SidelightCoreTests", directory / "Tests/SidelightCoreTests")
    shutil.copytree(ROOT / "Tests/Fixtures", directory / "Tests/Fixtures")
    app = directory / "Sources/Sidelight"
    app.mkdir(parents=True)
    for source in SERVICES:
        shutil.copy2(ROOT / "Sources/Sidelight" / source, app / pathlib.Path(source).name)
    tests = directory / "Tests/SidelightTests"
    tests.mkdir(parents=True)
    for name in ["TestSupport.swift", "OpenRouterServiceTests.swift", "RemoteResourceTests.swift"]:
        shutil.copy2(ROOT / "Tests/SidelightTests" / name, tests / name)
    (directory / "Package.swift").write_text(MANIFEST)
    (directory / "Makefile").write_text(MAKEFILE)
    command = ["make", "test"]
    if args.filter:
        command.append("TEST_ARGS=--filter " + shlex.quote(args.filter))
    try:
        return subprocess.run(command, cwd=directory, check=False).returncode
    finally:
        if not args.directory:
            shutil.rmtree(directory)


if __name__ == "__main__":
    raise SystemExit(main())
