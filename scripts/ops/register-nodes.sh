#!/usr/bin/env bash
# register-nodes.sh — Register a node with SMD (component, ethernet interface, BMC).
#
# Usage:
#   ./register-nodes.sh --xname x1000c0s0b0n0 --mac 02:00:00:00:00:01 --ip 192.168.100.101 \
#       [--bmc-ip 10.0.0.101] [--bmc-xname x1000c0s0b0] [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

parse_common_args "$@"

XNAME=""
MAC=""
IP=""
BMC_IP=""
BMC_XNAME=""

for arg in "$@"; do
  case "$arg" in
    --xname=*)     XNAME="${arg#--xname=}" ;;
    --mac=*)       MAC="${arg#--mac=}" ;;
    --ip=*)        IP="${arg#--ip=}" ;;
    --bmc-ip=*)    BMC_IP="${arg#--bmc-ip=}" ;;
    --bmc-xname=*) BMC_XNAME="${arg#--bmc-xname=}" ;;
  esac
done
prev=""
for arg in "$@"; do
  case "$prev" in
    --xname)     XNAME="$arg" ;;
    --mac)       MAC="$arg" ;;
    --ip)        IP="$arg" ;;
    --bmc-ip)    BMC_IP="$arg" ;;
    --bmc-xname) BMC_XNAME="$arg" ;;
  esac
  prev="$arg"
done

SMD_HOST="${SMD_HOST:-localhost}"
SMD_PORT="${SMD_PORT:-27779}"
SMD_BASE_URL="https://${SMD_HOST}:${SMD_PORT}"
REDFISH_BMC_USER="${REDFISH_BMC_USER:-admin}"
REDFISH_BMC_PASSWORD="${REDFISH_BMC_PASSWORD:-password}"

if [ -z "$XNAME" ] || [ -z "$MAC" ] || [ -z "$IP" ]; then
  log_error "usage: $0 --xname XNAME --mac MAC --ip IP [--bmc-ip BMC_IP] [--bmc-xname BMC_XNAME] [--dry-run]"
  exit 1
fi

# Derive BMC xname from node xname if not provided (strip trailing nN)
if [ -z "$BMC_XNAME" ]; then
  BMC_XNAME="${XNAME%n*}"
fi

# ---------------------------------------------------------------------------
# SMD helpers
# ---------------------------------------------------------------------------

ethernet_interface_exists() {
  local xname="$1" mac="$2" ip="$3"
  local response
  response="$(curl -skfG "${SMD_BASE_URL}/hsm/v2/Inventory/EthernetInterfaces" \
    --data-urlencode "ComponentID=${xname}" 2>/dev/null || true)"
  [ -n "$response" ] || return 1
  printf '%s' "$response" | jq -e \
    --arg xname "$xname" --arg mac "$mac" --arg ip "$ip" \
    'map(select(.ComponentID == $xname and .MACAddress == $mac and ((.IPAddresses // []) | any(.IPAddress == $ip)))) | length > 0' \
    >/dev/null
}

component_exists() {
  curl -skf "${SMD_BASE_URL}/hsm/v2/State/Components/${1}" >/dev/null 2>&1
}

redfish_endpoint_exists() {
  curl -skf "${SMD_BASE_URL}/hsm/v2/Inventory/RedfishEndpoints/${1}" >/dev/null 2>&1
}

ensure_ethernet_interface() {
  local xname="$1" mac="$2" ip="$3"

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
  local bmc_xname="$1" bmc_ip="$2"

  if [ "$DRY_RUN" != "true" ] && redfish_endpoint_exists "$bmc_xname"; then
    log_info "BMC endpoint $bmc_xname already registered"
  else
    run_cmd curl -skf -X POST "${SMD_BASE_URL}/hsm/v2/Inventory/RedfishEndpoints" \
      -H 'Content-Type: application/json' \
      -d "{
        \"ID\": \"$bmc_xname\",
        \"FQDN\": \"$bmc_ip\",
        \"RediscoverOnUpdate\": true,
        \"User\": \"$REDFISH_BMC_USER\",
        \"Password\": \"$REDFISH_BMC_PASSWORD\"
      }" || {
        if [ "$DRY_RUN" != "true" ] && redfish_endpoint_exists "$bmc_xname"; then
          log_info "BMC endpoint $bmc_xname already present after retry"
        else
          log_warn "failed to register BMC endpoint $bmc_xname"
          return 1
        fi
      }
  fi

  run_cmd curl -skf -X PATCH "${SMD_BASE_URL}/hsm/v2/Inventory/RedfishEndpoints/${bmc_xname}" \
    -H 'Content-Type: application/json' \
    -d "{
      \"FQDN\": \"$bmc_ip\",
      \"RediscoverOnUpdate\": true,
      \"User\": \"$REDFISH_BMC_USER\",
      \"Password\": \"$REDFISH_BMC_PASSWORD\"
    }" || {
      log_warn "failed to refresh BMC endpoint $bmc_xname discovery"
      return 1
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log_info "registering $XNAME (mac=$MAC, ip=$IP, bmc=$BMC_IP)"

ensure_ethernet_interface "$XNAME" "$MAC" "$IP" || exit 1
ensure_component "$XNAME" || exit 1

if [ -n "$BMC_IP" ] && [ "$BMC_IP" != "-" ]; then
  ensure_redfish_endpoint "$BMC_XNAME" "$BMC_IP" \
    || log_warn "failed to register BMC for $XNAME"
fi

log_info "registered $XNAME"
