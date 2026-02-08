#!/bin/bash
#
# run-connected-mode-tests.sh
#
# Comprehensive integration tests for connected-mode messaging and transfers.
# Tests both AXDP-enabled and raw packet communication.
#
# Usage:
#   ./run-connected-mode-tests.sh              # Run all connected mode tests
#   ./run-connected-mode-tests.sh with_relay   # Also run tests requiring Docker relay
#   ./run-connected-mode-tests.sh quick        # Quick subset of tests
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== AXTerm Connected Mode Integration Tests ==="
echo ""

# Build test arguments
TEST_ARGS=()
TEST_ARGS+=("-scheme" "AXTerm")
TEST_ARGS+=("-destination" "platform=macOS")

# Determine which tests to run
MODE="${1:-all}"

case "$MODE" in
    quick)
        echo "Running quick subset of tests..."
        TEST_ARGS+=("-only-testing:AXTermTests/ConnectedModeIntegrationTests/testConnectionEstablishment")
        TEST_ARGS+=("-only-testing:AXTermTests/ConnectedModeIntegrationTests/testPlainTextSingleMessage")
        TEST_ARGS+=("-only-testing:AXTermTests/ConnectedModeIntegrationTests/testAXDPChatSingleFragment")
        TEST_ARGS+=("-only-testing:AXTermTests/ConnectedModeIntegrationTests/testAXDPToNonAXDP")
        ;;
    with_relay)
        echo "Running all tests including Docker relay tests..."
        # In-memory tests
        TEST_ARGS+=("-only-testing:AXTermTests/ConnectedModeIntegrationTests")
        TEST_ARGS+=("-only-testing:AXTermTests/ConnectedModePerformanceTests")
        TEST_ARGS+=("-only-testing:AXTermTests/PlainTextAndMixedModeTests")
        TEST_ARGS+=("-only-testing:AXTermTests/LargeMultiFragmentAXDPTests")
        # Docker relay tests
        TEST_ARGS+=("-only-testing:AXTermTests/KISSRelayIntegrationTests")
        
        # Check if Docker relay is available
        if ! nc -z localhost 8001 2>/dev/null; then
            echo ""
            echo "WARNING: Docker KISS relay not available on port 8001"
            echo "To start the relay: cd Docker && docker-compose up -d"
            echo "Relay tests will be skipped."
            echo ""
        fi
        ;;
            all|*)
                echo "Running all in-memory connected mode tests..."
                TEST_ARGS+=("-only-testing:AXTermTests/ConnectedModeIntegrationTests")
                TEST_ARGS+=("-only-testing:AXTermTests/ConnectedModePerformanceTests")
                TEST_ARGS+=("-only-testing:AXTermTests/PlainTextAndMixedModeTests")
                TEST_ARGS+=("-only-testing:AXTermTests/LargeMultiFragmentAXDPTests")
                TEST_ARGS+=("-only-testing:AXTermTests/ConnectionEdgeCaseTests")
                TEST_ARGS+=("-only-testing:AXTermTests/FlowControlTests")
                TEST_ARGS+=("-only-testing:AXTermTests/ErrorRecoveryTests")
                TEST_ARGS+=("-only-testing:AXTermTests/AXDPEdgeCaseTests")
                TEST_ARGS+=("-only-testing:AXTermTests/LargeTransferStressTests")
                TEST_ARGS+=("-only-testing:AXTermTests/DigipeaterPathTests")
                TEST_ARGS+=("-only-testing:AXTermTests/MixedModeComprehensiveTests")
                # Manual relay / session chaining tests
                TEST_ARGS+=("-only-testing:AXTermTests/ManualRelayTests")
                TEST_ARGS+=("-only-testing:AXTermTests/MultiHopRelayTests")
                TEST_ARGS+=("-only-testing:AXTermTests/ViaPathVsManualRelayTests")
                TEST_ARGS+=("-only-testing:AXTermTests/RelayEdgeCaseTests")
                # Connection validation / address routing tests
                TEST_ARGS+=("-only-testing:AXTermTests/AddressValidationTests")
                TEST_ARGS+=("-only-testing:AXTermTests/SessionKeyTests")
                TEST_ARGS+=("-only-testing:AXTermTests/ConnectionRoutingTests")
                TEST_ARGS+=("-only-testing:AXTermTests/SelfConnectionPreventionTests")
                TEST_ARGS+=("-only-testing:AXTermTests/ConnectionStateTransitionTests")
                TEST_ARGS+=("-only-testing:AXTermTests/CallsignEdgeCasesTests")
                TEST_ARGS+=("-only-testing:AXTermTests/PathSignatureTests")
                TEST_ARGS+=("-only-testing:AXTermTests/IncomingFrameAddressVerificationTests")
                TEST_ARGS+=("-only-testing:AXTermTests/ConnectionRegressionTests")
                ;;
esac

echo ""
echo "Test categories:"
echo "  - Connection establishment (SABM/UA/DISC)"
echo "  - Plain text I-frame exchange"
echo "  - AXDP chat fragmentation & reassembly"
echo "  - AXDP file transfer"
echo "  - Mixed mode (AXDP ↔ non-AXDP)"
echo "  - Sequence number wraparound"
echo "  - Error handling (out-of-sequence)"
echo ""

# Run the tests
cd "$PROJECT_DIR"
echo "Running: xcodebuild test ${TEST_ARGS[*]}"
echo ""

if xcodebuild test "${TEST_ARGS[@]}" 2>&1 | tee /tmp/connected-mode-tests.log | grep -E "(Test case|TEST SUCCEEDED|TEST FAILED|error:|passed|failed)"; then
    echo ""
    PASSED=$(grep -c "passed" /tmp/connected-mode-tests.log || true)
    FAILED=$(grep -c "failed" /tmp/connected-mode-tests.log || true)
    echo "=== Summary: $PASSED passed, $FAILED failed ==="
    
    if [ "$FAILED" -gt 0 ]; then
        echo ""
        echo "=== Connected Mode Tests Failed ==="
        exit 1
    else
        echo ""
        echo "=== Connected Mode Tests Passed ==="
        exit 0
    fi
else
    echo ""
    echo "=== Test execution failed ==="
    exit 1
fi
