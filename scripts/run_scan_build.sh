#!/bin/bash
# JVE clang static analyzer (scan-build) runner.
#
# Wraps a clean cmake configure + `make jve -j4` under scan-build, parses the
# resulting bug report, and exits non-zero if issues are found. Uses a separate
# build dir (build-scan/) so it never disturbs the normal build/ tree.
#
# Usage: scripts/run_scan_build.sh
# Exit:  0 no issues, 1 issues found, 0 if scan-build missing (don't break CI).
#
# Run from repo root.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SCAN_OUT="/tmp/jve-scan"
SCAN_BUILD_DIR="$REPO_ROOT/build-scan"

# ---- locate scan-build ----------------------------------------------------
SCAN_BUILD=""
for candidate in \
    "$(command -v scan-build 2>/dev/null || true)" \
    "/opt/homebrew/opt/llvm@21/bin/scan-build" \
    "/opt/homebrew/opt/llvm/bin/scan-build" \
    "/usr/local/opt/llvm/bin/scan-build"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        SCAN_BUILD="$candidate"
        break
    fi
done

if [ -z "$SCAN_BUILD" ]; then
    echo "scan-build not found."
    echo "Install via: brew install llvm"
    echo "(scan-build ships with Homebrew's llvm package, not Apple's CLT.)"
    exit 0
fi

echo "Using scan-build: $SCAN_BUILD"

# Use Apple's clang for --use-cc / --use-c++ — Homebrew LLVM's clang doesn't
# parse Apple-specific SDK macros (CF_ENUM nullability extensions) and the
# compile fails before the analyzer can run. scan-build itself can still come
# from Homebrew LLVM; only the compiler-driver-as-clang needs to be Apple's.
USE_CC="$(xcrun -f clang 2>/dev/null || true)"
USE_CXX="$(xcrun -f clang++ 2>/dev/null || true)"
[ -x "$USE_CC" ]  || USE_CC=""
[ -x "$USE_CXX" ] || USE_CXX=""

# ---- prepare output + scan build dir --------------------------------------
rm -rf "$SCAN_OUT"
mkdir -p "$SCAN_OUT"

# Fresh configure into build-scan/ so we don't trash build/.
rm -rf "$SCAN_BUILD_DIR"

SCAN_ARGS=(
    -o "$SCAN_OUT"
    --exclude /opt/homebrew
    --exclude /Library/Developer
    --exclude /usr/include
    --exclude /Applications/Xcode.app
    --status-bugs
)
[ -n "$USE_CC" ]  && SCAN_ARGS+=(--use-cc "$USE_CC")
[ -n "$USE_CXX" ] && SCAN_ARGS+=(--use-c++ "$USE_CXX")

echo "Configuring (scan-build cmake) into $SCAN_BUILD_DIR ..."
if ! "$SCAN_BUILD" "${SCAN_ARGS[@]}" cmake -B "$SCAN_BUILD_DIR" -S "$REPO_ROOT" \
        > /tmp/jve-scan-configure.log 2>&1; then
    echo "cmake configure under scan-build FAILED. See /tmp/jve-scan-configure.log"
    tail -40 /tmp/jve-scan-configure.log
    exit 1
fi

echo "Building (scan-build make jve -j4) ..."
BUILD_LOG="/tmp/jve-scan-build.log"
set +e
"$SCAN_BUILD" "${SCAN_ARGS[@]}" \
    make -C "$SCAN_BUILD_DIR" jve -j4 > "$BUILD_LOG" 2>&1
BUILD_RC=$?
set -e

# scan-build --status-bugs returns non-zero if bugs found OR build failed.
# Disambiguate by checking whether the binary linked.
BUILT=0
if find "$SCAN_BUILD_DIR" -name 'jve' -type f -perm -u+x 2>/dev/null | grep -q .; then
    BUILT=1
fi
if [ "$BUILT" -eq 0 ]; then
    echo "scan-build build FAILED (binary not produced). See $BUILD_LOG"
    tail -60 "$BUILD_LOG"
    exit 1
fi

# ---- parse findings -------------------------------------------------------
# scan-build writes one HTML report per bug into a timestamped subdir of $SCAN_OUT.
# When zero bugs exist, no subdir is created — handle that cleanly.
REPORT_DIR=""
if [ -d "$SCAN_OUT" ]; then
    REPORT_DIR="$(find "$SCAN_OUT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
fi

if [ -z "$REPORT_DIR" ] || [ ! -d "$REPORT_DIR" ]; then
    echo ""
    echo "scan-build: no issues found."
    echo "Build log: $BUILD_LOG"
    exit 0
fi

# Each report is an HTML file with a BUGTYPE/BUGFILE/BUGLINE header.
TOTAL=0
declare -a CATS
CATS=()
while IFS= read -r html; do
    TOTAL=$((TOTAL + 1))
    bugtype=$(grep -m1 '<!-- BUGTYPE ' "$html" 2>/dev/null | sed -E 's/.*BUGTYPE (.*) -->.*/\1/')
    bugfile=$(grep -m1 '<!-- BUGFILE ' "$html" 2>/dev/null | sed -E 's/.*BUGFILE (.*) -->.*/\1/')
    bugline=$(grep -m1 '<!-- BUGLINE ' "$html" 2>/dev/null | sed -E 's/.*BUGLINE (.*) -->.*/\1/')
    CATS+=("${bugtype}|${bugfile}:${bugline}")
done < <(find "$REPORT_DIR" -name 'report-*.html' 2>/dev/null)

if [ "$TOTAL" -eq 0 ]; then
    echo "scan-build: no issues found."
    echo "Report dir: $REPORT_DIR (empty)"
    exit 0
fi

echo ""
echo "===== scan-build: $TOTAL issue(s) ====="
echo "Report:   $REPORT_DIR/index.html"
echo "Build log: $BUILD_LOG"
echo ""
echo "By category:"
printf '%s\n' "${CATS[@]}" | awk -F'|' '{print $1}' | sort | uniq -c | sort -rn
echo ""
echo "Top 10 issues (file:line: category):"
printf '%s\n' "${CATS[@]}" | awk -F'|' '{print $2": "$1}' | sort -u | head -10

exit 1
