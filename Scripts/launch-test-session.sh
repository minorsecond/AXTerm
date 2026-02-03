#!/bin/bash
#
# AXTerm Test Session Launcher
#
# One-command launcher for running two AXTerm UI instances with monitoring.
# This is the main entry point for visual UI testing.
#
# Usage:
#   ./launch-test-session.sh          # Launch everything
#   ./launch-test-session.sh --stop   # Stop all test instances
#
# What it does:
#   1. Builds AXTerm (if needed)
#   2. Starts Docker KISS relay
#   3. Launches two AXTerm macOS app instances
#   4. Opens monitoring dashboard in a new terminal
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_DIR/Docker"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Cleanup function
cleanup_test_instances() {
    echo -e "${YELLOW}Stopping test instances...${NC}"
    pkill -f "AXTerm.*--test-mode" 2>/dev/null || true
    rm -f /tmp/axterm_test_*.pid
    echo -e "${GREEN}Done.${NC}"
}

# Handle --stop flag
if [ "$1" = "--stop" ] || [ "$1" = "stop" ]; then
    cleanup_test_instances
    exit 0
fi

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║               AXTerm Test Session Launcher                    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Step 1: Check Docker
echo -e "${YELLOW}[1/5] Checking Docker...${NC}"
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed${NC}"
    exit 1
fi
if ! docker info &> /dev/null; then
    echo -e "${RED}Error: Docker is not running${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Docker OK${NC}"

# Step 2: Start KISS relay
echo -e "${YELLOW}[2/5] Starting KISS relay...${NC}"
cd "$DOCKER_DIR"
docker compose down 2>/dev/null || true
docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null

# Wait for ports
for i in {1..30}; do
    if nc -z localhost 8001 2>/dev/null && nc -z localhost 8002 2>/dev/null; then
        echo -e "${GREEN}✓ KISS relay ready on ports 8001 and 8002${NC}"
        break
    fi
    sleep 0.5
done

if ! nc -z localhost 8001 2>/dev/null; then
    echo -e "${RED}Error: KISS relay failed to start${NC}"
    exit 1
fi

# Step 3: Find or build app
echo -e "${YELLOW}[3/5] Finding AXTerm.app...${NC}"

# Check common locations
APP_PATHS=(
    "$HOME/Library/Developer/Xcode/DerivedData/AXTerm-*/Build/Products/Debug/AXTerm.app"
    "$PROJECT_DIR/build/Build/Products/Debug/AXTerm.app"
    "/Applications/AXTerm.app"
)

APP_PATH=""
for pattern in "${APP_PATHS[@]}"; do
    for path in $pattern; do
        if [ -d "$path" ]; then
            APP_PATH="$path"
            break 2
        fi
    done
done

if [ -z "$APP_PATH" ]; then
    echo -e "${YELLOW}Building AXTerm...${NC}"
    cd "$PROJECT_DIR"
    xcodebuild -project AXTerm.xcodeproj -scheme AXTerm -configuration Debug build 2>&1 | grep -E "BUILD|error:|warning:" || true

    # Find the built app
    APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "AXTerm.app" -path "*/Debug/*" 2>/dev/null | head -1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}Error: Could not find AXTerm.app${NC}"
    exit 1
fi

APP_EXECUTABLE="$APP_PATH/Contents/MacOS/AXTerm"
echo -e "${GREEN}✓ Found: $APP_PATH${NC}"

# Step 4: Launch two instances
echo -e "${YELLOW}[4/5] Launching AXTerm instances...${NC}"

# Kill any existing test instances
pkill -f "AXTerm.*--test-mode" 2>/dev/null || true
sleep 1

# Launch Station A - explicitly use localhost to avoid connecting to real modems
echo -e "  ${CYAN}Starting Station A (TEST-1 on localhost:8001)...${NC}"
"$APP_EXECUTABLE" \
    --test-mode \
    --host localhost \
    --port 8001 \
    --callsign "TEST-1" \
    --instance-name "Station A" \
    --auto-connect &
echo $! > /tmp/axterm_test_a.pid
sleep 2

# Launch Station B - explicitly use localhost to avoid connecting to real modems
echo -e "  ${CYAN}Starting Station B (TEST-2 on localhost:8002)...${NC}"
"$APP_EXECUTABLE" \
    --test-mode \
    --host localhost \
    --port 8002 \
    --callsign "TEST-2" \
    --instance-name "Station B" \
    --auto-connect &
echo $! > /tmp/axterm_test_b.pid
sleep 2

echo -e "${GREEN}✓ Both AXTerm instances launched${NC}"

# Step 5: Open monitoring dashboard
echo -e "${YELLOW}[5/5] Opening monitoring dashboard...${NC}"

# Check for Python and rich
if ! python3 -c "import rich" 2>/dev/null; then
    echo -e "${YELLOW}Installing 'rich' library...${NC}"
    pip3 install rich --quiet
fi

# Open monitor in new terminal window
if [[ "$OSTYPE" == "darwin"* ]]; then
    osascript <<EOF
tell application "Terminal"
    activate
    do script "cd '$SCRIPT_DIR' && python3 kiss-monitor.py"
end tell
EOF
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}Test session is ready!${NC}"
echo ""
echo "  Two AXTerm windows should now be open:"
echo "    • Station A - TEST-1 (connected to localhost:8001)"
echo "    • Station B - TEST-2 (connected to localhost:8002)"
echo ""
echo "  Each instance uses an ephemeral database in /tmp/AXTerm-Test/"
echo "  (Your real database is NOT affected)"
echo ""
echo "  A monitoring terminal will show traffic between stations."
echo ""
echo "  To stop the test session:"
echo "    $0 --stop"
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
