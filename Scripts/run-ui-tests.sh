#!/bin/bash
#
# AXTerm UI Integration Test Runner
#
# This script launches two actual AXTerm macOS application instances
# connected through a KISS relay, plus a monitoring terminal showing
# real-time diagnostics and frame traffic.
#
# Usage:
#   ./run-ui-tests.sh [--clean-rebuild|clean_rebuild] [mode]
#
# Modes:
#   manual      - Launch apps for manual testing (default)
#   automated   - Run automated XCUITest suite
#   monitor     - Launch monitoring dashboard only (apps already running)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_DIR/Docker"

# Dedicated, sandboxed build root for UI tests only.
# This keeps all test builds and ephemeral data completely separate from any
# build products you use during normal development.
BUILD_DIR="$PROJECT_DIR/.ui-test-build"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

CLEAN_REBUILD=0
MODE="manual"

for arg in "$@"; do
    case "$arg" in
        --clean-rebuild|clean_rebuild|clean_build)
            CLEAN_REBUILD=1
            ;;
        manual|automated|monitor|build|stop|help|-h|--help)
            MODE="$arg"
            ;;
    esac
done

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║          AXTerm UI Integration Test Runner                    ║"
    echo "║                                                               ║"
    echo "║   Launches two AXTerm instances with live monitoring          ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_dependencies() {
    echo -e "${YELLOW}Checking dependencies...${NC}"

    # Check Docker
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Error: Docker is not installed${NC}"
        exit 1
    fi

    if ! docker info &> /dev/null; then
        echo -e "${RED}Error: Docker daemon is not running${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Docker OK${NC}"

    # Check Python
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}Error: Python 3 is required${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Python OK${NC}"

    # Check rich library
    if ! python3 -c "import rich" 2>/dev/null; then
        echo -e "${YELLOW}Installing 'rich' library...${NC}"
        pip3 install rich --quiet
    fi
    echo -e "${GREEN}✓ Rich library OK${NC}"
}

build_app() {
    echo -e "${YELLOW}Building AXTerm...${NC}"

    if [ "$CLEAN_REBUILD" -eq 1 ]; then
        echo -e "${YELLOW}Cleaning build artifacts...${NC}"
        rm -rf "$BUILD_DIR"
    fi

    # Check if we need to build
    APP_PATH="$BUILD_DIR/Build/Products/Debug/AXTerm.app"
    EXEC_PATH="$APP_PATH/Contents/MacOS/AXTerm"
    if [ -d "$APP_PATH" ] && [ -x "$EXEC_PATH" ]; then
        echo -e "${GREEN}✓ AXTerm.app found at $APP_PATH${NC}"
        return 0
    fi

    # Build the app
    cd "$PROJECT_DIR"
    mkdir -p "$BUILD_DIR"

    xcodebuild \
        -project AXTerm.xcodeproj \
        -scheme AXTerm \
        -configuration Debug \
        -derivedDataPath "$BUILD_DIR" \
        build 2>&1 | while read line; do
            if [[ "$line" == *"error:"* ]]; then
                echo -e "${RED}$line${NC}"
            elif [[ "$line" == *"warning:"* ]]; then
                echo -e "${YELLOW}$line${NC}"
            elif [[ "$line" == *"BUILD SUCCEEDED"* ]]; then
                echo -e "${GREEN}$line${NC}"
            fi
        done

    if [ ! -d "$APP_PATH" ] || [ ! -x "$EXEC_PATH" ]; then
        echo -e "${RED}Error: Build failed - AXTerm.app executable not found at:${NC}"
        echo "  $EXEC_PATH"
        exit 1
    fi

    echo -e "${GREEN}✓ Build complete${NC}"
}

start_kiss_relay() {
    echo -e "${YELLOW}Starting KISS relay...${NC}"

    # Check if already running
    if nc -z localhost 8001 2>/dev/null && nc -z localhost 8002 2>/dev/null; then
        echo -e "${GREEN}✓ KISS relay already running on ports 8001 and 8002${NC}"
        return 0
    fi

    # Stop any existing containers
    cd "$DOCKER_DIR"
    docker compose down 2>/dev/null || true

    # Start the dual-port relay (or simulator)
    docker compose --profile simulator up -d 2>/dev/null || docker-compose --profile simulator up -d 2>/dev/null

    # Wait for relay
    echo -n "Waiting for relay"
    for i in {1..30}; do
        if nc -z localhost 8001 2>/dev/null && nc -z localhost 8002 2>/dev/null; then
            echo -e "\n${GREEN}✓ Relay ready on ports 8001 and 8002${NC}"
            return 0
        fi
        echo -n "."
        sleep 1
    done

    echo -e "\n${RED}Error: Relay failed to start${NC}"
    exit 1
}

