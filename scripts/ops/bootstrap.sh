#!/usr/bin/env bash
# bootstrap.sh — First-time setup for ochami-from-scratch RPM deployment.
#
# Detects host network settings, generates secrets, renders config templates,
# downloads iPXE firmware, and prepares the system for starting openchami.target.
#
# Usage: /usr/libexec/openchami/bootstrap.sh
#
# This script is idempotent — it will not overwrite an existing openchami.env.

set -euo pipefail

ENV_FILE="/etc/openchami/openchami.env"
ENV_TEMPLATE="/etc/openchami/configs/.env.template"
CONFIGS_DIR="/etc/openchami/configs"
ARTIFACTS_DIR="/etc/openchami/artifacts"
TFTPBOOT_DIR="/etc/openchami/tftpboot"
RUSTFS_DATA_DIR="${ARTIFACTS_DIR}/rustfs-data"
RUSTFS_LOG_DIR="${ARTIFACTS_DIR}/rustfs-logs"

log() { echo "[bootstrap] $*"; }

ensure_env_var() {
  local name="$1"
  local value="$2"

  if ! grep -q "^${name}=" "$ENV_FILE" 2>/dev/null; then
    echo "${name}=${value}" >> "$ENV_FILE"
    log "added ${name} to $ENV_FILE"
  fi
}

set_env_var() {
  local name="$1"
  local value="$2"

  if grep -q "^${name}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${name}=.*|${name}=${value}|" "$ENV_FILE"
  else
    echo "${name}=${value}" >> "$ENV_FILE"
  fi
}

# --- 1. Create required directories ---
mkdir -p "$ARTIFACTS_DIR" "$TFTPBOOT_DIR" "$RUSTFS_DATA_DIR" "$RUSTFS_LOG_DIR"
chown 10001:10001 "$RUSTFS_DATA_DIR" "$RUSTFS_LOG_DIR" 2>/dev/null || true
log "ensured $ARTIFACTS_DIR, $TFTPBOOT_DIR, $RUSTFS_DATA_DIR, and $RUSTFS_LOG_DIR exist"

# --- 2. Generate secrets env file if missing ---
CREATED_ENV_FILE=false
if [ -f "$ENV_FILE" ]; then
  log "$ENV_FILE already exists, skipping secret generation"
else
  CREATED_ENV_FILE=true
  log "generating secrets in $ENV_FILE"
  PASS="$(openssl rand -hex 16)"

  # Start with the template vars (POSTGRES_PASSWORD, SMD_DB_PASSWORD, etc.)
  if [ -f "$ENV_TEMPLATE" ]; then
    sed "s/=$/=${PASS}/" "$ENV_TEMPLATE" > "$ENV_FILE"
  else
    cat > "$ENV_FILE" <<EOF
POSTGRES_PASSWORD=${PASS}
SMD_DB_PASSWORD=${PASS}
BSS_DB_PASSWORD=${PASS}
KEA_DB_PASSWORD=${PASS}
PCS_DB_PASSWORD=${PASS}
STORK_DB_PASSWORD=${PASS}
EOF
  fi

  # Append derived vars expected by quadlet env mappings
  cat >> "$ENV_FILE" <<EOF
SMD_DBPASS=${PASS}
BSS_DBPASS=${PASS}
KEA_DBPASS=${PASS}
PCS_DBPASS=${PASS}
EOF

  chmod 600 "$ENV_FILE"
  log "secrets written to $ENV_FILE"
fi

PASS="$(awk -F= '/^POSTGRES_PASSWORD=/{print $2; exit}' "$ENV_FILE" 2>/dev/null || true)"
if [ -z "$PASS" ]; then
  PASS="$(openssl rand -hex 16)"
fi

for var in POSTGRES_PASSWORD SMD_DB_PASSWORD BSS_DB_PASSWORD KEA_DB_PASSWORD PCS_DB_PASSWORD STORK_DB_PASSWORD; do
  ensure_env_var "$var" "$PASS"
done

for var in SMD_DBPASS BSS_DBPASS KEA_DBPASS PCS_DBPASS; do
  ensure_env_var "$var" "$PASS"
done

