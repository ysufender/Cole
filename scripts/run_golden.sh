#!/usr/bin/env bash
# Usage:
#   ./scripts/run_golden.sh            # check against recorded goldens
#   ./scripts/run_golden.sh --record   # (re)write goldens from current output
#
# Exit code: 0 if all match, 1 if any diverge (lists which ones).

set -u
cd "$(dirname "$0")/.."

BIN=./zig-out/bin/jaslc-debug
FIXTURES_VALID=tests/fixtures/valid
FIXTURES_INVALID=tests/fixtures/invalid
GOLDEN=tests/golden
RECORD=0
[ "${1:-}" = "--record" ] && RECORD=1

if [ ! -x "$BIN" ]; then
    echo "Build first: zig build debug" >&2
    exit 2
fi

fail=0

run_one() {
    local file="$1" flag="$2" label="$3"
    local out golden_file
    golden_file="$GOLDEN/$(basename "$file" .jasl).$label"

    out="$("$BIN" "$file" $flag --print-ast 2>&1; echo "EXIT:$?")"

    if [ "$RECORD" = "1" ]; then
        printf '%s\n' "$out" > "$golden_file"
        echo "recorded: $golden_file"
        return
    fi

    if [ ! -f "$golden_file" ]; then
        echo "MISSING GOLDEN: $golden_file (run with --record)"
        fail=1
        return
    fi

    if ! diff -q <(printf '%s\n' "$out") "$golden_file" > /dev/null; then
        echo "MISMATCH: $file [$label]"
        diff <(printf '%s\n' "$out") "$golden_file" | head -20
        fail=1
    fi
}

for f in "$FIXTURES_VALID"/*.jasl; do
    run_one "$f" --parse-only parse
    run_one "$f" --typecheck-only typecheck
    run_one "$f" "" full
done

for f in "$FIXTURES_INVALID"/*.jasl; do
    run_one "$f" --parse-only parse
done

if [ "$fail" = "1" ]; then
    echo "GOLDEN TESTS FAILED"
    exit 1
fi
echo "All golden tests passed."
