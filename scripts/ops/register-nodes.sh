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

SMD_HOST="${SMD_HOST:-localhost}"
SMD_PORT="${SMD_PORT:-27779}"
SMD_BASE_URL="https://${SMD_HOST}:${SMD_PORT}"

if [ -z "$NODES_CSV" ]; then
  log_error "usage: $0 --nodes-csv FILE [--dry-run]"
  exit 1
fi

if [ ! -f "$NODES_CSV" ]; then
  log_error "nodes CSV file not found: $NODES_CSV"
  exit 1
fi

log_info "registering nodes from $NODES_CSV"

ethernet_interface_exists() {
  local xname="$1"
  local mac="$2"
  local ip="$3"
  local response

  response="$(curl -skfG "${SMD_BASE_URL}/hsm/v2/Inventory/EthernetInterfaces" \
    --data-urlencode "ComponentID=${xname}" 2>/dev/null || true)"
 
  [ -n "$response" ] || return 1

  printf '%s' "$response" | jq -e \
    --arg xname "$xname" \
    --arg mac "$mac" \
    --arg ip "$ip" \
    'map(select(.ComponentID == $xname and .MACAddress == $mac and ((.IPAddresses // []) | any(.IPAddress == $ip)))) | length > 0' \
    >/dev/null
}

component_exists() {
  local xname="$1"
  curl -skf "${SMD_BASE_URL}/hsm/v2/State/Components/${xname}" >/dev/null 2>&1
}

redfish_endpoint_exists() {
  local xname="$1"
  curl -skf "${SMD_BASE_URL}/hsm/v2/Inventory/RedfishEndpoints/${xname}" >/dev/null 2>&1
}

ensure_ethernet_interface() {
  local xname="$1"
  local mac="$2"
  local ip="$3"

  if [ "$DRY_RUN" != "true" ] && ethernet_interface_exists "$xname" "$mac" "$ip"; then
    log_info "ethernet interface for $xname already registered"
    return 0
  fi

  run_cmd curl -skf -X POST "${SMD_BASE_URL}/hsm/v2/Inventory/EthernetInterfaces" \
    -H 'Content-Type: application/json' \
    -d "{
      \"ComponentID\": \"$xname\",
      \"Description\": \"Ethernet Interface\",
      \"MACAddress\": \"$mac\",
      \"IPAddresses\": [{\"IPAddress\": \"$ip\"}]
    }" || {
      if [ "$DRY_RUN" != "true" ] && ethernet_interface_exists "$xname" "$mac" "$ip"; then
        log_info "ethernet interface for $xname already present after retry"
        return 0
      fi
      log_warn "failed to register $xname ethernet interface"
      return 1
    }
}

ensure_component() {
  local xname="$1"

  if [ "$DRY_RUN" != "true" ] && component_exists "$xname"; then
    log_info "component $xname already registered"
    return 0
  fi

  run_cmd curl -skf -X POST "${SMD_BASE_URL}/hsm/v2/State/Components" \
    -H 'Content-Type: application/json' \
    -d "{
      \"Components\": [{
        \"ID\": \"$xname\",
        \"State\": \"Ready\",
        \"NetType\": \"Sling\",
        \"Arch\": \"X86\",
        \"Role\": \"Compute\"
      }]
    }" || {
      if [ "$DRY_RUN" != "true" ] && component_exists "$xname"; then
        log_info "component $xname already present after retry"
        return 0
      fi
      log_warn "failed to register $xname component"
      return 1
    }
}

ensure_redfish_endpoint() {
  local bmc_xname="$1"
  local bmc_ip="$2"

  if [ "$DRY_RUN" != "true" ] && redfish_endpoint_exists "$bmc_xname"; then
    log_info "BMC endpoint $bmc_xname already registered"
    return 0
  fi

  run_cmd curl -skf -X POST "${SMD_BASE_URL}/hsm/v2/Inventory/RedfishEndpoints" \
    -H 'Content-Type: application/json' \
    -d "{
      \"ID\": \"$bmc_xname\",
      \"FQDN\": \"$bmc_ip\",
      \"RediscoverOnUpdate\": false,
      \"User\": \"admin\",
      \"Password\": \"password\"
    }" || {
      if [ "$DRY_RUN" != "true" ] && redfish_endpoint_exists "$bmc_xname"; then
        log_info "BMC endpoint $bmc_xname already present after retry"
        return 0
      fi
      log_warn "failed to register BMC endpoint $bmc_xname"
      return 1
    }
}

failed=0
while IFS=',' read -r xname mac ip bmc_ip; do
  # Skip header and empty lines
  [ -z "$xname" ] && continue
  [[ "$xname" =~ ^# ]] && continue
  [[ "$xname" == "xname" ]] && continue

  log_info "registering $xname (mac=$mac, ip=$ip, bmc=$bmc_ip)"

  # Register node in SMD EthernetInterfaces
  ensure_ethernet_interface "$xname" "$mac" "$ip" \
    || { failed=$((failed + 1)); continue; }

  # Register node component in SMD State/Components
  ensure_component "$xname" \
    || { failed=$((failed + 1)); continue; }

  # Register BMC RedfishEndpoint if bmc_ip is provided
  if [ -n "$bmc_ip" ] && [ "$bmc_ip" != "-" ]; then
    bmc_xname="${xname%n*}"  # Strip node suffix to get BMC xname
    ensure_redfish_endpoint "$bmc_xname" "$bmc_ip" \
      || log_warn "failed to register BMC for $xname"
  fi

  log_info "registered $xname"
done < "$NODES_CSV"

if [ "$failed" -gt 0 ]; then
  log_error "$failed node(s) failed registration"
  exit 1
fi

log_info "node registration complete"
