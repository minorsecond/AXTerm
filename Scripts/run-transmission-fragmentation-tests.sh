#!/bin/bash
# AXTerm Transmission Fragmentation Test Runner
# Runs TransmissionFragmentationTests: paclen, window, reassembly for short/long/control/file payloads.
#
# Usage:
#   Scripts/run-transmission-fragmentation-tests.sh
#   Scripts/run-transmission-fragmentation-tests.sh --verbose
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

VERBOSE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v   Show full xcodebuild output"
            echo "  -h, --help      Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

cd "$PROJECT_ROOT"

TEST_ARGS=("-scheme" "AXTerm" "-destination" "platform=macOS")
TEST_ARGS+=("-only-testing:AXTermTests/TransmissionFragmentationTests")
TEST_ARGS+=("-only-testing:AXTermTests/PlainTextAndMixedModeTests")

echo -e "${GREEN}=== Transmission Fragmentation Tests ===${NC}"
echo "  xcodebuild test ${TEST_ARGS[*]}"
echo ""

if [ "$VERBOSE" = true ]; then
    xcodebuild test "${TEST_ARGS[@]}" 2>&1
    RESULT=$?
else
    if command -v xcpretty &> /dev/null; then
        xcodebuild test "${TEST_ARGS[@]}" 2>&1 | xcpretty
        RESULT=${PIPESTATUS[0]}
    else
        xcodebuild test "${TEST_ARGS[@]}" 2>&1 | grep -E '(Test Case|passed|failed|error:|BUILD|TEST)'
        RESULT=${PIPESTATUS[0]}
    fi
fi

echo ""
if [ $RESULT -eq 0 ]; then
    echo -e "${GREEN}=== Transmission Fragmentation Tests Passed ===${NC}"
else
    echo -e "${RED}=== Transmission Fragmentation Tests Failed ===${NC}"
fi
exit $RESULT
