#!/bin/bash
# AXTerm Network Test Runner
# Runs all networking-related tests: AX.25, packet handling, AXDP, file transfers,
# bulk transfers, protocol implementations (YAPP, 7+, Raw Binary), KISS transport,
# connected-mode networking, and link quality (unit tests, plus optional integration tests).
#
# Includes:
#   - AX.25 frame handling, session management, I-frame reordering
#   - AXDP protocol, capabilities, compatibility
#   - File transfer protocols (YAPP, 7+, Raw Binary, AXDP)
#   - Bulk transfer coordination and metrics
#   - KISS encoding/decoding and transport
#   - NET/ROM link quality and routing
#   - Transmission scheduling and edge cases
#
# Usage:
#   Scripts/run-network-tests.sh
#   Scripts/run-network-tests.sh --verbose
#   Scripts/run-network-tests.sh --with-integration
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
WITH_INTEGRATION=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --with-integration)
            WITH_INTEGRATION=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v        Show full xcodebuild output"
            echo "  --with-integration   Also run AXTermIntegrationTests networking suites"
            echo "  -h, --help           Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo -e "${GREEN}=== AXTerm Network Tests (AX.25 / Packet / AXDP / File Transfer / KISS) ===${NC}"
echo ""

cd "$PROJECT_ROOT"

UNIT_TEST_ARGS=()
UNIT_TEST_ARGS+=("-scheme" "AXTerm")
UNIT_TEST_ARGS+=("-destination" "platform=macOS")

# Core AX.25 / packet / AXDP / link-quality classes
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/AX25Tests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/AX25SessionTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/AX25FrameBuildingTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/AX25ControlFieldDecoderTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/IFrameReorderingTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/ConnectedModeTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/PacketHandlingTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/PacketOrderingTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/PacketPersistenceControlFieldTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/PacketEncodingTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/AXDPTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/AXDPCompatibilityTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/AXDPCapabilityTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/SessionCoordinatorTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/LinkQualityControlTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/NetRomLinkQualityTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/NetRomLinkQualitySourceModeTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/NetRomLinkQualityPersistenceRehydrationTests")

# File transfer / bulk transfer / protocol tests
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/FileTransferProtocolTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/FileTransferReceiverTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/BulkTransferTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/TransferMetricsTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/TransferProtocolRegistryTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/RawBinaryProtocolTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/SevenPlusProtocolTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/YAPPProtocolTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/WholeFileCompressionTests")

# KISS / transport / frame transmission tests
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/KISSTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/KISSEncodingTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/KISSTransportTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/KISSRelayIntegrationTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/OutboundFrameTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/TerminalTxViewModelTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/TxSchedulerTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/TxSchedulerIntegrationTests")
UNIT_TEST_ARGS+=("-only-testing:AXTermTests/TransmissionEdgeCaseTests")

echo "Running unit networking tests..."
echo "  xcodebuild test ${UNIT_TEST_ARGS[*]}"
echo ""

if [ "$VERBOSE" = true ]; then
    xcodebuild test "${UNIT_TEST_ARGS[@]}" 2>&1
    UNIT_RESULT=$?
else
    if command -v xcpretty &> /dev/null; then
        xcodebuild test "${UNIT_TEST_ARGS[@]}" 2>&1 | xcpretty
        UNIT_RESULT=${PIPESTATUS[0]}
    else
        xcodebuild test "${UNIT_TEST_ARGS[@]}" 2>&1 | grep -E '(Test Case|passed|failed|error:|BUILD|TEST)'
        UNIT_RESULT=${PIPESTATUS[0]}
    fi
fi

echo ""

INTEGRATION_RESULT=0

if [ "$WITH_INTEGRATION" = true ]; then
    echo -e "${YELLOW}=== Running integration networking tests (ConnectedModeSession) ===${NC}"
    echo ""

    # Reuse the existing sim-start/sim-stop scripts if available
    if ! nc -z localhost 8001 2>/dev/null || ! nc -z localhost 8002 2>/dev/null; then
        echo "Simulation not running. Starting..."
        "$SCRIPT_DIR/sim-start.sh"
        echo ""
    fi

    INTEGRATION_ARGS=()
    INTEGRATION_ARGS+=("-scheme" "AXTerm-Integration")
    INTEGRATION_ARGS+=("-destination" "platform=macOS")
    INTEGRATION_ARGS+=("-only-testing:AXTermIntegrationTests/ConnectedModeSessionTests")

    echo "  xcodebuild test ${INTEGRATION_ARGS[*]}"
    echo ""

    if [ "$VERBOSE" = true ]; then
        xcodebuild test "${INTEGRATION_ARGS[@]}" 2>&1
        INTEGRATION_RESULT=$?
    else
        if command -v xcpretty &> /dev/null; then
            xcodebuild test "${INTEGRATION_ARGS[@]}" 2>&1 | xcpretty
            INTEGRATION_RESULT=${PIPESTATUS[0]}
        else
            xcodebuild test "${INTEGRATION_ARGS[@]}" 2>&1 | grep -E '(Test Case|passed|failed|error:|BUILD|TEST)'
            INTEGRATION_RESULT=${PIPESTATUS[0]}
        fi
    fi

    echo ""
fi

if [ $UNIT_RESULT -eq 0 ] && [ $INTEGRATION_RESULT -eq 0 ]; then
    echo -e "${GREEN}=== All Network Tests Passed ===${NC}"
    exit 0
fi

echo -e "${RED}=== Network Tests Failed ===${NC}"
exit 1

