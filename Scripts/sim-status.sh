#!/bin/bash
# AXTerm Simulation Status Script
# Shows status of KISS relay and port connectivity

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_ROOT/Docker"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== AXTerm Simulation Status ==="
echo ""

# Check Docker
echo "Docker:"
if command -v docker &> /dev/null; then
    if docker info &> /dev/null; then
        echo -e "  ${GREEN}Running${NC}"
    else
        echo -e "  ${RED}Not running (start Docker Desktop)${NC}"
    fi
else
    echo -e "  ${RED}Not installed${NC}"
fi

# Check relay container
echo ""
echo "KISS Relay Container:"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "axterm-kiss-relay"; then
    echo -e "  ${GREEN}Running${NC}"
    docker ps --format "  Image: {{.Image}}\n  Status: {{.Status}}" --filter "name=axterm-kiss-relay"
else
    echo -e "  ${YELLOW}Not running${NC}"
fi

# Check port connectivity
echo ""
echo "KISS Port Connectivity:"

check_port() {
    local port=$1
    local name=$2
    if nc -z -w 2 localhost $port 2>/dev/null; then
        echo -e "  $name (localhost:$port): ${GREEN}Accessible${NC}"
        return 0
    else
        echo -e "  $name (localhost:$port): ${RED}Not accessible${NC}"
        return 1
    fi
}

check_port 8001 "Station A"
check_port 8002 "Station B"

echo ""
echo "=== End Status ==="
