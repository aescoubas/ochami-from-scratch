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
  log_error "usage: $0 --method compose|quadlets|minikube [--profile official|dev] [--dry-run]"
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
TEST_NODE_IMAGE="${TEST_NODE_IMAGE:-almalinux}"
TEST_NODE_IMAGE="${OPENCHAMI_TEST_NODE_IMAGE:-$TEST_NODE_IMAGE}"
BOOT_ARTIFACTS_PATH="${BOOT_ARTIFACTS_PATH:-}"
export OPENCHAMI_TEST_NODE_IMAGE="$TEST_NODE_IMAGE"

# Source deployment profile.
PROFILE_ENV="${PROJECT_ROOT}/profiles/${PROFILE}.env"
if [ -f "$PROFILE_ENV" ]; then
  log_info "loading profile: $PROFILE_ENV"
  # shellcheck disable=SC1090
  . "$PROFILE_ENV"
fi

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
if [ "$DRY_RUN" != "true" ]; then
  log_info "step 2/6: ensuring secrets at $SECRETS_FILE..."
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
      OPENCHAMI_PROFILE="$PROFILE" "$SCRIPT_DIR/build-images.sh" $RUNTIME_FLAG
    else
      log_info "step 3/6: skipping image build (SKIP_IMAGE_BUILD=true)"
    fi
    ;;
  *)
    log_info "step 3/6: skipping image build (not applicable for $METHOD)"
    ;;
esac

# Step 3.5: Build boot artifacts early so they are available for compose volume mounts.
if [ "$DRY_RUN" != "true" ] && [ -z "$BOOT_ARTIFACTS_PATH" ]; then
  log_info "step 3.5/6: building boot artifacts for test node image ${TEST_NODE_IMAGE}..."
  BOOT_ARTIFACTS_PATH="$(
    OPENCHAMI_TEST_NODE_IMAGE="$TEST_NODE_IMAGE" \
      "$SCRIPT_DIR/build-boot-artifacts.sh" 2>/dev/null
  )"
  if [ -z "$BOOT_ARTIFACTS_PATH" ] || [ ! -d "$BOOT_ARTIFACTS_PATH" ]; then
    log_error "failed to build boot artifacts"
    exit 1
  fi
fi

