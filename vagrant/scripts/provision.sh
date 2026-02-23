#!/bin/bash
set -e

# provision.sh — Base VM provisioning for OpenCHAMI integration tests
# Runs once on `vagrant up --provision`. Installs basic dependencies;
# the deploy scripts themselves call install_prerequisites.sh for the rest.

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
    dnf install -y curl wget git make jq
    # Install Docker CE via official repo
    dnf -y install dnf-plugins-core
    dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo || true
    dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
elif [ "$DISTRO" = "ubuntu" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl wget git make jq
    # Install Docker via convenience script
    if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com | sh
    fi
    systemctl enable --now docker
fi

# Add vagrant user to docker group
usermod -aG docker vagrant || true

echo -e "${GREEN}=== Base provisioning complete ===${NC}"
