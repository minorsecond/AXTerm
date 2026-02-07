#!/bin/bash
# AXTerm Test Runner
# Runs tests by category using the new organized structure.
#
# Usage:
#   Scripts/run-tests.sh                    # Run all tests
#   Scripts/run-tests.sh unit               # Run all unit tests
#   Scripts/run-tests.sh integration        # Run integration tests
#   Scripts/run-tests.sh regression         # Run regression tests
#   Scripts/run-tests.sh unit/protocol      # Run protocol unit tests
#   Scripts/run-tests.sh unit/analytics     # Run analytics unit tests
#   Scripts/run-tests.sh unit/routing       # Run routing unit tests
#   Scripts/run-tests.sh --verbose          # Show full output
#
# Test Structure:
#   AXTermTests/
#   ├── Unit/              (96 files) - Fast, pure logic tests
#   │   ├── Protocol/      (17) - AX.25, KISS, AXDP
#   │   ├── Analytics/     (17) - Graph, health, statistics
#   │   ├── Routing/       (19) - NET/ROM, link quality
#   │   ├── Core/          (27) - Settings, utilities, models
#   │   └── Transmission/  (16) - TX scheduling, file transfer
#   ├── Integration/       (15 files) - Multi-component tests
#   │   ├── Session/       (7)  - Session coordination
#   │   ├── Transfer/      (1)  - Bulk transfers
#   │   └── Relay/         (7)  - Digipeaters, NET/ROM
#   ├── Regression/        (5 files) - Edge cases, data integrity
#   └── Mocks/             (4 files) - Test utilities

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

VERBOSE=false
CATEGORY=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            head -25 "$0" | tail -23
            exit 0
            ;;
        unit|integration|regression|unit/*|Unit/*|Integration/*|Regression/*)
            CATEGORY="$1"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h for help"
            exit 1
            ;;
    esac
done

cd "$PROJECT_ROOT"

# Build test args based on category
TEST_ARGS=()
TEST_ARGS+=("-scheme" "AXTerm")
TEST_ARGS+=("-destination" "platform=macOS")

# Map category to test classes
get_test_classes() {
    local category="$1"
    local dir="AXTermTests/$category"
    
    # Normalize case
    case "$category" in
        unit|Unit) dir="AXTermTests/Unit" ;;
        integration|Integration) dir="AXTermTests/Integration" ;;
        regression|Regression) dir="AXTermTests/Regression" ;;
        unit/*) dir="AXTermTests/Unit/${category#unit/}" ;;
        Unit/*) dir="AXTermTests/${category}" ;;
        Integration/*) dir="AXTermTests/${category}" ;;
        Regression/*) dir="AXTermTests/${category}" ;;
    esac
    
    if [[ -d "$dir" ]]; then
        find "$dir" -name "*.swift" -exec basename {} .swift \; | grep -v "^Mock" | sort
    fi
}

if [[ -n "$CATEGORY" ]]; then
    echo -e "${CYAN}=== Running $CATEGORY tests ===${NC}"
    echo ""
    
    classes=$(get_test_classes "$CATEGORY")
    if [[ -z "$classes" ]]; then
        echo -e "${RED}No test classes found for category: $CATEGORY${NC}"
        exit 1
    fi
    
    for class in $classes; do
        TEST_ARGS+=("-only-testing:AXTermTests/$class")
    done
else
    echo -e "${GREEN}=== Running ALL tests ===${NC}"
    echo ""
fi

echo "Running tests..."
if [[ -n "$CATEGORY" ]]; then
    echo "Category: $CATEGORY"
    echo "Classes: $(echo "$classes" | wc -l | tr -d ' ') test files"
fi
echo ""

# Run tests
if [ "$VERBOSE" = true ]; then
    xcodebuild test "${TEST_ARGS[@]}" 2>&1
    RESULT=$?
else
    if command -v xcpretty &> /dev/null; then
        xcodebuild test "${TEST_ARGS[@]}" 2>&1 | xcpretty
        RESULT=${PIPESTATUS[0]}
    else
        xcodebuild test "${TEST_ARGS[@]}" 2>&1 | grep -E '(Test Case|passed|failed|error:|BUILD|Executed)'
        RESULT=${PIPESTATUS[0]}
    fi
fi

echo ""
if [ $RESULT -eq 0 ]; then
    echo -e "${GREEN}=== Tests Passed ===${NC}"
else
    echo -e "${RED}=== Tests Failed ===${NC}"
fi

exit $RESULT
