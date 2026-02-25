#!/bin/bash
set -e

# On macOS, delegate to the macOS-specific prerequisites script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(uname -s)" == "Darwin" ]]; then
    exec bash "$SCRIPT_DIR/install_prerequisites_macos.sh" "$@"
fi

# On Fedora, delegate to the Fedora-specific prerequisites script
if [ -f /etc/fedora-release ]; then
    exec bash "$SCRIPT_DIR/install_prerequisites_fedora.sh" "$@"
fi

GREEN='\033[0;32m'
NC='\033[0m' # No Color
SET_FS_PROTECTED_REGULAR=false
FS_PROTECTED_REGULAR_STATE_FILE="${FS_PROTECTED_REGULAR_STATE_FILE:-/tmp/openchami-fs-protected-regular.state}"

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --set-fs-protected-regular  Opt in to setting host fs.protected_regular=0
  -h, --help                  Show this help message
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --set-fs-protected-regular) SET_FS_PROTECTED_REGULAR=true ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            show_help >&2
            exit 1
            ;;
    esac
    shift
done

echo -e "${GREEN}=== Checking and Installing Prerequisites for Minikube 'none' Driver ===${NC}"

# Helper to check command existence
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 1. Update apt cache if we are going to install something
UPDATED_APT=false
ensure_apt_update() {
    if [ "$UPDATED_APT" = false ]; then
        echo "Updating apt cache..."
        sudo apt-get update
        UPDATED_APT=true
    fi
}

# 2. Install conntrack
if ! command_exists conntrack || ! command_exists socat; then
    echo -e "${GREEN}--> Installing conntrack and socat...${NC}"
    ensure_apt_update
    sudo apt-get install -y conntrack socat
else
    echo "conntrack and socat are installed."
fi

# 2b. Install Python dependencies (PyYAML)
if ! python3 -c "import yaml" >/dev/null 2>&1; then
    echo -e "${GREEN}--> Installing python3-yaml...${NC}"
    ensure_apt_update
    sudo apt-get install -y python3-yaml
else
    echo "python3-yaml is installed."
fi

# 2c. Install Go toolchain (required for local microservice builds)
if ! command_exists go; then
    echo -e "${GREEN}--> Installing golang-go...${NC}"
    ensure_apt_update
    sudo apt-get install -y golang-go
else
    echo "go is installed."
fi

# 3. Install cri-tools (crictl)
if ! command_exists crictl; then
    echo -e "${GREEN}--> Installing cri-tools...${NC}"
    
    # Check if package exists, if not, add Kubernetes repo
    ensure_apt_update
    if ! apt-cache show cri-tools >/dev/null 2>&1; then
        echo "Adding Kubernetes repository..."
        sudo apt-get install -y apt-transport-https ca-certificates curl gpg
        
        sudo mkdir -p -m 755 /etc/apt/keyrings
        # Using v1.34 to match the Kubernetes version seen in Minikube
        K8S_VER="v1.34"
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VER}/deb/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VER}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
        
        sudo apt-get update
        UPDATED_APT=true
    fi
    
    sudo apt-get install -y cri-tools
else
    echo "cri-tools is installed."
fi

# 4. Ensure Docker is running (Required for cri-dockerd)
echo -e "${GREEN}--> Ensuring Docker is running...${NC}"
if ! sudo systemctl is-active --quiet docker; then
    echo "Starting Docker..."
    sudo systemctl start docker
fi

# 5. Install cri-dockerd
if ! command_exists cri-dockerd; then
    echo -e "${GREEN}--> Installing cri-dockerd...${NC}"
    # Fetch latest release URL for Ubuntu Jammy (compatible with Noble)
    # Using the API to find the tag, then constructing the URL or finding the asset
    LATEST_URL=$(curl -s https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest | grep browser_download_url | grep "ubuntu-jammy_amd64.deb" | cut -d '"' -f 4)
    
    if [ -z "$LATEST_URL" ]; then
        echo "Error: Could not find cri-dockerd download URL."
        exit 1
    fi
    
    echo "Downloading from $LATEST_URL..."
    wget -O /tmp/cri-dockerd.deb "$LATEST_URL"
    
    echo "Installing package..."
    sudo dpkg -i /tmp/cri-dockerd.deb
    rm -f /tmp/cri-dockerd.deb
    
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

# 6. Install CNI Plugins
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

# 7. Install minikube
if ! command_exists minikube; then
    echo -e "${GREEN}--> Installing minikube...${NC}"
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    sudo install minikube-linux-amd64 /usr/local/bin/minikube
    rm -f minikube-linux-amd64
else
    echo "minikube is installed."
fi

# 8. Install helm
if ! command_exists helm; then
    echo -e "${GREEN}--> Installing helm...${NC}"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo "helm is installed."
fi

# 9. Optionally adjust fs.protected_regular for minikube none-driver compatibility
PROTECTED_REGULAR="$(sysctl -n fs.protected_regular 2>/dev/null || true)"
if [ "$SET_FS_PROTECTED_REGULAR" = true ]; then
    if [ -z "$PROTECTED_REGULAR" ]; then
        echo "Could not read fs.protected_regular; skipping requested update."
    elif [ "$PROTECTED_REGULAR" != "0" ]; then
        echo -e "${GREEN}--> Setting fs.protected_regular=0...${NC}"
        sudo sysctl -w fs.protected_regular=0
        if [ "$(sysctl -n fs.protected_regular 2>/dev/null || true)" = "0" ]; then
            printf '%s\n' "$PROTECTED_REGULAR" > "$FS_PROTECTED_REGULAR_STATE_FILE"
            echo "Saved previous fs.protected_regular=$PROTECTED_REGULAR to $FS_PROTECTED_REGULAR_STATE_FILE"
        else
            echo "Error: failed to set fs.protected_regular=0." >&2
            exit 1
        fi
    else
        echo "fs.protected_regular is already 0."
    fi
else
    if [ -z "$PROTECTED_REGULAR" ]; then
        echo "Could not read fs.protected_regular. Not modifying by default."
    else
        echo "fs.protected_regular is $PROTECTED_REGULAR. Not modifying fs.protected_regular by default."
        echo "If needed for minikube none-driver, re-run with --set-fs-protected-regular."
    fi
fi

echo -e "${GREEN}=== Prerequisites Check Complete ===${NC}"
