#!/usr/bin/env bash
# bootstrap.sh — First-time setup for ochami-from-scratch RPM deployment.
#
# Generates secrets, creates required directories, and prepares the system
# for starting the openchami.target.
#
# Usage: /usr/libexec/openchami/bootstrap.sh
#
# This script is idempotent — it will not overwrite an existing openchami.env.

set -euo pipefail

ENV_FILE="/etc/openchami/openchami.env"
ENV_TEMPLATE="/etc/openchami/configs/.env.template"
ARTIFACTS_DIR="/etc/openchami/artifacts"

log() { echo "[bootstrap] $*"; }

# --- 1. Create required directories ---
mkdir -p "$ARTIFACTS_DIR"
log "ensured $ARTIFACTS_DIR exists"

# --- 2. Generate secrets env file if missing ---
if [ -f "$ENV_FILE" ]; then
  log "$ENV_FILE already exists, skipping secret generation"
else
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

# --- 3. Reload systemd so quadlet units are visible ---
systemctl daemon-reload
log "systemd daemon reloaded"

log "bootstrap complete — start services with: systemctl start openchami.target"
