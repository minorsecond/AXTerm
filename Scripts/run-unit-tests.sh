#!/bin/bash
# AXTerm Unit Test Runner
# Runs all AXTerm unit tests (AX25, connected mode, KISS, etc.) on macOS.
#
# Usage:
#   Scripts/run-unit-tests.sh              # run all unit tests (pretty output if xcpretty is installed)
#   Scripts/run-unit-tests.sh --verbose    # full xcodebuild log
#   Scripts/run-unit-tests.sh --filter AX25SessionTests/testHandleInboundIFrameWithNoSessionDoesNotRespondWithDM
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

VERBOSE=false
TEST_FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --filter)
            TEST_FILTER="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v        Show full xcodebuild output"
            echo "  --filter TESTSPEC    Only run tests matching TESTSPEC"
            echo "                       e.g. AX25SessionTests/testHandleInboundIFrameWithNoSessionDoesNotRespondWithDM"
            echo "  -h, --help           Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo -e "${GREEN}=== AXTerm Unit Tests ===${NC}"
echo ""

cd "$PROJECT_ROOT"

TEST_ARGS=()
TEST_ARGS+=("-scheme" "AXTerm")
TEST_ARGS+=("-destination" "platform=macOS")

if [ -n "$TEST_FILTER" ]; then
    TEST_ARGS+=("-only-testing:AXTermTests/$TEST_FILTER")
else
    TEST_ARGS+=("-only-testing:AXTermTests")
fi

echo "Running unit tests with args:"
echo "  xcodebuild test ${TEST_ARGS[*]}"
echo ""

if [ "$VERBOSE" = true ]; then
    xcodebuild test "${TEST_ARGS[@]}" 2>&1
    TEST_RESULT=$?
else
    if command -v xcpretty &> /dev/null; then
        xcodebuild test "${TEST_ARGS[@]}" 2>&1 | xcpretty
        TEST_RESULT=${PIPESTATUS[0]}
    else
        xcodebuild test "${TEST_ARGS[@]}" 2>&1 | grep -E '(Test Case|passed|failed|error:|BUILD|TEST)'
        TEST_RESULT=${PIPESTATUS[0]}
    fi
fi

echo ""

if [ $TEST_RESULT -eq 0 ]; then
    echo -e "${GREEN}=== All Unit Tests Passed ===${NC}"
else
    echo -e "${RED}=== Unit Tests Failed ===${NC}"
fi

exit $TEST_RESULT

