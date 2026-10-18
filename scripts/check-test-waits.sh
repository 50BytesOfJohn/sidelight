#!/bin/bash
# Fails on a test that waits a fixed time.
#
# `make check` runs the suite once on an idle machine, so a fixed wait that a loaded machine outruns passes
# here and fails in CI. Tests/SidelightTests/TestSupport.swift has the two ways to wait instead: `eventually`
# for something that has to happen, `settle` for asserting that something doesn't.
set -euo pipefail
cd "$(dirname "$0")/.."

OFFENDERS=$(
    find Tests/SidelightTests Tests/SidelightCoreTests -name '*.swift' ! -name TestSupport.swift -print0 |
        xargs -0 awk '
            /sleeps on purpose/ { excused = FILENAME SUBSEP (FNR + 1) }
            /Task\.sleep/ && FILENAME SUBSEP FNR != excused { printf "%s:%d:%s\n", FILENAME, FNR, $0 }
        '
)

if [[ -n "$OFFENDERS" ]]; then
    echo "$OFFENDERS" >&2
    echo "error: tests must not wait a fixed time. Wait for something to happen with eventually { }, or let" >&2
    echo "work in flight run with settle() before asserting that it didn't happen. A sleep that is neither" >&2
    echo "needs a '// sleeps on purpose: <why>' comment on the line above it." >&2
    exit 1
fi
