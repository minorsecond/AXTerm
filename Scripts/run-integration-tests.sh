#!/bin/bash
# AXTerm Integration Test Runner
# Starts simulation if needed, runs integration tests, and reports results

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Parse arguments
STOP_AFTER=false
VERBOSE=false
TEST_FILTER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --stop-after)
            STOP_AFTER=true
            shift
            ;;
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
            echo "  --stop-after   Stop simulation after tests complete"
            echo "  --verbose, -v  Show verbose test output"
            echo "  --filter NAME  Only run tests matching NAME"
            echo "  -h, --help     Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo -e "${GREEN}=== AXTerm Integration Tests ===${NC}"
echo ""

# Check if simulation is running
if ! nc -z localhost 8001 2>/dev/null || ! nc -z localhost 8002 2>/dev/null; then
    echo "Simulation not running. Starting..."
    "$SCRIPT_DIR/sim-start.sh"
    echo ""
fi

# Verify ports are accessible
echo "Verifying simulation connectivity..."
if ! nc -z localhost 8001 2>/dev/null; then
    echo -e "${RED}Error: Station A (port 8001) not accessible${NC}"
    exit 1
fi
if ! nc -z localhost 8002 2>/dev/null; then
    echo -e "${RED}Error: Station B (port 8002) not accessible${NC}"
    exit 1
fi
echo -e "${GREEN}Simulation is ready${NC}"
echo ""

# Build test arguments
TEST_ARGS=()
TEST_ARGS+=("-scheme" "AXTerm-Integration")
TEST_ARGS+=("-destination" "platform=macOS")

if [ -n "$TEST_FILTER" ]; then
    TEST_ARGS+=("-only-testing:AXTermIntegrationTests/$TEST_FILTER")
else
    TEST_ARGS+=("-only-testing:AXTermIntegrationTests")
fi

# Run tests
echo "Running integration tests..."
echo ""

cd "$PROJECT_ROOT"

if [ "$VERBOSE" = true ]; then
    xcodebuild test "${TEST_ARGS[@]}" 2>&1
    TEST_RESULT=$?
else
    # Use xcpretty if available, otherwise fall back to grep
    if command -v xcpretty &> /dev/null; then
        xcodebuild test "${TEST_ARGS[@]}" 2>&1 | xcpretty
        TEST_RESULT=${PIPESTATUS[0]}
    else
        xcodebuild test "${TEST_ARGS[@]}" 2>&1 | grep -E '(Test Case|passed|failed|error:|BUILD|TEST)'
        TEST_RESULT=${PIPESTATUS[0]}
    fi
fi

echo ""

# Report results
if [ $TEST_RESULT -eq 0 ]; then
    echo -e "${GREEN}=== All Integration Tests Passed ===${NC}"
else
    echo -e "${RED}=== Integration Tests Failed ===${NC}"
fi

# Stop simulation if requested
if [ "$STOP_AFTER" = true ]; then
    echo ""
    "$SCRIPT_DIR/sim-stop.sh" --halt
fi

exit $TEST_RESULT
