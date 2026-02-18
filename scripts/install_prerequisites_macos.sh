#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Checking and Installing Prerequisites for macOS ===${NC}"

# Helper to check command existence
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 1. Check for Homebrew
if ! command_exists brew; then
    echo -e "${RED}Error: Homebrew is required but not installed.${NC}" >&2
    echo "Install it from https://brew.sh/" >&2
    exit 1
fi
echo "Homebrew is installed."

# 2. Check for Docker Desktop
if ! command_exists docker; then
    echo -e "${RED}Error: Docker is required but not installed.${NC}" >&2
    echo "Install Docker Desktop from https://www.docker.com/products/docker-desktop/" >&2
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}Error: Docker is installed but not running.${NC}" >&2
    echo "Please start Docker Desktop and try again." >&2
    exit 1
fi
echo "Docker Desktop is running."

# 3. Install gettext (provides envsubst)
if ! command_exists envsubst; then
    echo -e "${GREEN}--> Installing gettext (provides envsubst)...${NC}"
    brew install gettext
else
    echo "envsubst (gettext) is installed."
fi

# 4. Install Python3 and PyYAML
if ! command_exists python3; then
    echo -e "${GREEN}--> Installing python3...${NC}"
    brew install python3
else
    echo "python3 is installed."
fi

if ! python3 -c "import yaml" >/dev/null 2>&1; then
    echo -e "${GREEN}--> Installing PyYAML...${NC}"
    pip3 install PyYAML
else
    echo "PyYAML is installed."
fi

# 5. Install GNU grep (for -P/--perl-regexp support)
if ! command_exists ggrep; then
    echo -e "${GREEN}--> Installing GNU grep...${NC}"
    brew install grep
else
    echo "GNU grep (ggrep) is installed."
fi

# 6. Install minikube (optional, for minikube method)
if ! command_exists minikube; then
    echo -e "${GREEN}--> Installing minikube...${NC}"
    brew install minikube
else
    echo "minikube is installed."
fi

# 7. Install helm (optional, for minikube method)
if ! command_exists helm; then
    echo -e "${GREEN}--> Installing helm...${NC}"
    brew install helm
else
    echo "helm is installed."
fi

# 8. Install squashfs tools (provides mksquashfs)
if ! command_exists mksquashfs; then
    echo -e "${GREEN}--> Installing squashfs tools (mksquashfs)...${NC}"
    brew install squashfs
else
    echo "mksquashfs is installed."
fi

echo -e "${GREEN}=== macOS Prerequisites Check Complete ===${NC}"
