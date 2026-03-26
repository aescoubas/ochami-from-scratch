#!/usr/bin/env bash
# build-boot-artifacts.sh — Download PXE boot artifacts (kernel + initrd) for
# test node booting, replacing the former nix/boot-artifacts.nix builder.
#
# Usage:
#   ./build-boot-artifacts.sh [--force] [--dry-run]
#
# Environment:
#   TEST_NODE_IMAGE / OPENCHAMI_TEST_NODE_IMAGE  distro to fetch (default: almalinux)
#   BOOT_ARTIFACTS_DIR                           output directory (default: .tmp/boot-artifacts)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

FORCE="false"

for arg in "$@"; do
  case "$arg" in
    --force) FORCE="true" ;;
  esac
done

parse_common_args "$@"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TEST_NODE_IMAGE="${TEST_NODE_IMAGE:-almalinux}"
TEST_NODE_IMAGE="${OPENCHAMI_TEST_NODE_IMAGE:-$TEST_NODE_IMAGE}"

BOOT_ARTIFACTS_DIR="${BOOT_ARTIFACTS_DIR:-${PROJECT_ROOT}/.tmp/boot-artifacts}"
SUPPORTED_IMAGES=("almalinux" "ubuntu" "opensuse")

# ---------------------------------------------------------------------------
# Per-distro catalog
# ---------------------------------------------------------------------------

declare -A IMAGE_LABEL
declare -A IMAGE_RELATIVE_DIR
declare -A IMAGE_KERNEL_FILE
declare -A IMAGE_INITRD_FILE
declare -A IMAGE_KERNEL_ARGS
declare -A IMAGE_CONSOLE_READY_PATTERN

# --- AlmaLinux 9.7 ---
IMAGE_LABEL[almalinux]="AlmaLinux 9.7 PXE installer"
IMAGE_RELATIVE_DIR[almalinux]="artifacts/almalinux"
IMAGE_KERNEL_FILE[almalinux]="vmlinuz"
IMAGE_INITRD_FILE[almalinux]="initrd.img"
IMAGE_KERNEL_ARGS[almalinux]="ip=dhcp inst.repo=https://repo.almalinux.org/almalinux/9.7/BaseOS/x86_64/os/ inst.text console=ttyS0,115200n8 console=tty0"
IMAGE_CONSOLE_READY_PATTERN[almalinux]="AlmaLinux|anaconda|installation program|login:"

ALMALINUX_KERNEL_URL="https://repo.almalinux.org/almalinux/9.7/BaseOS/x86_64/os/images/pxeboot/vmlinuz"
ALMALINUX_INITRD_URL="https://repo.almalinux.org/almalinux/9.7/BaseOS/x86_64/os/images/pxeboot/initrd.img"

# --- openSUSE Leap 15.6 ---
IMAGE_LABEL[opensuse]="openSUSE Leap 15.6 installer"
IMAGE_RELATIVE_DIR[opensuse]="artifacts/opensuse"
IMAGE_KERNEL_FILE[opensuse]="linux"
IMAGE_INITRD_FILE[opensuse]="initrd"
IMAGE_KERNEL_ARGS[opensuse]="install=https://download.opensuse.org/distribution/leap/15.6/repo/oss/ ifcfg=dhcp textmode=1 console=ttyS0,115200 console=tty0"
IMAGE_CONSOLE_READY_PATTERN[opensuse]="openSUSE|linuxrc|YaST|login:"

OPENSUSE_KERNEL_URL="https://download.opensuse.org/distribution/leap/15.6/repo/oss/boot/x86_64/loader/linux"
OPENSUSE_INITRD_URL="https://download.opensuse.org/distribution/leap/15.6/repo/oss/boot/x86_64/loader/initrd"

