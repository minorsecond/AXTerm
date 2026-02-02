#!/bin/bash
# AXTerm Simulation Stop Script
# Stops the Docker-based KISS relay

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_ROOT/Docker"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Stopping AXTerm Simulation ===${NC}"

cd "$DOCKER_DIR"

if docker ps --format '{{.Names}}' | grep -q "axterm-kiss-relay"; then
    echo "Stopping KISS relay..."
    docker-compose down
    echo -e "${GREEN}Simulation stopped${NC}"
else
    echo -e "${YELLOW}Simulation was not running${NC}"
fi
