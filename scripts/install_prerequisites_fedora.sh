#!/bin/bash
set -e

GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Checking and Installing Prerequisites for Fedora ===${NC}"

# Helper to check command existence
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 1. Install conntrack and socat
if ! command_exists conntrack || ! command_exists socat; then
    echo -e "${GREEN}--> Installing conntrack-tools and socat...${NC}"
    sudo dnf install -y conntrack-tools socat
else
    echo "conntrack and socat are installed."
fi

# 2. Install Python dependencies (PyYAML)
if ! python3 -c "import yaml" >/dev/null 2>&1; then
    echo -e "${GREEN}--> Installing python3-pyyaml...${NC}"
    sudo dnf install -y python3-pyyaml
else
    echo "python3-pyyaml is installed."
fi

# 2b. Install Go toolchain (required for local microservice builds)
if ! command_exists go; then
    echo -e "${GREEN}--> Installing golang...${NC}"
    sudo dnf install -y golang
else
    echo "go is installed."
fi

# 3. Install Docker CE
if ! command_exists docker; then
    echo -e "${GREEN}--> Installing Docker CE...${NC}"
    sudo dnf -y install dnf-plugins-core
    sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
    sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo systemctl enable --now docker
else
    echo "Docker is installed."
fi

# Ensure Docker is running
echo -e "${GREEN}--> Ensuring Docker is running...${NC}"
if ! sudo systemctl is-active --quiet docker; then
    echo "Starting Docker..."
    sudo systemctl start docker
fi

# 4. Install Podman
if ! command_exists podman; then
    echo -e "${GREEN}--> Installing Podman...${NC}"
    sudo dnf install -y podman
else
    echo "Podman is installed."
fi

# 5. Install cri-tools (crictl)
if ! command_exists crictl; then
    echo -e "${GREEN}--> Installing cri-tools...${NC}"

    # Try from kubernetes RPM repo first
    if ! rpm -q cri-tools >/dev/null 2>&1; then
        echo "Adding Kubernetes repository..."
        K8S_VER="v1.34"
        cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_VER}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_VER}/rpm/repodata/repomd.xml.key
EOF
        sudo dnf install -y cri-tools
    fi
else
    echo "cri-tools is installed."
fi

# 6. Install cri-dockerd
if ! command_exists cri-dockerd; then
    echo -e "${GREEN}--> Installing cri-dockerd...${NC}"
    LATEST_URL=$(curl -s https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest | grep browser_download_url | grep "\.fc.*\.x86_64\.rpm" | head -n1 | cut -d '"' -f 4)

    # Fallback to el9 RPM if no Fedora-specific RPM found
    if [ -z "$LATEST_URL" ]; then
        LATEST_URL=$(curl -s https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest | grep browser_download_url | grep "\.el9\.x86_64\.rpm" | head -n1 | cut -d '"' -f 4)
    fi

    if [ -z "$LATEST_URL" ]; then
        echo "Error: Could not find cri-dockerd RPM download URL."
        exit 1
    fi

    echo "Downloading from $LATEST_URL..."
    wget -O /tmp/cri-dockerd.rpm "$LATEST_URL"

    echo "Installing package..."
    sudo rpm -i /tmp/cri-dockerd.rpm || sudo dnf install -y /tmp/cri-dockerd.rpm
    rm -f /tmp/cri-dockerd.rpm

    echo "Enabling cri-docker.socket..."
    sudo systemctl enable --now cri-docker.socket
else
    echo "cri-dockerd is installed."
    # Ensure socket is active
    if ! sudo systemctl is-active --quiet cri-docker.socket; then
        echo "Starting cri-docker.socket..."
        sudo systemctl start cri-docker.socket
    fi
fi

# 7. Install CNI Plugins
CNI_BIN_DIR="/opt/cni/bin"
if [ ! -d "$CNI_BIN_DIR" ] || [ -z "$(ls -A $CNI_BIN_DIR)" ]; then
    echo -e "${GREEN}--> Installing CNI Plugins...${NC}"
    CNI_VERSION="v1.9.0"
    CNI_URL="https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz"

    echo "Downloading CNI plugins..."
    wget -O /tmp/cni-plugins.tgz "$CNI_URL"

    echo "Extracting to $CNI_BIN_DIR..."
    sudo mkdir -p "$CNI_BIN_DIR"
    sudo tar -xzvf /tmp/cni-plugins.tgz -C "$CNI_BIN_DIR"
    rm -f /tmp/cni-plugins.tgz
else
    echo "CNI plugins seem to be installed in $CNI_BIN_DIR."
fi

# 8. Install minikube
if ! command_exists minikube; then
    echo -e "${GREEN}--> Installing minikube...${NC}"
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    sudo install minikube-linux-amd64 /usr/local/bin/minikube
    rm -f minikube-linux-amd64
else
    echo "minikube is installed."
fi

# 9. Install helm
if ! command_exists helm; then
    echo -e "${GREEN}--> Installing helm...${NC}"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo "helm is installed."
fi

# 10. Install gettext (provides envsubst)
if ! command_exists envsubst; then
    echo -e "${GREEN}--> Installing gettext (provides envsubst)...${NC}"
    sudo dnf install -y gettext
else
    echo "envsubst (gettext) is installed."
fi

# 11. Fix fs.protected_regular (Fixes "boot lock: unable to open /tmp/juju-..." error)
PROTECTED_REGULAR=$(sysctl -n fs.protected_regular)
if [ "$PROTECTED_REGULAR" != "0" ]; then
    echo -e "${GREEN}--> Setting fs.protected_regular=0...${NC}"
    sudo sysctl -w fs.protected_regular=0
else
    echo "fs.protected_regular is already 0."
fi

echo -e "${GREEN}=== Fedora Prerequisites Check Complete ===${NC}"
