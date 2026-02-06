#!/bin/bash
#
# AXTerm Visual Integration Test Runner
#
# This script:
# 1. Ensures Docker relay is running
# 2. Installs dependencies if needed
# 3. Runs the visual test harness
#
# Usage:
#   ./run-visual-tests.sh [basic|axdp|connected|stress|all]
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
NC='\033[0m' # No Color

MODE="${1:-basic}"

# Show usage
show_usage() {
    echo "Usage: $0 [mode]"
    echo ""
    echo "Modes:"
    echo "  basic       - Basic UI frame tests (default)"
    echo "  axdp        - AXDP protocol tests"
    echo "  connected   - Connected mode (SABM/UA) tests"
    echo "  stress      - Performance/stress tests"
    echo "  all         - Run all test modes"
    echo "  interactive - Interactive console (type your own messages)"
    echo ""
}

echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║        AXTerm Visual Integration Test Runner               ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check for Python
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: Python 3 is required${NC}"
    exit 1
fi

# Check/install rich library
echo -e "${YELLOW}Checking dependencies...${NC}"
if ! python3 -c "import rich" 2>/dev/null; then
    echo -e "${YELLOW}Installing 'rich' library...${NC}"
    pip3 install rich --quiet
fi
echo -e "${GREEN}✓ Dependencies OK${NC}"

# Check Docker
echo -e "${YELLOW}Checking Docker...${NC}"
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed${NC}"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo -e "${RED}Error: Docker daemon is not running${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Docker OK${NC}"

# Start Docker relay if needed
echo -e "${YELLOW}Checking KISS relay...${NC}"
if ! nc -z localhost 8001 2>/dev/null; then
    echo -e "${YELLOW}Starting Docker KISS relay...${NC}"
    cd "$DOCKER_DIR"
    docker compose up -d kiss-relay 2>/dev/null || docker-compose up -d kiss-relay 2>/dev/null

    # Wait for relay to be ready
    echo -n "Waiting for relay"
    for i in {1..30}; do
        if nc -z localhost 8001 2>/dev/null; then
            echo -e "\n${GREEN}✓ Relay ready${NC}"
            break
        fi
        echo -n "."
        sleep 1
    done

    if ! nc -z localhost 8001 2>/dev/null; then
        echo -e "\n${RED}Error: Relay failed to start${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✓ Relay already running${NC}"
fi

echo ""

# Run the visual tests
if [ "$MODE" = "all" ]; then
    echo -e "${CYAN}Running all test modes...${NC}"
    echo ""

    for m in basic axdp connected stress; do
        echo -e "${CYAN}═══ Running $m tests ═══${NC}"
        python3 "$SCRIPT_DIR/visual-test.py" --mode "$m"
        echo ""
        sleep 1
    done
elif [ "$MODE" = "interactive" ]; then
    echo -e "${CYAN}Starting interactive console...${NC}"
    echo -e "${YELLOW}Type messages to send between stations. Use /help for commands.${NC}"
    echo ""
    python3 "$SCRIPT_DIR/interactive-test.py"
elif [ "$MODE" = "help" ] || [ "$MODE" = "-h" ] || [ "$MODE" = "--help" ]; then
    show_usage
    exit 0
else
    echo -e "${CYAN}Running $MODE tests...${NC}"
    echo ""
    python3 "$SCRIPT_DIR/visual-test.py" --mode "$MODE"
fi

echo ""
echo -e "${GREEN}Done!${NC}"
