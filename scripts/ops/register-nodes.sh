#!/usr/bin/env bash
# register-nodes.sh — Register nodes with SMD and BSS via curl.
# Usage: ./register-nodes.sh --nodes-csv NODES_CSV [--dry-run]
#
# CSV format: xname,mac,ip,bmc_ip
# Example:    x1000c0s0b0n0,02:00:00:00:00:01,192.168.100.101,10.0.0.101

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

NODES_CSV=""
parse_common_args "$@"

# Parse --nodes-csv argument
for arg in "$@"; do
  case "$arg" in
    --nodes-csv=*) NODES_CSV="${arg#--nodes-csv=}" ;;
  esac
done
# Also handle --nodes-csv VALUE form
prev=""
for arg in "$@"; do
  if [ "$prev" = "--nodes-csv" ]; then
    NODES_CSV="$arg"
  fi
  prev="$arg"
done

HOST="${HOST_IP:-localhost}"
HTTP_PORT="${HTTP_PORT:-80}"
BASE_URL="http://${HOST}:${HTTP_PORT}"

if [ -z "$NODES_CSV" ]; then
  log_error "usage: $0 --nodes-csv FILE [--dry-run]"
  exit 1
fi

if [ ! -f "$NODES_CSV" ]; then
  log_error "nodes CSV file not found: $NODES_CSV"
  exit 1
fi

log_info "registering nodes from $NODES_CSV"

failed=0
while IFS=',' read -r xname mac ip bmc_ip; do
  # Skip header and empty lines
  [ -z "$xname" ] && continue
  [[ "$xname" =~ ^# ]] && continue
  [[ "$xname" == "xname" ]] && continue

  log_info "registering $xname (mac=$mac, ip=$ip, bmc=$bmc_ip)"

  # Register node in SMD EthernetInterfaces
  run_cmd curl -sf -X POST "${BASE_URL}/hsm/v2/Inventory/EthernetInterfaces" \
    -H 'Content-Type: application/json' \
    -d "{
      \"ComponentID\": \"$xname\",
      \"Description\": \"Ethernet Interface\",
      \"MACAddress\": \"$mac\",
      \"IPAddresses\": [{\"IPAddress\": \"$ip\"}]
    }" || { log_warn "failed to register $xname ethernet interface"; failed=$((failed + 1)); continue; }

  # Register node component in SMD State/Components
  run_cmd curl -sf -X POST "${BASE_URL}/hsm/v2/State/Components" \
    -H 'Content-Type: application/json' \
    -d "{
      \"Components\": [{
        \"ID\": \"$xname\",
        \"State\": \"Ready\",
        \"NetType\": \"Sling\",
        \"Arch\": \"X86\",
        \"Role\": \"Compute\"
      }]
    }" || { log_warn "failed to register $xname component"; failed=$((failed + 1)); continue; }

  # Register BMC RedfishEndpoint if bmc_ip is provided
  if [ -n "$bmc_ip" ] && [ "$bmc_ip" != "-" ]; then
    bmc_xname="${xname%n*}"  # Strip node suffix to get BMC xname
    run_cmd curl -sf -X POST "${BASE_URL}/hsm/v2/Inventory/RedfishEndpoints" \
      -H 'Content-Type: application/json' \
      -d "{
        \"ID\": \"$bmc_xname\",
        \"FQDN\": \"$bmc_ip\",
        \"RediscoverOnUpdate\": false,
        \"User\": \"admin\",
        \"Password\": \"password\"
      }" || log_warn "failed to register BMC for $xname"
  fi

  log_info "registered $xname"
done < "$NODES_CSV"

if [ "$failed" -gt 0 ]; then
  log_error "$failed node(s) failed registration"
  exit 1
fi

log_info "node registration complete"