# Step 4: Start services
log_info "step 4/6: starting services (method=$METHOD)..."
case "$METHOD" in
  compose|docker-compose)
    COMPOSE_DIR="${COMPOSE_DIR:-${PROJECT_ROOT}/deploy/compose}"
    COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
    CONFIG_DIR="${COMPOSE_DIR}/configs"
    ensure_libvirt_network "$LIBVIRT_NETWORK_NAME" "$PXE_INTERFACE" "$HOST_IP" "$PXE_CIDR"
    disable_conflicting_dhcp_networks "$PXE_INTERFACE" "$LIBVIRT_NET_STATE_FILE"
    ensure_bridge_carrier "$PXE_INTERFACE"

    if [ -f "$COMPOSE_FILE" ] && [ -d "$CONFIG_DIR" ]; then
      log_info "using docker-compose artifacts from $COMPOSE_DIR"
    else
      log_error "docker-compose artifacts not found at $COMPOSE_DIR"
      log_error "ensure deploy/compose/docker-compose.yml and deploy/compose/configs/ exist"
      exit 1
    fi

    # Render config templates with secrets into a staging directory, then swap
    # them into the configs dir for compose volume mounts. Committed templates
    # are backed up and restored by teardown.
    RENDERED_CONFIG_DIR="${PROJECT_ROOT}/.tmp/rendered-configs"
    rm -rf "$RENDERED_CONFIG_DIR"
    mkdir -p "$RENDERED_CONFIG_DIR"
    # shellcheck disable=SC1090
    . "$SECRETS_FILE"
    # shellcheck disable=SC2046
    export $(cut -d= -f1 "$SECRETS_FILE" | grep -v '^#')
    envsubst_vars="$(cut -d= -f1 "$SECRETS_FILE" | grep -v '^#' | sed 's/^/${/; s/$/}/' | tr '\n' ' ')"
    for f in "$CONFIG_DIR"/*; do
      [ -f "$f" ] || continue
      envsubst "$envsubst_vars" < "$f" > "$RENDERED_CONFIG_DIR/$(basename "$f")"
      chmod 644 "$RENDERED_CONFIG_DIR/$(basename "$f")"
    done
    # Back up committed templates and install rendered configs for compose.
    if [ ! -d "${CONFIG_DIR}.templates" ]; then
      cp -r "$CONFIG_DIR" "${CONFIG_DIR}.templates"
    fi
    cp "$RENDERED_CONFIG_DIR"/* "$CONFIG_DIR/"

    # Place boot artifacts where the compose volume mount expects them.
    if [ -n "$BOOT_ARTIFACTS_PATH" ] && [ -d "$BOOT_ARTIFACTS_PATH" ]; then
      ARTIFACTS_DIR="${COMPOSE_DIR}/artifacts"
      rm -rf "$ARTIFACTS_DIR" 2>/dev/null || sudo rm -rf "$ARTIFACTS_DIR"
      mkdir -p "$ARTIFACTS_DIR"
      cp -rL "$BOOT_ARTIFACTS_PATH"/artifacts/* "$ARTIFACTS_DIR/"
      chmod -R u+rw "$ARTIFACTS_DIR"
      log_info "boot artifacts placed at $ARTIFACTS_DIR"
    fi

    docker_compose -f "$COMPOSE_FILE" --env-file "$SECRETS_FILE" up -d --wait --wait-timeout "${COMPOSE_WAIT_TIMEOUT:-120}"
    ;;

  quadlets)
    PROFILE_DIR="${PROFILE_DIR:-}"
    if [ -z "$PROFILE_DIR" ]; then
      log_error "PROFILE_DIR must be set for quadlet deployments"
      exit 1
    fi
    if [ ! -d "$PROFILE_DIR" ]; then
      log_error "deploy profile not found at $PROFILE_DIR"
      exit 1
    fi
    # Place boot artifacts for quadlets containers.
    if [ -n "$BOOT_ARTIFACTS_PATH" ] && [ -d "$BOOT_ARTIFACTS_PATH" ]; then
      run_cmd sudo mkdir -p /etc/openchami/artifacts
      run_cmd sudo cp -rL "$BOOT_ARTIFACTS_PATH"/artifacts/* /etc/openchami/artifacts/
      log_info "boot artifacts placed at /etc/openchami/artifacts"
    fi
    run_cmd sudo "$PROFILE_DIR/bin/activate"
    ;;

  minikube)
    RELEASE="${HELM_RELEASE:-ochami}"
    NAMESPACE="${HELM_NAMESPACE:-default}"
    CHART_DIR="${CHART_DIR:-$(dirname "$SCRIPT_DIR")/deploy/helm}"
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
CHECK_KEA="$CHECK_KEA" TEST_NODE_IMAGE="$TEST_NODE_IMAGE" BOOT_ARTIFACTS_PATH="$BOOT_ARTIFACTS_PATH" \
  PXE_INTERFACE="$PXE_INTERFACE" COMPOSE_FILE="${COMPOSE_FILE:-}" SECRETS_FILE="$SECRETS_FILE" \
  "$SCRIPT_DIR/health-check.sh" $DRY_RUN_FLAG

# Step 6: Register BSS defaults
log_info "step 6/6: registering BSS defaults..."
TEST_NODE_IMAGE="$TEST_NODE_IMAGE" BOOT_ARTIFACTS_PATH="$BOOT_ARTIFACTS_PATH" \
  "$SCRIPT_DIR/register-bss-defaults.sh" $DRY_RUN_FLAG

log_info "deployment complete (method=$METHOD profile=$PROFILE test-node-image=$TEST_NODE_IMAGE)"