launch_axterm_instances() {
    echo -e "${YELLOW}Launching AXTerm instances...${NC}"

    # Allow overriding the executable path so developers can point at an
    # already-installed AXTerm.app (e.g. from Xcode's DerivedData).
    if [ -n "$AXTERM_EXECUTABLE" ]; then
        APP_PATH="$AXTERM_EXECUTABLE"
    else
        APP_PATH="$BUILD_DIR/Build/Products/Debug/AXTerm.app/Contents/MacOS/AXTerm"
    fi

    if [ ! -x "$APP_PATH" ]; then
        echo -e "${RED}Error: AXTerm executable not found or not executable at:$NC"
        echo "  $APP_PATH"
        echo ""
        echo "You can point this script at a known-good build by setting:"
        echo "  AXTERM_EXECUTABLE=\"/path/to/AXTerm.app/Contents/MacOS/AXTerm\" ./run-ui-tests.sh"
        exit 1
    fi

    # Kill any existing instances
    pkill -f "AXTerm.*--test-mode" 2>/dev/null || true
    sleep 1

    # Launch Station A (port 8001) - use localhost to avoid connecting to real modems
    echo -e "${CYAN}Launching Station A on localhost:8001...${NC}"
    "$APP_PATH" \
        --test-mode \
        --host localhost \
        --port 8001 \
        --callsign "TEST-1" \
        --instance-name "Station A" \
        --auto-connect &
    PID_A=$!
    echo -e "${GREEN}✓ Station A launched (PID: $PID_A)${NC}"

    sleep 2

    # Launch Station B (port 8002) - use localhost to avoid connecting to real modems
    echo -e "${CYAN}Launching Station B on localhost:8002...${NC}"
    "$APP_PATH" \
        --test-mode \
        --host localhost \
        --port 8002 \
        --callsign "TEST-2" \
        --instance-name "Station B" \
        --auto-connect &
    PID_B=$!
    echo -e "${GREEN}✓ Station B launched (PID: $PID_B)${NC}"

    # Save PIDs for cleanup
    echo "$PID_A" > /tmp/axterm_test_pid_a
    echo "$PID_B" > /tmp/axterm_test_pid_b

    sleep 2
}

launch_monitor() {
    echo -e "${YELLOW}Launching monitoring dashboard...${NC}"
    python3 "$SCRIPT_DIR/kiss-monitor.py"
}

run_automated_tests() {
    echo -e "${YELLOW}Running automated UI tests...${NC}"

    cd "$PROJECT_DIR"

    AXTERM_DUAL_INSTANCE_TESTS=1 xcodebuild \
        -project AXTerm.xcodeproj \
        -scheme AXTermUITests \
        -destination 'platform=macOS' \
        -derivedDataPath "$BUILD_DIR" \
        test 2>&1 | while read line; do
            if [[ "$line" == *"Test Case"* ]] && [[ "$line" == *"passed"* ]]; then
                echo -e "${GREEN}$line${NC}"
            elif [[ "$line" == *"Test Case"* ]] && [[ "$line" == *"failed"* ]]; then
                echo -e "${RED}$line${NC}"
            elif [[ "$line" == *"error:"* ]]; then
                echo -e "${RED}$line${NC}"
            fi
        done
}

cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"

    # Kill AXTerm instances
    if [ -f /tmp/axterm_test_pid_a ]; then
        kill $(cat /tmp/axterm_test_pid_a) 2>/dev/null || true
        rm -f /tmp/axterm_test_pid_a
    fi
    if [ -f /tmp/axterm_test_pid_b ]; then
        kill $(cat /tmp/axterm_test_pid_b) 2>/dev/null || true
        rm -f /tmp/axterm_test_pid_b
    fi

    pkill -f "AXTerm.*--test-mode" 2>/dev/null || true

    echo -e "${GREEN}✓ Cleanup complete${NC}"
}

show_usage() {
    echo "Usage: $0 [--clean-rebuild|clean_rebuild|clean_build] [mode]"
    echo ""
    echo "Options:"
    echo "  --clean-rebuild, clean_rebuild  - Remove build artifacts before building"
    echo ""
    echo "Modes:"
    echo "  manual      - Launch apps for manual testing (default)"
    echo "  automated   - Run automated XCUITest suite"
    echo "  monitor     - Launch monitoring dashboard only"
    echo "  build       - Build AXTerm only"
    echo "  stop        - Stop all test instances"
    echo ""
}

# Trap cleanup
trap cleanup EXIT

# Main
print_banner

case "$MODE" in
    manual)
        check_dependencies
        build_app
        start_kiss_relay
        launch_axterm_instances
        echo ""
        echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}Two AXTerm instances are now running!${NC}"
        echo ""
        echo "  Station A: Connected to port 8001 (callsign: TEST-1)"
        echo "  Station B: Connected to port 8002 (callsign: TEST-2)"
        echo ""
        echo "You can now use both apps to send messages between stations."
        echo ""
        echo -e "${CYAN}Press Enter to launch the monitoring dashboard...${NC}"
        read
        launch_monitor
        ;;

    automated)
        check_dependencies
        build_app
        start_kiss_relay
        launch_axterm_instances
        sleep 3
        run_automated_tests
        ;;

    monitor)
        check_dependencies
        launch_monitor
        ;;

    build)
        build_app
        ;;

    stop)
        cleanup
        ;;

    help|-h|--help)
        show_usage
        ;;

    *)
        echo -e "${RED}Unknown mode: $MODE${NC}"
        show_usage
        exit 1
        ;;
esac