# --- Ubuntu 24.04 ---
IMAGE_LABEL[ubuntu]="Ubuntu Server 24.04.4 netboot installer"
IMAGE_RELATIVE_DIR[ubuntu]="artifacts/ubuntu"
IMAGE_KERNEL_FILE[ubuntu]="linux"
IMAGE_INITRD_FILE[ubuntu]="initrd"
IMAGE_KERNEL_ARGS[ubuntu]="root=/dev/ram0 ramdisk_size=1500000 ip=dhcp iso-url=https://releases.ubuntu.com/noble/ubuntu-24.04.4-live-server-amd64.iso console=ttyS0,115200n8 console=tty0 ---"
IMAGE_CONSOLE_READY_PATTERN[ubuntu]="Ubuntu Server|Subiquity|ubuntu login:|login:"

UBUNTU_NETBOOT_URL="https://releases.ubuntu.com/noble/ubuntu-24.04.4-netboot-amd64.tar.gz"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_supported_image() {
  local img="$1"
  local supported
  for supported in "${SUPPORTED_IMAGES[@]}"; do
    if [ "$img" = "$supported" ]; then
      return 0
    fi
  done
  return 1
}

download_file() {
  local url="$1"
  local dest="$2"

  if [ "$FORCE" != "true" ] && [ -f "$dest" ]; then
    log_info "cached: $dest (use --force to re-download)"
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would download $url -> $dest"
    return 0
  fi

  local dest_dir
  dest_dir="$(dirname "$dest")"
  mkdir -p "$dest_dir"

  local tmp_dest="${dest}.part"
  log_info "downloading $url"
  if ! curl -fL --progress-bar -o "$tmp_dest" "$url"; then
    rm -f "$tmp_dest"
    log_error "failed to download $url"
    return 1
  fi
  mv "$tmp_dest" "$dest"
  log_info "saved: $dest"
}

write_metadata() {
  local image="$1"
  local output_dir="$2"
  local metadata_file="${output_dir}/metadata.json"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would write metadata to $metadata_file"
    return 0
  fi

  require_command jq "metadata generation" || {
    # Fallback: write metadata without jq using printf
    log_warn "jq not found; writing metadata manually"
    cat > "$metadata_file" <<EOF
{
  "selected": {
    "id": "${image}",
    "label": "${IMAGE_LABEL[$image]}",
    "relativeDir": "${IMAGE_RELATIVE_DIR[$image]}",
    "kernelFile": "${IMAGE_KERNEL_FILE[$image]}",
    "initrdFile": "${IMAGE_INITRD_FILE[$image]}",
    "kernelArgs": "${IMAGE_KERNEL_ARGS[$image]}",
    "consoleReadyPattern": "${IMAGE_CONSOLE_READY_PATTERN[$image]}"
  },
  "supported": ["almalinux", "ubuntu", "opensuse"]
}
EOF
    return 0
  }

  jq -n \
    --arg id "$image" \
    --arg label "${IMAGE_LABEL[$image]}" \
    --arg relativeDir "${IMAGE_RELATIVE_DIR[$image]}" \
    --arg kernelFile "${IMAGE_KERNEL_FILE[$image]}" \
    --arg initrdFile "${IMAGE_INITRD_FILE[$image]}" \
    --arg kernelArgs "${IMAGE_KERNEL_ARGS[$image]}" \
    --arg consoleReadyPattern "${IMAGE_CONSOLE_READY_PATTERN[$image]}" \
    '{
      selected: {
        id: $id,
        label: $label,
        relativeDir: $relativeDir,
        kernelFile: $kernelFile,
        initrdFile: $initrdFile,
        kernelArgs: $kernelArgs,
        consoleReadyPattern: $consoleReadyPattern
      },
      supported: ["almalinux", "ubuntu", "opensuse"]
    }' > "$metadata_file"

  log_info "metadata written: $metadata_file"
}

write_kernel_params() {
  local image="$1"
  local artifact_dir="$2"
  local params_file="${artifact_dir}/kernel-params"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would write kernel-params to $params_file"
    return 0
  fi

  printf '%s\n' "${IMAGE_KERNEL_ARGS[$image]}" > "$params_file"
  log_info "kernel-params written: $params_file"
}

# ---------------------------------------------------------------------------
# Per-distro fetch functions
# ---------------------------------------------------------------------------

