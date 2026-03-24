#!/usr/bin/env bash
# activate — Render config templates and start OpenCHAMI quadlet services.
#
# This script is installed by the RPM/DEB package at /usr/libexec/openchami/activate.
# It is intentionally Nix-free: no store paths, only standard system tools.

set -euo pipefail

SECRETS="${OPENCHAMI_SECRETS:-/etc/openchami/openchami.env}"
CONFIG_TEMPLATES="/etc/openchami/configs.templates"
CONFIG_DIR="/etc/openchami/configs"
PG_INIT_SRC="/etc/openchami/pg-init.templates"
PG_INIT_DIR="/etc/openchami/pg-init"
ARTIFACTS_DIR="/etc/openchami/artifacts"

if [ ! -f "$SECRETS" ]; then
  echo "ERROR: secrets file not found: $SECRETS"
  echo "Create it from: /etc/openchami/openchami.env.template"
  exit 1
fi

# Source secrets and build envsubst variable list.
# shellcheck disable=SC1090
. "$SECRETS"
envsubst_keys="$(cut -d= -f1 "$SECRETS" | grep -v '^#' | grep -v '^$')"
export $envsubst_keys
envsubst_vars="$(echo "$envsubst_keys" | sed 's/^/$/; s/$/ /' | tr -d '\n')"

# Render config templates with secret substitution.
mkdir -p "$CONFIG_DIR"
if [ -d "$CONFIG_TEMPLATES" ]; then
  for f in "$CONFIG_TEMPLATES"/*; do
    [ -f "$f" ] || continue
    envsubst "$envsubst_vars" < "$f" > "${CONFIG_DIR}/$(basename "$f")"
  done
fi

# Copy support files (pg-init scripts, etc.)
if [ -d "$PG_INIT_SRC" ]; then
  mkdir -p "$PG_INIT_DIR"
  cp -r "$PG_INIT_SRC"/* "$PG_INIT_DIR"/
fi

# Ensure artifacts directory exists (boot artifacts are placed here separately).
mkdir -p "$ARTIFACTS_DIR"

# Trigger podman quadlet generator and start services.
systemctl daemon-reload
systemctl start openchami.target

echo "OpenCHAMI activated."
