#!/usr/bin/env bash
# Usage:
#   ./scripts/triage_crashes.sh
#   ./scripts/triage_crashes.sh --binary ./zig-out/bin/jaslc-debug --crashes-dir tests/crashes --out tests/crash_report.txt
#
# Exit code: 0 if tests/crashes/ is empty, 1 if there's anything to
# triage (so it composes with `set -e` pipelines: run it last, let it
# be the thing that fails the run).

set -u
cd "$(dirname "$0")/.."

BIN=./zig-out/bin/jaslc-debug
CRASHES_DIR=tests/crashes
OUT=tests/crash_report.txt
TIMEOUT=5

while [ $# -gt 0 ]; do
    case "$1" in
        --binary) BIN="$2"; shift 2 ;;
        --crashes-dir) CRASHES_DIR="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ ! -x "$BIN" ]; then
    echo "Build first: zig build debug" >&2
    exit 2
fi

shopt -s nullglob
files=("$CRASHES_DIR"/*.jasl)

if [ ${#files[@]} -eq 0 ]; then
    echo "No crashes to triage ($CRASHES_DIR is empty)."
    : > "$OUT"
    exit 0
fi

tmp_raw=$(mktemp -d)
trap 'rm -rf "$tmp_raw"' EXIT

for f in "${files[@]}"; do
    name=$(basename "$f")
    out_file="$tmp_raw/$name.out"

    timeout "$TIMEOUT" "$BIN" "$f" --parse-only > "$out_file" 2>&1
    code=$?
    echo "EXIT_CODE=$code" >> "$out_file"
done

sig_of() {
    local out_file="$1"
    local sig
    sig=$(grep -iE "panic|reached unreachable|index out of (bounds|range)|integer overflow" "$out_file" | head -1)
    if [ -z "$sig" ]; then
        sig=$(grep -E "\.zig:[0-9]+:[0-9]+" "$out_file" | head -1)
    fi
    if [ -z "$sig" ]; then
        sig="(no panic trace) $(grep '^EXIT_CODE=' "$out_file")"
    fi
    echo "$sig"
}

declare -A groups

for f in "${files[@]}"; do
    name=$(basename "$f")
    out_file="$tmp_raw/$name.out"
    sig=$(sig_of "$out_file")
    groups["$sig"]="${groups[$sig]:-} $name"
done

{
    echo "Crash triage report"
    echo "binary:     $BIN"
    echo "crashes:    $CRASHES_DIR"
    echo "generated:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "total files: ${#files[@]}"
    echo "distinct signatures: ${#groups[@]}"
    echo "================================================================"

    n=0
    for sig in "${!groups[@]}"; do
        n=$((n + 1))
        members=(${groups[$sig]})
        echo ""
        echo "## [$n/${#groups[@]}] ${#members[@]} hit(s) — $sig"
        echo "----------------------------------------------------------------"
        echo "files: ${members[*]}"

        rep="${members[0]}"
        echo ""
        echo "--- repro: $rep ---"
        echo "\$ $BIN $CRASHES_DIR/$rep --parse-only"
        echo ""
        echo "input:"
        sed 's/^/    /' "$CRASHES_DIR/$rep"
        echo ""
        echo "output:"
        sed 's/^/    /' "$tmp_raw/$rep.out"
    done
} > "$OUT"

echo "Wrote $OUT — ${#files[@]} crash file(s), ${#groups[@]} distinct signature(s)."
echo "Top signatures:"
for sig in "${!groups[@]}"; do
    members=(${groups[$sig]})
    printf '%d\t%s\n' "${#members[@]}" "$sig"
done | sort -rn | while IFS=$'\t' read -r count sig; do
    printf '  (%sx) %s\n' "$count" "$sig"
done

exit 1
