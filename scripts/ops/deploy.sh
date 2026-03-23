#!/usr/bin/env bash
# deploy.sh — Top-level deployment orchestrator for OpenCHAMI.
# Usage: ./deploy.sh --method compose|lab-vm|quadlets|minikube [--dry-run]
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
NIX_FLAKE_REF="${OPENCHAMI_NIX_FLAKE_REF:-$(nix_flake_ref "$PROJECT_ROOT")}"

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
PXE_INTERFACE="${PXE_INTERFACE:-virbr-ochami}"
LIBVIRT_NETWORK_NAME="${LIBVIRT_NETWORK_NAME:-ochami-pxe-net}"
HOST_IP="${HOST_IP:-192.168.100.1}"
PXE_CIDR="${PXE_CIDR:-24}"
LIBVIRT_NET_STATE_FILE="${PROJECT_ROOT}/.tmp/libvirt-networks.paused"
TEST_NODE_IMAGE="${TEST_NODE_IMAGE:-nixos}"
TEST_NODE_IMAGE="${OPENCHAMI_TEST_NODE_IMAGE:-$TEST_NODE_IMAGE}"
BOOT_ARTIFACTS_PATH="${BOOT_ARTIFACTS_PATH:-}"
export OPENCHAMI_TEST_NODE_IMAGE="$TEST_NODE_IMAGE"

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
  lab-vm)
    DEFAULT_SECRETS_FILE=""
    ;;
  *)
    DEFAULT_SECRETS_FILE="/etc/openchami/secrets.env"
    ;;
esac
SECRETS_FILE="${OPENCHAMI_SECRETS:-$DEFAULT_SECRETS_FILE}"
if [ "$METHOD" = "lab-vm" ]; then
  log_info "step 2/6: skipping secrets (not applicable for lab-vm)"
elif [ "$DRY_RUN" != "true" ]; then
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

# Build boot artifacts early so they are available for compose volume mounts.
if [ "$METHOD" != "lab-vm" ] && [ "$DRY_RUN" != "true" ] && [ -z "$BOOT_ARTIFACTS_PATH" ]; then
  BOOT_ARTIFACTS_OUTPUT="$(boot_artifacts_output_for_image "$TEST_NODE_IMAGE")"
  log_info "preparing ${BOOT_ARTIFACTS_OUTPUT} for test node image ${TEST_NODE_IMAGE}..."
  BOOT_ARTIFACTS_PATH="$(
    OPENCHAMI_TEST_NODE_IMAGE="$TEST_NODE_IMAGE" \
      nix build --impure "${NIX_FLAKE_REF}#${BOOT_ARTIFACTS_OUTPUT}" --no-link --print-out-paths 2>/dev/null
  )"
  if [ -z "$BOOT_ARTIFACTS_PATH" ] || [ ! -d "$BOOT_ARTIFACTS_PATH" ]; then
    log_error "failed to build ${BOOT_ARTIFACTS_OUTPUT}"
    exit 1
  fi
fi

# Step 4: Start services
log_info "step 4/6: starting services (method=$METHOD)..."
case "$METHOD" in
  compose|docker-compose)
    COMPOSE_DIR="${COMPOSE_DIR:-${PROJECT_ROOT}/ochami-docker-compose}"
    COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
    CONFIG_DIR="${COMPOSE_DIR}/configs"
    ensure_libvirt_network "$LIBVIRT_NETWORK_NAME" "$PXE_INTERFACE" "$HOST_IP" "$PXE_CIDR"
    disable_conflicting_dhcp_networks "$PXE_INTERFACE" "$LIBVIRT_NET_STATE_FILE"
    ensure_bridge_carrier "$PXE_INTERFACE"

    # Use committed static artifacts if present; regenerate via nix otherwise.
    if [ -f "$COMPOSE_FILE" ] && [ -d "$CONFIG_DIR" ]; then
      log_info "using committed docker-compose artifacts from $COMPOSE_DIR"
    else
      log_info "generating docker-compose directory via nix..."
      COMPOSE_OUTPUT="$(flake_output_for_profile "docker-compose-yml" "$PROFILE")"
      GENERATED="$(
        OPENCHAMI_TEST_NODE_IMAGE="$TEST_NODE_IMAGE" \
          nix build --impure "${NIX_FLAKE_REF}#${COMPOSE_OUTPUT}" --no-link --print-out-paths 2>/dev/null
      )"
      if [ -z "$GENERATED" ] || [ ! -d "$GENERATED" ]; then
        log_error "failed to generate ${COMPOSE_OUTPUT}"
        exit 1
      fi
      mkdir -p "$COMPOSE_DIR"
      cp "$GENERATED"/docker-compose.yml "$COMPOSE_FILE"
      cp -r "$GENERATED"/configs "$CONFIG_DIR"
      cp -r "$GENERATED"/pg-init "$COMPOSE_DIR/pg-init"
      [ -f "$GENERATED/.env.template" ] && cp "$GENERATED/.env.template" "$COMPOSE_DIR/.env.template"
      chmod -R u+w "$COMPOSE_DIR"
      log_info "docker-compose artifacts generated at $COMPOSE_DIR"
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

  lab-vm)
    "$SCRIPT_DIR/lab-vm.sh" start $DRY_RUN_FLAG
    ;;

  quadlets)
    PROFILE_DIR="${PROFILE_DIR:-}"
    if [ -z "$PROFILE_DIR" ]; then
      log_info "building deploy profile with nix..."
      DEPLOY_PROFILE_OUTPUT="$(flake_output_for_profile "deploy-profile" "$PROFILE")"
      PROFILE_DIR="$(
        OPENCHAMI_TEST_NODE_IMAGE="$TEST_NODE_IMAGE" \
          nix build --impure "${NIX_FLAKE_REF}#${DEPLOY_PROFILE_OUTPUT}" --no-link --print-out-paths 2>/dev/null
      )"
    fi
    if [ -z "$PROFILE_DIR" ] || [ ! -d "$PROFILE_DIR" ]; then
      log_error "deploy profile not found. Run: nix build .#$(flake_output_for_profile "deploy-profile" "$PROFILE")"
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
case "$METHOD" in
  lab-vm)
    "$SCRIPT_DIR/lab-vm.sh" health $DRY_RUN_FLAG
    ;;
  *)
    CHECK_KEA="$CHECK_KEA" TEST_NODE_IMAGE="$TEST_NODE_IMAGE" BOOT_ARTIFACTS_PATH="$BOOT_ARTIFACTS_PATH" \
      PXE_INTERFACE="$PXE_INTERFACE" COMPOSE_FILE="${COMPOSE_FILE:-}" SECRETS_FILE="$SECRETS_FILE" \
      "$SCRIPT_DIR/health-check.sh" $DRY_RUN_FLAG
    ;;
esac

# Step 6: Register BSS defaults
log_info "step 6/6: registering BSS defaults..."
case "$METHOD" in
  lab-vm)
    log_info "skipping BSS default registration (not applicable for lab-vm)"
    ;;
  *)
    TEST_NODE_IMAGE="$TEST_NODE_IMAGE" BOOT_ARTIFACTS_PATH="$BOOT_ARTIFACTS_PATH" \
      "$SCRIPT_DIR/register-bss-defaults.sh" $DRY_RUN_FLAG
    ;;
esac

log_info "deployment complete (method=$METHOD profile=$PROFILE test-node-image=$TEST_NODE_IMAGE)"
