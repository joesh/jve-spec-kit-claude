#!/bin/bash
# run_all_bug_reporter_tests.sh
# Unified test runner for bug reporter system (local + CI)

set -e  # Exit on first failure

# Colors for output (if terminal supports it)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Test results tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
PHASE_RESULTS=()

# Function to run a test phase
run_phase() {
    local phase_num=$1
    local phase_name=$2
    local test_file=$3

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Phase $phase_num: $phase_name${NC}"
    echo -e "${BLUE}========================================${NC}"

    if [ ! -f "$test_file" ]; then
        echo -e "${RED}✗ Test file not found: $test_file${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        PHASE_RESULTS+=("Phase $phase_num: FAILED (file not found)")
        return 1
    fi

    # Run test and capture output
    if output=$(lua "$test_file" 2>&1); then
        # Extract test count from output
        if echo "$output" | grep -q "Passed:"; then
            count=$(echo "$output" | grep "Passed:" | tail -1 | sed 's/Passed: \([0-9]*\) .*/\1/')
            TOTAL_TESTS=$((TOTAL_TESTS + count))
            PASSED_TESTS=$((PASSED_TESTS + count))
        fi

        echo -e "${GREEN}✓ Phase $phase_num passed${NC}"
        PHASE_RESULTS+=("Phase $phase_num: PASSED")
        return 0
    else
        echo -e "${RED}✗ Phase $phase_num failed${NC}"
        echo "$output"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        PHASE_RESULTS+=("Phase $phase_num: FAILED")
        return 1
    fi
}

# Banner
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Bug Reporter Comprehensive Test Suite         ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
echo ""

# Check Lua installation
if ! command -v lua &> /dev/null; then
    echo -e "${RED}✗ Lua not found. Please install Lua 5.1 or LuaJIT${NC}"
    exit 1
fi

LUA_VERSION=$(lua -v 2>&1)
echo -e "${GREEN}✓ Lua detected: $LUA_VERSION${NC}"

# Check for dkjson
if ! lua -e "require('dkjson')" &> /dev/null; then
    echo -e "${YELLOW}⚠ dkjson not found. Installing via luarocks...${NC}"
    if command -v luarocks &> /dev/null; then
        luarocks install dkjson
    else
        echo -e "${RED}✗ luarocks not found. Please install dkjson manually${NC}"
        exit 1
    fi
fi

# Check for ffmpeg (optional - slideshow tests will note if missing)
if ! command -v ffmpeg &> /dev/null; then
    echo -e "${YELLOW}⚠ ffmpeg not found. Slideshow generation tests will be limited.${NC}"
    echo -e "${YELLOW}  Install with: brew install ffmpeg (macOS) or apt-get install ffmpeg (Linux)${NC}"
fi

echo ""

# Change to tests directory
cd "$(dirname "$0")"

# Run all test phases
run_phase 0 "Ring Buffers" "test_capture_manager.lua"
run_phase 2 "JSON Export" "test_bug_reporter_export.lua"
run_phase 3 "Slideshow Generation" "test_slideshow_generator.lua"
run_phase 4 "Mocked Test Runner" "test_mocked_runner.lua"
run_phase 5 "GUI Test Runner" "test_gui_runner.lua"
run_phase 6 "Upload System" "test_upload_system.lua"
run_phase 7 "UI Components" "test_ui_components.lua"

# Summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Test Suite Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

for result in "${PHASE_RESULTS[@]}"; do
    if [[ $result == *"PASSED"* ]]; then
        echo -e "${GREEN}✓ $result${NC}"
    else
        echo -e "${RED}✗ $result${NC}"
    fi
done

echo ""
echo -e "Total tests run: ${BLUE}$TOTAL_TESTS${NC}"
echo -e "Tests passed:    ${GREEN}$PASSED_TESTS${NC}"
echo -e "Tests failed:    ${RED}$FAILED_TESTS${NC}"
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          ✓ ALL TESTS PASSED! 🎉                   ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║          ✗ SOME TESTS FAILED                       ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════╝${NC}"
    exit 1
fi