if [ "$CREATED_ENV_FILE" = "true" ]; then
  set_env_var RUSTFS_ACCESS_KEY "$(openssl rand -hex 16)"
  set_env_var RUSTFS_SECRET_KEY "$(openssl rand -hex 16)"
  log "generated dedicated RustFS credentials in $ENV_FILE"
else
  ensure_env_var RUSTFS_ACCESS_KEY "$(openssl rand -hex 16)"
  ensure_env_var RUSTFS_SECRET_KEY "$(openssl rand -hex 16)"
fi

chmod 600 "$ENV_FILE"

# --- 3. Detect and persist network settings ---
# OPENCHAMI_BASE_IP: the host's primary IP (used by all services)
if ! grep -q '^OPENCHAMI_BASE_IP=' "$ENV_FILE" 2>/dev/null; then
  BASE_IP="$(hostname -I | awk '{print $1}')"
  if [ -n "$BASE_IP" ]; then
    echo "OPENCHAMI_BASE_IP=${BASE_IP}" >> "$ENV_FILE"
    log "set OPENCHAMI_BASE_IP=$BASE_IP"
  else
    log "WARNING: could not determine host IP, OPENCHAMI_BASE_IP not set"
  fi
fi

# Derive network settings from the interface that holds OPENCHAMI_BASE_IP
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

if [ -n "${OPENCHAMI_BASE_IP:-}" ]; then
  # Find the interface and CIDR for this IP
  IFACE_LINE=$(ip -o -4 addr show | grep " ${OPENCHAMI_BASE_IP}/" | head -1)
  if [ -n "$IFACE_LINE" ]; then
    CIDR=$(echo "$IFACE_LINE" | awk '{print $4}')       # e.g. 148.187.1.36/27
    PREFIX=${CIDR#*/}                                     # e.g. 27

    # Derive gateway from default route
    GATEWAY=$(ip route show default | awk '{print $3}' | head -1)

    # Derive subnet in CIDR notation using python (available on RHEL)
    SUBNET=$(python3 -c "
import ipaddress
net = ipaddress.ip_network('${CIDR}', strict=False)
print(net)
")

    # Derive a sensible DHCP pool: prefer base_ip+4 to base_ip+14,
    # but clamp it to the subnet's usable host range so smaller subnets
    # (for example /28 controller networks) still render a valid Kea config.
    POOL_RANGE=$(python3 -c "
import ipaddress

ip = ipaddress.ip_address('${OPENCHAMI_BASE_IP}')
net = ipaddress.ip_network('${CIDR}', strict=False)

if net.num_addresses > 2:
    first_usable = net.network_address + 1
    last_usable = net.broadcast_address - 1
else:
    first_usable = net.network_address
    last_usable = net.broadcast_address

desired_start = ip + 4
desired_end = ip + 14

pool_start = min(max(desired_start, first_usable), last_usable)
pool_end = min(max(desired_end, pool_start), last_usable)

print(f'{pool_start} {pool_end}')
")
    POOL_START="${POOL_RANGE%% *}"
    POOL_END="${POOL_RANGE##* }"

    # Persist network vars if not already set
    for var in OPENCHAMI_GATEWAY OPENCHAMI_SUBNET OPENCHAMI_POOL_START OPENCHAMI_POOL_END; do
      if ! grep -q "^${var}=" "$ENV_FILE" 2>/dev/null; then
        case "$var" in
          OPENCHAMI_GATEWAY)    val="$GATEWAY" ;;
          OPENCHAMI_SUBNET)     val="$SUBNET" ;;
          OPENCHAMI_POOL_START) val="$POOL_START" ;;
          OPENCHAMI_POOL_END)   val="$POOL_END" ;;
        esac
        echo "${var}=${val}" >> "$ENV_FILE"
        log "set ${var}=${val}"
      fi
    done
  else
    log "WARNING: could not find interface for $OPENCHAMI_BASE_IP"
  fi
fi

# --- 4. Render config templates with secrets and network vars ---
# Reload env file (now includes network vars)
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

