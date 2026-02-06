#!/bin/bash
# AXTerm Simulation Start Script
# Starts the Docker-based KISS relay for testing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_ROOT/Docker"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== AXTerm KISS Relay Simulation ===${NC}"

# Check for Docker
echo "Checking prerequisites..."

if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed${NC}"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo -e "${RED}Error: Docker is not running. Please start Docker Desktop.${NC}"
    exit 1
fi

# Check if already running
if docker ps --format '{{.Names}}' | grep -q "axterm-kiss-relay"; then
    echo -e "${YELLOW}KISS relay is already running${NC}"
else
    echo "Starting KISS relay..."
    cd "$DOCKER_DIR"
    docker-compose up -d --build
fi

# Wait for ports to be ready
echo "Waiting for ports to be ready..."
MAX_WAIT=30
WAITED=0

while [ $WAITED -lt $MAX_WAIT ]; do
    if nc -z localhost 8001 2>/dev/null && nc -z localhost 8002 2>/dev/null; then
        echo -e "${GREEN}Both KISS ports are accessible${NC}"
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
    echo "  Waiting... ($WAITED/$MAX_WAIT seconds)"
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo -e "${RED}Error: Timeout waiting for KISS ports${NC}"
    echo "Check Docker logs: docker logs axterm-kiss-relay"
    exit 1
fi

echo ""
echo -e "${GREEN}=== Simulation Ready ===${NC}"
echo ""
echo "KISS TCP Ports (connect from AXTerm or tests):"
echo "  Station A: localhost:8001"
echo "  Station B: localhost:8002"
echo ""
echo "Frames sent to one port will be relayed to the other."
echo ""
echo "View relay logs:"
echo "  docker logs -f axterm-kiss-relay"
echo ""
echo "Stop simulation:"
echo "  $SCRIPT_DIR/sim-stop.sh"
