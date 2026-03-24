#!/usr/bin/env bash
# deactivate — Stop OpenCHAMI quadlet services.
#
# This script is installed by the RPM/DEB package at /usr/libexec/openchami/deactivate.
# It is intentionally Nix-free: no store paths, only standard system tools.

set -euo pipefail

systemctl stop openchami.target 2>/dev/null || true
systemctl daemon-reload

echo "OpenCHAMI deactivated."