ENVSUBST_VARS='$KEA_DB_PASSWORD $POSTGRES_PASSWORD $SMD_DB_PASSWORD $BSS_DB_PASSWORD $PCS_DB_PASSWORD $STORK_DB_PASSWORD $SMD_DBPASS $BSS_DBPASS $KEA_DBPASS $PCS_DBPASS $OPENCHAMI_BASE_IP $OPENCHAMI_GATEWAY $OPENCHAMI_SUBNET $OPENCHAMI_POOL_START $OPENCHAMI_POOL_END'

TEMPLATE_PATTERN='\$\{?KEA_DB_PASSWORD|\$\{?POSTGRES_PASSWORD|\$\{?SMD_DB_PASSWORD|\$\{?BSS_DB_PASSWORD|\$\{?PCS_DB_PASSWORD|\$\{?SMD_DBPASS|\$\{?BSS_DBPASS|\$\{?KEA_DBPASS|\$\{?PCS_DBPASS|\$\{?OPENCHAMI_BASE_IP|\$\{?OPENCHAMI_GATEWAY|\$\{?OPENCHAMI_SUBNET|\$\{?OPENCHAMI_POOL_START|\$\{?OPENCHAMI_POOL_END'

# Render config files (kea, boot.ipxe, etc.)
if [ -d "$CONFIGS_DIR" ]; then
  for conf in "$CONFIGS_DIR"/*.conf "$CONFIGS_DIR"/*.ipxe; do
    [ -f "$conf" ] || continue
    if grep -qE "$TEMPLATE_PATTERN" "$conf" 2>/dev/null; then
      envsubst "$ENVSUBST_VARS" < "$conf" > "$conf.rendered"
      mv "$conf.rendered" "$conf"
      log "rendered $(basename "$conf")"
    fi
  done
fi

# Render quadlet container files (BSS uses OPENCHAMI_BASE_IP in Environment= lines)
QUADLET_DIR="/etc/containers/systemd"
if [ -d "$QUADLET_DIR" ]; then
  for container in "$QUADLET_DIR"/*.container; do
    [ -f "$container" ] || continue
    if grep -qE "$TEMPLATE_PATTERN" "$container" 2>/dev/null; then
      envsubst "$ENVSUBST_VARS" < "$container" > "$container.rendered"
      mv "$container.rendered" "$container"
      log "rendered $(basename "$container")"
    fi
  done
fi

# --- 5. Download iPXE firmware if missing ---
if [ ! -f "$TFTPBOOT_DIR/undionly.kpxe" ] || [ ! -f "$TFTPBOOT_DIR/ipxe.efi" ]; then
  log "downloading iPXE firmware..."
  IPXE_BASE="http://boot.ipxe.org"
  if curl -sfL -o "$TFTPBOOT_DIR/undionly.kpxe" "$IPXE_BASE/undionly.kpxe"; then
    log "  downloaded undionly.kpxe (BIOS)"
  else
    log "WARNING: failed to download undionly.kpxe"
  fi
  if curl -sfL -o "$TFTPBOOT_DIR/ipxe.efi" "$IPXE_BASE/x86_64-efi/ipxe.efi"; then
    log "  downloaded ipxe.efi (UEFI x86_64)"
  else
    log "WARNING: failed to download ipxe.efi"
  fi
else
  log "iPXE firmware already present in $TFTPBOOT_DIR"
fi

# --- 6. Install ochami CLI config if missing ---
CLI_CONFIG="/etc/ochami/config.yaml"
CLI_CONFIG_TEMPLATE="/etc/openchami/configs/ochami-cli.yaml"
if [ -f "$CLI_CONFIG" ]; then
  log "$CLI_CONFIG already exists, skipping CLI config install"
elif [ -f "$CLI_CONFIG_TEMPLATE" ]; then
  mkdir -p "$(dirname "$CLI_CONFIG")"
  cp "$CLI_CONFIG_TEMPLATE" "$CLI_CONFIG"
  log "installed ochami CLI config to $CLI_CONFIG"
else
  log "CLI config template not found at $CLI_CONFIG_TEMPLATE, skipping"
fi

# --- 7. Reload systemd so quadlet units are visible ---
systemctl daemon-reload
log "systemd daemon reloaded"

log "bootstrap complete — start services with: systemctl start openchami.target"
