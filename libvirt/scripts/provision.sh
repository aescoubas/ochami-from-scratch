#!/bin/bash
set -euo pipefail

# provision.sh — Base VM provisioning for OpenCHAMI integration tests
# Runs inside a libvirt cloud-image VM before invoking run_tests.sh.

GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}=== OpenCHAMI Test VM Provisioning ===${NC}"

# Detect distro
if [ -f /etc/fedora-release ]; then
    DISTRO="fedora"
elif [ -f /etc/lsb-release ] || grep -qi ubuntu /etc/os-release 2>/dev/null; then
    DISTRO="ubuntu"
else
    DISTRO="unknown"
fi
echo "Detected distro: $DISTRO"

# Install base tools
if [ "$DISTRO" = "fedora" ]; then
    sudo dnf install -y curl wget git make jq rsync
    # Install Docker CE via official repo
    sudo dnf -y install dnf-plugins-core
    sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo || true
    sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo systemctl enable --now docker
elif [ "$DISTRO" = "ubuntu" ]; then
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update
    sudo apt-get install -y curl wget git make jq rsync
    # Install Docker via convenience script
    if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com | sudo sh
    fi
    sudo systemctl enable --now docker
fi

# Add cloud user to docker group
CLOUD_USER="${SUDO_USER:-$(id -un)}"
if id "$CLOUD_USER" >/dev/null 2>&1; then
    sudo usermod -aG docker "$CLOUD_USER" || true
fi

echo -e "${GREEN}=== Base provisioning complete ===${NC}"
