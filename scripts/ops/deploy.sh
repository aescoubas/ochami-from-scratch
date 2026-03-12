#!/usr/bin/env bash
# deploy.sh — Top-level deployment orchestrator for OpenCHAMI.
# Usage: ./deploy.sh --method compose|quadlets|minikube [--dry-run]
#
# Steps:
#   1. Check dependencies
#   2. Ensure secrets
#   3. Start services
#   4. Health check
#   5. Register BSS defaults

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Step 1: Check dependencies
log_info "step 1/5: checking dependencies..."
"$SCRIPT_DIR/check-deps.sh" --method "$METHOD" $DRY_RUN_FLAG

# Step 2: Ensure secrets
SECRETS_FILE="${OPENCHAMI_SECRETS:-/etc/openchami/secrets.env}"
log_info "step 2/5: ensuring secrets at $SECRETS_FILE..."
if [ "$DRY_RUN" != "true" ]; then
  ensure_secrets_file "$SECRETS_FILE"
fi

# Step 3: Start services
log_info "step 3/5: starting services (method=$METHOD)..."
case "$METHOD" in
  compose|docker-compose)
    COMPOSE_DIR="${COMPOSE_DIR:-$(dirname "$SCRIPT_DIR")/ochami-docker-compose}"
    COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
    if [ ! -f "$COMPOSE_FILE" ]; then
      log_error "docker-compose.yml not found at $COMPOSE_FILE"
      exit 1
    fi
    run_cmd docker compose -f "$COMPOSE_FILE" --env-file "$SECRETS_FILE" up -d
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

# Step 4: Health check
log_info "step 4/5: running health checks..."
"$SCRIPT_DIR/health-check.sh" $DRY_RUN_FLAG

# Step 5: Register BSS defaults
log_info "step 5/5: registering BSS defaults..."
"$SCRIPT_DIR/register-bss-defaults.sh" $DRY_RUN_FLAG

log_info "deployment complete (method=$METHOD)"
