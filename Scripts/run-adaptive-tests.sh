#!/bin/bash
# AXTerm Adaptive Parameter Test Runner
# Runs all tests that cover adaptive transmission: per-route cache, merged config,
# link quality learning, vanilla AX.25 vs AXDP, and session config stability.
#
# Usage:
#   Scripts/run-adaptive-tests.sh                    # unit + integration (if sim available)
#   Scripts/run-adaptive-tests.sh --unit-only        # unit tests only
#   Scripts/run-adaptive-tests.sh --integration-only  # integration tests only (requires KISS sim)
#   Scripts/run-adaptive-tests.sh --verbose         # full xcodebuild output
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

RUN_UNIT=true
RUN_INTEGRATION=true
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --unit-only)
            RUN_UNIT=true
            RUN_INTEGRATION=false
            shift
            ;;
        --integration-only)
            RUN_UNIT=false
            RUN_INTEGRATION=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Runs all adaptive parameter functionality tests:"
            echo "  - AdaptiveSettingsTests (TxAdaptiveSettings, updateFromLinkQuality)"
            echo "  - SessionCoordinatorTests (per-route cache, merged config, clearAll, fixed config)"
            echo "  - AdaptiveTransmissionIntegrationTests (unit: full pipeline, vanilla/AXDP config)"
            echo "  - TxAdaptiveSettingsViewModelTests (UI binding)"
            echo "  - AXTermIntegrationTests/AdaptiveTransmissionIntegrationTests (vanilla AX.25 + AXDP over KISS)"
            echo ""
            echo "Options:"
            echo "  --unit-only         Run only unit tests (no KISS simulator required)"
            echo "  --integration-only Run only integration tests (requires sim on ports 8001/8002)"
            echo "  --verbose, -v       Full xcodebuild output"
            echo "  -h, --help          Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

run_xcode_test() {
    local scheme="$1"
    shift
    local args=("$@")
    if [ "$VERBOSE" = true ]; then
        xcodebuild test -scheme "$scheme" -destination "platform=macOS" "${args[@]}" 2>&1
        return $?
    fi
    if command -v xcpretty &> /dev/null; then
        xcodebuild test -scheme "$scheme" -destination "platform=macOS" "${args[@]}" 2>&1 | xcpretty
        return ${PIPESTATUS[0]}
    fi
    xcodebuild test -scheme "$scheme" -destination "platform=macOS" "${args[@]}" 2>&1 | grep -E '(Test Case|passed|failed|error:|BUILD|TEST)'
    return ${PIPESTATUS[0]}
}

cd "$PROJECT_ROOT"

TOTAL_RESULT=0

# -----------------------------------------------------------------------------
# Unit tests: adaptive settings, session coordinator, in-process integration
# -----------------------------------------------------------------------------
if [ "$RUN_UNIT" = true ]; then
    echo -e "${GREEN}=== Adaptive unit tests ===${NC}"
    echo "  AdaptiveSettingsTests"
    echo "  SessionCoordinatorTests"
    echo "  AdaptiveTransmissionIntegrationTests"
    echo "  TxAdaptiveSettingsViewModelTests"
    echo ""

    UNIT_ARGS=(
        "-only-testing:AXTermTests/AdaptiveSettingsTests"
        "-only-testing:AXTermTests/SessionCoordinatorTests"
        "-only-testing:AXTermTests/AdaptiveTransmissionIntegrationTests"
        "-only-testing:AXTermTests/TxAdaptiveSettingsViewModelTests"
    )

    if run_xcode_test "AXTerm" "${UNIT_ARGS[@]}"; then
        echo -e "${GREEN}Unit tests passed.${NC}"
    else
        echo -e "${RED}Unit tests failed.${NC}"
        TOTAL_RESULT=1
    fi
    echo ""
fi

# -----------------------------------------------------------------------------
# Integration tests: vanilla AX.25 + AXDP over KISS simulator
# -----------------------------------------------------------------------------
if [ "$RUN_INTEGRATION" = true ]; then
    echo -e "${GREEN}=== Adaptive integration tests (KISS simulator) ===${NC}"
    if nc -z localhost 8001 2>/dev/null && nc -z localhost 8002 2>/dev/null; then
        echo "Simulation ports 8001/8002 are open."
    else
        echo -e "${YELLOW}Simulation not detected on 8001/8002. Attempting to start...${NC}"
        if [ -x "$SCRIPT_DIR/sim-start.sh" ]; then
            "$SCRIPT_DIR/sim-start.sh" || true
        else
            echo -e "${YELLOW}Run Scripts/sim-start.sh first if you want integration tests.${NC}"
        fi
    fi
    echo ""

    INTEGRATION_ARGS=(
        "-only-testing:AXTermIntegrationTests/AdaptiveTransmissionIntegrationTests"
    )

    if run_xcode_test "AXTerm-Integration" "${INTEGRATION_ARGS[@]}"; then
        echo -e "${GREEN}Integration tests passed.${NC}"
    else
        echo -e "${RED}Integration tests failed (or simulator not available).${NC}"
        TOTAL_RESULT=1
    fi
    echo ""
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
if [ $TOTAL_RESULT -eq 0 ]; then
    echo -e "${GREEN}=== All adaptive parameter tests passed ===${NC}"
else
    echo -e "${RED}=== Some adaptive parameter tests failed ===${NC}"
fi

exit $TOTAL_RESULT
