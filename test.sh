set -e

zig build test
zig build debug
./scripts/run_golden.sh --record
./scripts/run_golden.sh
./scripts/fuzz.py --binary ./zig-out/bin/jaslc-debug --iterations 200

./scripts/triage_crashes.sh --binary ./zig-out/bin/jaslc-debug \
    --crashes-dir tests/crashes --out tests/crash_report.txt
