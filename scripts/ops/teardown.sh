#!/usr/bin/env bash
# teardown.sh — Tear down OpenCHAMI services by deployment method.
# Usage: ./teardown.sh --method compose|lab-vm|quadlets|minikube [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

METHOD=""
parse_common_args "$@"

if [ -z "$METHOD" ]; then
  log_error "usage: $0 --method compose|lab-vm|quadlets|minikube [--profile official|dev] [--dry-run]"
  exit 1
fi

DRY_RUN_FLAG=""
if [ "$DRY_RUN" = "true" ]; then
  DRY_RUN_FLAG="--dry-run"
fi

case "$METHOD" in
  compose|docker-compose)
    log_info "tearing down docker-compose deployment..."
    COMPOSE_DIR="${COMPOSE_DIR:-$(dirname "$(dirname "$SCRIPT_DIR")")/ochami-docker-compose}"
    COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.generated.yml"
    LIBVIRT_NET_STATE_FILE="$(dirname "$(dirname "$SCRIPT_DIR")")/.tmp/libvirt-networks.paused"
    LIBVIRT_BMC_CONTAINER_PREFIX="${LIBVIRT_BMC_CONTAINER_PREFIX:-ochami-libvirt-bmc}"
    if [ -f "$COMPOSE_FILE" ]; then
      docker_compose -f "$COMPOSE_FILE" down -v --remove-orphans
    else
      # Try generated compose file
      docker_compose down -v --remove-orphans
    fi
    if [ "$DRY_RUN" = "true" ]; then
      log_info "[dry-run] would remove docker containers matching ${LIBVIRT_BMC_CONTAINER_PREFIX}-*"
    elif docker_daemon_reachable; then
      for container in $(docker ps -a --filter "name=${LIBVIRT_BMC_CONTAINER_PREFIX}-" --format '{{.Names}}' 2>/dev/null); do
        run_cmd docker rm -f "$container" 2>/dev/null || true
      done
    fi
    remove_bridge_carrier_dummy
    restore_conflicting_dhcp_networks "$LIBVIRT_NET_STATE_FILE"
    ;;

  lab-vm)
    log_info "tearing down lab-vm deployment..."
    "$SCRIPT_DIR/lab-vm.sh" stop $DRY_RUN_FLAG
    ;;

  quadlets)
    log_info "tearing down quadlet deployment..."
    CONTAINER_TOOL="${CONTAINER_TOOL:-sudo podman}"
    run_cmd sudo systemctl stop ochami.target 2>/dev/null || true
    run_cmd sudo systemctl stop openchami.target 2>/dev/null || true

    # Stop all ochami services
    for unit in $(systemctl list-units --no-legend 'ochami-*' 2>/dev/null | awk '{print $1}'); do
      run_cmd sudo systemctl stop "$unit" 2>/dev/null || true
    done

    # Remove containers
    for container in $($CONTAINER_TOOL ps -a --filter "name=ochami-" --format '{{.Names}}' 2>/dev/null); do
      run_cmd $CONTAINER_TOOL rm -f "$container" 2>/dev/null || true
    done

    # Remove systemd unit files
    run_cmd sudo rm -f /etc/systemd/system/ochami-*.service
    run_cmd sudo rm -f /etc/systemd/system/ochami.target
    run_cmd sudo rm -f /etc/systemd/system/openchami.target
    run_cmd sudo systemctl daemon-reload
    ;;

  minikube)
    log_info "tearing down minikube deployment..."
    RELEASE="${HELM_RELEASE:-ochami}"
    NAMESPACE="${HELM_NAMESPACE:-default}"
    run_cmd helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null || true

    # Clean up PVCs
    run_cmd kubectl delete pvc -l app.kubernetes.io/instance="$RELEASE" -n "$NAMESPACE" 2>/dev/null || true
    ;;

  *)
    log_error "unknown method: $METHOD"
    exit 1
    ;;
esac

log_info "teardown complete for method=$METHOD profile=$PROFILE"
