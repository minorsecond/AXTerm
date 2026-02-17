#!/bin/bash
#
# run_rf_tests.sh — Run AXTerm RF integration tests
#
# These tests transmit on amateur radio frequencies using real hardware.
# They require operator supervision and a valid amateur radio license.
#
# Usage:
#   ./run_rf_tests.sh              # Run all RF tests
#   ./run_rf_tests.sh tnc4         # Run only TNC4 hardware tests
#   ./run_rf_tests.sh direwolf     # Run only dual-radio Direwolf tests
#   ./run_rf_tests.sh bpq          # Run only BPQ command tests
#   ./run_rf_tests.sh <TestName>   # Run a specific test by name
#

set -euo pipefail

SCHEME="AXTerm"
DESTINATION="platform=macOS"
SENTINEL="/tmp/axterm_rf_tests_enabled"

# Clean up sentinel on exit (normal or error)
cleanup() {
    rm -f "$SENTINEL"
}
trap cleanup EXIT

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  AXTerm RF Integration Tests${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}WARNING: These tests transmit on amateur radio frequencies.${NC}"
echo -e "${YELLOW}A valid amateur radio license is required.${NC}"
echo ""
echo -e "${CYAN}Before proceeding, please verify:${NC}"
echo ""
echo "  1. Mobilinkd TNC4 is connected via USB-C"
echo "  2. Radio is powered on and tuned to a clear simplex frequency"
echo "     (e.g., 145.050 MHz or another quiet frequency in your area)"
echo "  3. K0EPI-7 (ham-pi LinBPQ) is running and reachable on-air"
echo "  4. ham-pi Direwolf is accessible at 192.168.3.218:8001"
echo "     (for dual-radio cross-verification tests)"
echo "  5. You have monitored the frequency and confirmed it is not in use"
echo "     by other stations for critical traffic"
echo ""

# Check for TNC4
TNC_DEVICE=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1 || true)
if [ -n "$TNC_DEVICE" ]; then
    echo -e "  ${GREEN}✓ TNC4 detected: ${TNC_DEVICE}${NC}"
else
    echo -e "  ${RED}✗ No TNC4 detected (/dev/cu.usbmodem* not found)${NC}"
    echo -e "  ${RED}  Connect the TNC4 via USB-C and try again.${NC}"
    exit 1
fi

# Check for Direwolf
if nc -z -w2 192.168.3.218 8001 2>/dev/null; then
    echo -e "  ${GREEN}✓ Direwolf reachable at 192.168.3.218:8001${NC}"
else
    echo -e "  ${YELLOW}⚠ Direwolf not reachable at 192.168.3.218:8001${NC}"
    echo -e "  ${YELLOW}  Dual-radio tests will be skipped.${NC}"
fi

echo ""
read -p "Ready to transmit? (y/N) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# Create sentinel file to enable RF tests
touch "$SENTINEL"

# Determine which tests to run
case "${1:-all}" in
    tnc4)
        echo -e "${CYAN}Running TNC4 hardware tests...${NC}"
        TEST_FILTER=(
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testKISSLinkSerialOpensDirectly'
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testTNC4SerialLinkOpens'
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testTNC4ReceivesAfterManualReset'
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testTNC4ReceivesPackets'
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testConnectToK0EPI7'
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testSendAndReceiveData'
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testMobilinkdBatteryTelemetry'
        )
        ;;
    direwolf|dw)
        echo -e "${CYAN}Running dual-radio Direwolf tests...${NC}"
        TEST_FILTER=(
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testDirewolfTCPConnects'
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testDirewolfSeesOurSABM'
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testTNC4ReceivesFrameFromDirewolf'
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testDualStackSessionWithMonitor'
        )
        ;;
    bpq)
        echo -e "${CYAN}Running BPQ command tests...${NC}"
        TEST_FILTER=(
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testBPQNodesCommand'
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testBPQInfoCommand'
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testBPQPortsCommand'
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testBPQMheardCommand'
            -only-testing:'AXTermTests/TNC4LiveConnectionTests/testBPQUsersCommand'
        )
        ;;
    all)
        echo -e "${CYAN}Running all RF integration tests...${NC}"
        TEST_FILTER=(
            -only-testing:'AXTermTests/TNC4LiveConnectionTests'
            -only-testing:'AXTermTests/RealHardwareTNCTests'
        )
        ;;
    *)
        # Assume it's a specific test name
        echo -e "${CYAN}Running test: ${1}...${NC}"
        TEST_FILTER=(
            -only-testing:"AXTermTests/TNC4LiveConnectionTests/${1}"
        )
        ;;
esac

echo ""

# Run the tests
xcodebuild test \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    "${TEST_FILTER[@]}" \
    2>&1 | grep -E 'Test (Case|Suite)|passed|failed|skipped|Executed|error:|assert' || true

# Sentinel is cleaned up by the trap
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  RF Tests Complete${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
