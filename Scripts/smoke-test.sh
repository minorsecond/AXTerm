#!/bin/bash
# AXTerm Smoke Tests
#
# Fast, hardware-free unit tests covering the critical protocol paths.
# Completes in ~60s. Safe to run at any time — no radio, no TNC, no simulators.
#
# Coverage domains:
#   - KISS encode / decode / escape handling
#   - AX.25 frame decode, encode, control field classification
#   - AX.25 session state machine (connect / disconnect / retry / T1 / T3)
#   - Connected-mode I/S/U frame handling
#   - AXDP capability negotiation and framing
#   - NET/ROM routing math (df, dr, ETX, quality score)
#   - Adaptive parameter tuning (RTT, RTO, AIMD)
#   - Packet persistence and ordering
#
# Usage:
#   Scripts/smoke-test.sh              # run smoke suite
#   Scripts/smoke-test.sh --verbose    # full xcodebuild output
#   Scripts/smoke-test.sh --list       # print suites without running
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

VERBOSE=false
LIST_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=true; shift ;;
        --list|-l)    LIST_ONLY=true; shift ;;
        -h|--help)
            sed -n '/^# /p' "$0" | head -20 | sed 's/^# //'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Smoke suite — curated fast, hardware-free test classes
# Excluded intentionally:
#   AX25SessionFuzzTests / AX25FuzzTests       — take minutes
#   KISSLinkBLETests                           — requires BLE hardware
#   AX25AdaptiveValidationTests                — uses real wall-clock timers
#   *IntegrationTests / *UITests               — require simulator / TNC
#   RealHardwareTNCTests / LiveDirewolfTests   — live hardware
# ---------------------------------------------------------------------------
SMOKE_SUITES=(
    # ---- KISS layer --------------------------------------------------------
    "AXTermTests/KISSTests"
    "AXTermTests/KISSEncodingTests"
    "AXTermTests/KISSLinkTests"

    # ---- AX.25 frame decode / encode ---------------------------------------
    "AXTermTests/AX25Tests"
    "AXTermTests/AX25FrameBuildingTests"
    "AXTermTests/AX25ControlFieldDecoderTests"
    "AXTermTests/PacketClassificationTests"
    "AXTermTests/PacketEncodingTests"

    # ---- Session state machine ---------------------------------------------
    "AXTermTests/AX25SessionTests"
    "AXTermTests/ConnectedModeTests"
    "AXTermTests/AX25RetryTests"
    "AXTermTests/AX25PollFinalTests"
    "AXTermTests/AX25SpecComplianceTests"
    "AXTermTests/AX25DuplicateTransmissionTests"
    "AXTermTests/IFrameReorderingTests"
    "AXTermTests/AX25SessionViaPathTests"
    "AXTermTests/PacketOrderingTests"
    "AXTermTests/PacketPersistenceControlFieldTests"

    # ---- AXDP --------------------------------------------------------------
    "AXTermTests/AXDPTests"
    "AXTermTests/AXDPCapabilityTests"
    "AXTermTests/AXDPCompatibilityTests"

    # ---- Routing math ------------------------------------------------------
    "AXTermTests/NetRomRoutingTests"
    "AXTermTests/NetRomLinkQualityTests"
    "AXTermTests/NetRomBroadcastParserTests"
    "AXTermTests/NetRomDecayTests"
    "AXTermTests/NetRomFreshnessTests"
    "AXTermTests/RouteHysteresisTests"
    "AXTermTests/PathSuggestionTests"

    # ---- Adaptive tuning ---------------------------------------------------
    "AXTermTests/AdaptiveTuningTests"
    "AXTermTests/AdaptiveSettingsTests"
    "AXTermTests/OutboundFrameTests"
    "AXTermTests/TransmissionEdgeCaseTests"
    "AXTermTests/TransmissionFragmentationTests"

    # ---- Core regression ---------------------------------------------------
    "AXTermTests/NonAXDPDataDeliveryTests"
    "AXTermTests/BackwardsCompatibilityTests"
    "AXTermTests/ConsoleLineGroupingTests"
    "AXTermTests/ConnectionValidationTests"
    "AXTermTests/AXDPCapabilityConfirmationTests"
    "AXTermTests/AXDPReassemblyBufferTests"
)

if $LIST_ONLY; then
    echo -e "${CYAN}Smoke test suites (${#SMOKE_SUITES[@]} classes):${NC}"
    for s in "${SMOKE_SUITES[@]}"; do
        echo "  $s"
    done
    exit 0
fi

echo -e "${BOLD}${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║       AXTerm Smoke Tests             ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "  Suites : ${#SMOKE_SUITES[@]} test classes"
echo -e "  Scope  : KISS · AX.25 · Session SM · AXDP · Routing · Adaptive"
echo -e "  Mode   : hardware-free, no timers, deterministic"
echo ""

cd "$PROJECT_ROOT"

# Build the -only-testing args
ONLY_ARGS=()
for suite in "${SMOKE_SUITES[@]}"; do
    ONLY_ARGS+=("-only-testing:$suite")
done

RESULT_BUNDLE="/tmp/AXTerm-Smoke-$(date +%Y%m%d-%H%M%S).xcresult"

XCODE_ARGS=(
    "test"
    "-scheme" "AXTerm"
    "-destination" "platform=macOS"
    "-resultBundlePath" "$RESULT_BUNDLE"
    "${ONLY_ARGS[@]}"
)

echo -e "${YELLOW}▶ Running...${NC}"
START=$(date +%s)

# Disable errexit around xcodebuild — we capture its exit code manually via PIPESTATUS
set +e

if $VERBOSE; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcodebuild "${XCODE_ARGS[@]}" 2>&1
    EXIT_CODE=$?
else
    # Compact output: show each test case pass/fail and final summary
    if command -v xcpretty &>/dev/null; then
        DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
            xcodebuild "${XCODE_ARGS[@]}" 2>&1 | xcpretty --color
        EXIT_CODE=${PIPESTATUS[0]}
    else
        # set +e already active; no || true needed — we capture xcodebuild's code via PIPESTATUS
        DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
            xcodebuild "${XCODE_ARGS[@]}" 2>&1 \
            | grep --line-buffered -E \
                'Test case|Test suite|passed \(|failed \(|error:|BUILD SUCCEEDED|BUILD FAILED|Executed [0-9]+ test'
        EXIT_CODE=${PIPESTATUS[0]}
    fi
fi

set -e

END=$(date +%s)
ELAPSED=$((END - START))

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Pull summary from xcresult if available
if [ -d "$RESULT_BUNDLE" ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" 2>/dev/null || true
    echo ""
    INSIGHTS=$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun xcresulttool get test-results insights --path "$RESULT_BUNDLE" 2>/dev/null || true)
    if [ -n "$INSIGHTS" ]; then
        echo -e "${RED}Failures / insights:${NC}"
        echo "$INSIGHTS"
        echo ""
    fi
fi

if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${BOLD}${GREEN}✅  SMOKE PASSED${NC}  (${ELAPSED}s)"
else
    echo -e "${BOLD}${RED}❌  SMOKE FAILED${NC}  (${ELAPSED}s)"
    echo ""
    echo -e "  Result bundle: ${RESULT_BUNDLE}"
    echo -e "  Full log:      xcodebuild … (rerun with --verbose)"
fi

echo ""
exit $EXIT_CODE
