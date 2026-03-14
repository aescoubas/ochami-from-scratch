#!/usr/bin/env bash
# deploy.sh — Top-level deployment orchestrator for OpenCHAMI.
# Usage: ./deploy.sh --method compose|quadlets|minikube [--dry-run]
#
# Steps:
#   1. Check dependencies
#   2. Ensure secrets
#   3. Build local OCI images
#   4. Start services
#   5. Health check
#   6. Register BSS defaults

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
. "$SCRIPT_DIR/lib/common.sh"

METHOD=""
parse_common_args "$@"

if [ -z "$METHOD" ]; then
  log_error "usage: $0 --method compose|quadlets|minikube [--dry-run]"
  exit 1
fi

DRY_RUN_FLAG=""
if [ "$DRY_RUN" = "true" ]; then
  DRY_RUN_FLAG="--dry-run"
fi
PXE_INTERFACE="${PXE_INTERFACE:-virbr-ochami}"
LIBVIRT_NETWORK_NAME="${LIBVIRT_NETWORK_NAME:-ochami-pxe-net}"
HOST_IP="${HOST_IP:-192.168.100.1}"
PXE_CIDR="${PXE_CIDR:-24}"
LIBVIRT_NET_STATE_FILE="${PROJECT_ROOT}/.tmp/libvirt-networks.paused"

CHECK_KEA=false
case "$METHOD" in
  compose|docker-compose|quadlets)
    CHECK_KEA=true
    ;;
esac

# Step 1: Check dependencies
log_info "step 1/6: checking dependencies..."
"$SCRIPT_DIR/check-deps.sh" --method "$METHOD" $DRY_RUN_FLAG

# Step 2: Ensure secrets
case "$METHOD" in
  compose|docker-compose)
    DEFAULT_SECRETS_FILE="${PROJECT_ROOT}/.tmp/openchami-secrets.env"
    ;;
  *)
    DEFAULT_SECRETS_FILE="/etc/openchami/secrets.env"
    ;;
esac
SECRETS_FILE="${OPENCHAMI_SECRETS:-$DEFAULT_SECRETS_FILE}"
log_info "step 2/6: ensuring secrets at $SECRETS_FILE..."
if [ "$DRY_RUN" != "true" ]; then
  ensure_secrets_file "$SECRETS_FILE"
fi

# Step 3: Build local OCI images (compose and quadlets only)
case "$METHOD" in
  compose|docker-compose|quadlets)
    if [ "${SKIP_IMAGE_BUILD:-}" != "true" ]; then
      log_info "step 3/6: building local OCI images..."
      RUNTIME_FLAG=""
      if [ "$METHOD" = "quadlets" ]; then
        RUNTIME_FLAG="--runtime podman"
      fi
      "$SCRIPT_DIR/build-images.sh" $RUNTIME_FLAG
    else
      log_info "step 3/6: skipping image build (SKIP_IMAGE_BUILD=true)"
    fi
    ;;
  *)
    log_info "step 3/6: skipping image build (not applicable for $METHOD)"
    ;;
esac

