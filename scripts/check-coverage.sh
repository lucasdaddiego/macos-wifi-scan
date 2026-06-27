#!/usr/bin/env bash
# Fail unless the given source files are at 100% region AND line coverage.
#
#   check-coverage.sh <instrumented-binary> <profdata> <source...>
#
# Reads llvm-cov's JSON summary (via jq) for exactly the listed sources, so the
# gate ignores the test harness itself. Used by `make coverage` and CI.
set -euo pipefail

bin=${1:?usage: check-coverage.sh <binary> <profdata> <source...>}
prof=${2:?usage: check-coverage.sh <binary> <profdata> <source...>}
shift 2
[ "$#" -gt 0 ] || { echo "check-coverage.sh: no source files given" >&2; exit 2; }

summary=$(xcrun llvm-cov export -summary-only -instr-profile="$prof" "$bin" "$@")
regions=$(printf '%s' "$summary"   | jq -r '.data[0].totals.regions.percent')
lines=$(printf '%s' "$summary"     | jq -r '.data[0].totals.lines.percent')
functions=$(printf '%s' "$summary" | jq -r '.data[0].totals.functions.percent')

printf 'coverage: regions %.2f%%  lines %.2f%%  functions %.2f%%\n' "$regions" "$lines" "$functions"

# Exact 100% (with a float-rounding cushion — a single missed region in a file this
# size lands far below 99.999%, so the cushion can't mask a real gap).
if awk -v r="$regions" -v l="$lines" 'BEGIN { exit (r >= 99.999 && l >= 99.999) ? 0 : 1 }'; then
    echo "OK: 100% region + line coverage of $*"
else
    {
        echo "FAIL: $* must be at 100% region and line coverage (got regions ${regions}%, lines ${lines}%)."
        echo "      Inspect the gaps with:"
        echo "        xcrun llvm-cov show '$bin' -instr-profile='$prof' $* --show-regions --show-line-counts-or-regions"
    } >&2
    exit 1
fi