fetch_almalinux() {
  local artifact_dir="${BOOT_ARTIFACTS_DIR}/${IMAGE_RELATIVE_DIR[almalinux]}"
  mkdir -p "$artifact_dir"

  download_file "$ALMALINUX_KERNEL_URL" "${artifact_dir}/${IMAGE_KERNEL_FILE[almalinux]}"
  download_file "$ALMALINUX_INITRD_URL" "${artifact_dir}/${IMAGE_INITRD_FILE[almalinux]}"
}

fetch_opensuse() {
  local artifact_dir="${BOOT_ARTIFACTS_DIR}/${IMAGE_RELATIVE_DIR[opensuse]}"
  mkdir -p "$artifact_dir"

  download_file "$OPENSUSE_KERNEL_URL" "${artifact_dir}/${IMAGE_KERNEL_FILE[opensuse]}"
  download_file "$OPENSUSE_INITRD_URL" "${artifact_dir}/${IMAGE_INITRD_FILE[opensuse]}"
}

fetch_ubuntu() {
  local artifact_dir="${BOOT_ARTIFACTS_DIR}/${IMAGE_RELATIVE_DIR[ubuntu]}"
  local tarball_path="${BOOT_ARTIFACTS_DIR}/.cache/ubuntu-netboot.tar.gz"
  local kernel_dest="${artifact_dir}/${IMAGE_KERNEL_FILE[ubuntu]}"
  local initrd_dest="${artifact_dir}/${IMAGE_INITRD_FILE[ubuntu]}"
  mkdir -p "$artifact_dir"

  # If both final files exist and --force was not given, skip everything
  if [ "$FORCE" != "true" ] && [ -f "$kernel_dest" ] && [ -f "$initrd_dest" ]; then
    log_info "cached: $kernel_dest (use --force to re-download)"
    log_info "cached: $initrd_dest (use --force to re-download)"
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would download and extract $UBUNTU_NETBOOT_URL"
    return 0
  fi

  # Download the tarball
  mkdir -p "${BOOT_ARTIFACTS_DIR}/.cache"
  download_file "$UBUNTU_NETBOOT_URL" "$tarball_path"

  # Extract kernel and initrd
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  log_info "extracting ubuntu netboot tarball"
  tar -xzf "$tarball_path" -C "$workdir"

  if [ ! -f "$workdir/amd64/linux" ] || [ ! -f "$workdir/amd64/initrd" ]; then
    log_error "expected files amd64/linux and amd64/initrd not found in tarball"
    return 1
  fi

  cp "$workdir/amd64/linux" "$kernel_dest"
  cp "$workdir/amd64/initrd" "$initrd_dest"
  log_info "extracted: $kernel_dest"
  log_info "extracted: $initrd_dest"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log_info "build-boot-artifacts: image=$TEST_NODE_IMAGE"

  if ! is_supported_image "$TEST_NODE_IMAGE"; then
    log_error "unsupported test node image '$TEST_NODE_IMAGE' (expected one of: ${SUPPORTED_IMAGES[*]})"
    exit 1
  fi

  require_command curl "downloading boot artifacts"

  case "$TEST_NODE_IMAGE" in
    almalinux) fetch_almalinux ;;
    opensuse)  fetch_opensuse  ;;
    ubuntu)    fetch_ubuntu    ;;
  esac

  local artifact_dir="${BOOT_ARTIFACTS_DIR}/${IMAGE_RELATIVE_DIR[$TEST_NODE_IMAGE]}"
  write_kernel_params "$TEST_NODE_IMAGE" "$artifact_dir"
  write_metadata "$TEST_NODE_IMAGE" "$BOOT_ARTIFACTS_DIR"

  log_info "boot artifacts ready: $BOOT_ARTIFACTS_DIR"
  log_info "  kernel: ${artifact_dir}/${IMAGE_KERNEL_FILE[$TEST_NODE_IMAGE]}"
  log_info "  initrd: ${artifact_dir}/${IMAGE_INITRD_FILE[$TEST_NODE_IMAGE]}"
}

main