# Step 4: Start services
log_info "step 4/6: starting services (method=$METHOD)..."
case "$METHOD" in
  compose|docker-compose)
    COMPOSE_DIR="${COMPOSE_DIR:-${PROJECT_ROOT}/ochami-docker-compose}"
    COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.generated.yml"
    CONFIG_DIR="${COMPOSE_DIR}/configs"
    ensure_libvirt_network "$LIBVIRT_NETWORK_NAME" "$PXE_INTERFACE" "$HOST_IP" "$PXE_CIDR"
    disable_conflicting_dhcp_networks "$PXE_INTERFACE" "$LIBVIRT_NET_STATE_FILE"
    ensure_bridge_carrier "$PXE_INTERFACE"
    mkdir -p "$COMPOSE_DIR"
    mkdir -p "$CONFIG_DIR"
    log_info "generating docker-compose.yml via nix..."
    GENERATED=$(nix build .#docker-compose-yml --no-link --print-out-paths 2>/dev/null)
    if [ -z "$GENERATED" ] || [ ! -f "$GENERATED" ]; then
      log_error "failed to generate docker-compose.yml"
      exit 1
    fi
    cp "$GENERATED" "$COMPOSE_FILE"
    chmod 644 "$COMPOSE_FILE"
    log_info "docker-compose.yml generated at $COMPOSE_FILE"
    log_info "rendering compose config files via nix deploy profile..."
    PROFILE_DIR=$(nix build .#deploy-profile --no-link --print-out-paths 2>/dev/null)
    if [ -z "$PROFILE_DIR" ] || [ ! -d "$PROFILE_DIR" ]; then
      log_error "failed to build deploy profile for compose configs"
      exit 1
    fi
    # shellcheck disable=SC1090
    . "$SECRETS_FILE"
    export $(cut -d= -f1 "$SECRETS_FILE" | grep -v '^#')
    envsubst_vars="$(cut -d= -f1 "$SECRETS_FILE" | grep -v '^#' | sed 's/^/${/; s/$/}/' | tr '\n' ' ')"
    for f in "$PROFILE_DIR"/etc/openchami/configs/*; do
      envsubst "$envsubst_vars" < "$f" > "$CONFIG_DIR/$(basename "$f")"
      chmod 644 "$CONFIG_DIR/$(basename "$f")"
    done
    run_cmd docker compose -f "$COMPOSE_FILE" --env-file "$SECRETS_FILE" up -d --wait --wait-timeout "${COMPOSE_WAIT_TIMEOUT:-120}"
    ;;

  quadlets)
    PROFILE_DIR="${PROFILE_DIR:-}"
    if [ -z "$PROFILE_DIR" ]; then
      log_info "building deploy profile with nix..."
      PROFILE_DIR=$(nix build .#deploy-profile --no-link --print-out-paths 2>/dev/null)
    fi
    if [ -z "$PROFILE_DIR" ] || [ ! -d "$PROFILE_DIR" ]; then
      log_error "deploy profile not found. Run: nix build .#deploy-profile"
      exit 1
    fi
    run_cmd sudo "$PROFILE_DIR/bin/activate"
    ;;

  minikube)
    RELEASE="${HELM_RELEASE:-ochami}"
    NAMESPACE="${HELM_NAMESPACE:-default}"
    CHART_DIR="${CHART_DIR:-$(dirname "$SCRIPT_DIR")/ochami-helm}"
    VALUES="${VALUES_FILE:-$CHART_DIR/values.yaml}"
    run_cmd helm upgrade --install "$RELEASE" "$CHART_DIR" \
      -n "$NAMESPACE" \
      -f "$VALUES" \
      --set postgres.password="$(grep POSTGRES_PASSWORD "$SECRETS_FILE" | cut -d= -f2-)" \
      --set postgres.smd_password="$(grep SMD_DB_PASSWORD "$SECRETS_FILE" | cut -d= -f2-)" \
      --set postgres.bss_password="$(grep BSS_DB_PASSWORD "$SECRETS_FILE" | cut -d= -f2-)" \
      --set postgres.kea_password="$(grep KEA_DB_PASSWORD "$SECRETS_FILE" | cut -d= -f2-)" \
      --set postgres.pcs_password="$(grep PCS_DB_PASSWORD "$SECRETS_FILE" | cut -d= -f2-)" \
      --set postgres.stork_password="$(grep STORK_DB_PASSWORD "$SECRETS_FILE" | cut -d= -f2-)"
    ;;

  *)
    log_error "unknown method: $METHOD"
    exit 1
    ;;
esac

# Step 5: Health check
log_info "step 5/6: running health checks..."
CHECK_KEA="$CHECK_KEA" PXE_INTERFACE="$PXE_INTERFACE" COMPOSE_FILE="${COMPOSE_FILE:-}" SECRETS_FILE="$SECRETS_FILE" "$SCRIPT_DIR/health-check.sh" $DRY_RUN_FLAG

# Step 6: Register BSS defaults
log_info "step 6/6: registering BSS defaults..."
"$SCRIPT_DIR/register-bss-defaults.sh" $DRY_RUN_FLAG

log_info "deployment complete (method=$METHOD)"
