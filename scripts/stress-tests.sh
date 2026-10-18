#!/bin/bash
# Runs the test suite over and over on a busy machine, stopping at the first failure.
#
# A rare flake only shows up in reruns, and timing ones need the machine loaded, since everything in
# SidelightTests shares the main actor and under load a test and the work it waits for are no longer resumed in
# deadline order. Passing here proves nothing -- a CI runner is slower than this and the odds there are worse.
# scripts/check-test-waits.sh is what actually keeps the common cause out.
#
# Usage: scripts/stress-tests.sh [repetitions] [busy cores]
set -euo pipefail
cd "$(dirname "$0")/.."

REPETITIONS=${1:-20}
LOAD=${2:-$(sysctl -n hw.ncpu)}

# Build first, so the load below contends with the tests rather than with the compiler.
swift build --build-tests -Xswiftc -warnings-as-errors

SPINNERS=()
trap 'kill "${SPINNERS[@]}" 2>/dev/null || true' EXIT
for ((i = 0; i < LOAD; i++)); do
    (while :; do :; done) &
    SPINNERS+=($!)
done

echo "Running the suite up to $REPETITIONS times against $LOAD busy cores. Ctrl-C quits."
swift test --maximum-repetitions "$REPETITIONS" --repeat-until fail
