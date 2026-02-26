#!/bin/bash

# --- Configuration ---
# This script defines functions to build OpenCHAMI microservices.
#
# USAGE:
# 1. Source this script into your shell:
#    source ./scripts/build_microservices.sh
#
# 2. Call the desired build function with an explicit git_ref and optional image_tag/repo_uri:
#    build_smd <git_ref> [image_tag] [repo_uri]
#    build_bss main
#    build_all my-feature-branch

readonly REPO_BASE_DIR="/tmp"
CONTAINER_TOOL=${CONTAINER_TOOL:-docker}
BUILD_RETRY_ATTEMPTS=${BUILD_RETRY_ATTEMPTS:-3}
BUILD_RETRY_DELAY_SECONDS=${BUILD_RETRY_DELAY_SECONDS:-5}


# --- Helper Functions ---

# Prints usage information.
usage() {
    echo "Usage: source this script, then call a build function with git_ref and optional image_tag/repo_uri."
    echo
    echo "Available functions:"
    echo "  build_smd <git_ref> [image_tag] [repo_uri]"
    echo "  build_bss <git_ref> [image_tag] [repo_uri]"
    echo "  build_coresmd <git_ref> [image_tag] [repo_uri]"
    echo "  build_cloud-init <git_ref> [image_tag] [repo_uri]"
    echo "  build_pcs <git_ref> [image_tag] [repo_uri]"
    echo "  build_all <git_ref>"
    echo
    echo "  <git_ref>: The git branch or tag to build from (required)."
    echo "  [image_tag]: Optional container image tag. Defaults to git_ref with '/' replaced by '-'."
    echo "  [repo_uri]: Optional Git URI for the source repository."
    return 1
}

sanitize_tag() {
    local git_ref="$1"
    echo "${git_ref//\//-}"
}

run_with_retry() {
    local attempts="${1:-$BUILD_RETRY_ATTEMPTS}"
    local delay_seconds="${2:-$BUILD_RETRY_DELAY_SECONDS}"
    shift 2

    if ! [[ "$attempts" =~ ^[0-9]+$ ]] || [ "$attempts" -lt 1 ]; then
        attempts=1
    fi
    if ! [[ "$delay_seconds" =~ ^[0-9]+$ ]]; then
        delay_seconds=0
    fi

    local attempt=1
    local rc=0
    local cmd_display="$*"

    while [ "$attempt" -le "$attempts" ]; do
        "$@"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            return 0
        fi
        if [ "$attempt" -lt "$attempts" ]; then
            echo "Attempt $attempt/$attempts failed for: $cmd_display (exit $rc). Retrying in ${delay_seconds}s..."
            sleep "$delay_seconds"
        fi
        attempt=$((attempt + 1))
    done

    echo "ERROR: command failed after $attempts attempts: $cmd_display (exit $rc)" >&2
    return "$rc"
}

default_repo_uri_for_service() {
    local service_name="$1"
    case "$service_name" in
        smd) echo "https://github.com/aescoubas/ochami-smd.git" ;;
        bss) echo "https://github.com/aescoubas/ochami-bss.git" ;;
        coresmd) echo "https://github.com/aescoubas/ochami-coresmd.git" ;;
        cloud-init) echo "https://github.com/aescoubas/ochami-cloud-init.git" ;;
        pcs) echo "https://github.com/OpenCHAMI/power-control.git" ;;
        *)
            echo "Error: No default repository URI defined for service '$service_name'." >&2
            return 1
            ;;
    esac
}

repo_dir_from_uri() {
    local repo_uri="$1"
    local repo_name="${repo_uri##*/}"
    repo_name="${repo_name%.git}"
    echo "$repo_name"
}

# Clones a repository and cds into it. This function changes the current directory.
# Arguments:
#   $1: Logical service name (e.g., "smd")
#   $2: Git reference (branch or tag)
#   $3: Optional explicit repository URI
prepare_repo() {
    #set -euo pipefail
    local service_name=$1
    local git_ref=$2
    local repo_uri="${3:-}"

    if [ -z "$repo_uri" ]; then
        repo_uri="$(default_repo_uri_for_service "$service_name")" || return 1
    fi

    local repo_name
    repo_name="$(repo_dir_from_uri "$repo_uri")"
    if [ -z "$repo_name" ]; then
        echo "Error: Could not determine local repository name from URI '$repo_uri'." >&2
        return 1
    fi

    mkdir -p "$REPO_BASE_DIR"
    local repo_dir="$REPO_BASE_DIR/$repo_name"

    if [ -d "$repo_dir" ] && [ ! -d "$repo_dir/.git" ]; then
        echo "Error: '$repo_dir' exists but is not a Git repository." >&2
        return 1
    fi

    if [ ! -d "$repo_dir/.git" ]; then
        echo "Cloning repository: $repo_uri into $repo_dir"
        git clone "$repo_uri" "$repo_dir"
    fi

    cd "$repo_dir"
    local current_origin
    current_origin="$(git remote get-url origin 2>/dev/null || true)"
    if [ -n "$current_origin" ] && [ "$current_origin" != "$repo_uri" ]; then
        echo "Switching origin from '$current_origin' to '$repo_uri'..."
        git remote set-url origin "$repo_uri"
    fi

    echo "Fetching updates and checking out ref: '$git_ref'..."
    git fetch --all --tags
    git checkout "$git_ref"
    git pull || true

    # Normalize permissions to avoid shipping unreadable files (for example migrations)
    # into container images when a prior run used a restrictive umask.
    chmod -R a+rX "$repo_dir"
}


# --- Service-Specific Build Functions ---
# TODO: Modify the '$CONTAINER_TOOL build' command within each function as needed.

build_smd() {
    local original_dir=$(pwd)
    #set -euo pipefail
    local ref="${1:-}"
    if [ -z "${ref}" ]; then
        echo "Error: ${FUNCNAME[0]} requires a git_ref argument." >&2
        return 1
    fi
    local tag="${2:-$(sanitize_tag "$ref")}"
    local repo_uri="${3:-${SMD_REPO_URI:-}}"
    echo "--- Building smd (ref: $ref) ---"
    run_with_retry "$BUILD_RETRY_ATTEMPTS" "$BUILD_RETRY_DELAY_SECONDS" prepare_repo "smd" "$ref" "$repo_uri"
    
    make clean || echo "Warning: make clean failed (non-fatal, continuing...)"
    run_with_retry "$BUILD_RETRY_ATTEMPTS" "$BUILD_RETRY_DELAY_SECONDS" make binaries
    run_with_retry "$BUILD_RETRY_ATTEMPTS" "$BUILD_RETRY_DELAY_SECONDS" "$CONTAINER_TOOL" build -t "localhost/smd:$tag" .

    echo "--- Finished smd ---"
    cd "$original_dir"
}

build_bss() {
    local original_dir=$(pwd)
    #set -euo pipefail
    local ref="${1:-}"
    if [ -z "${ref}" ]; then
        echo "Error: ${FUNCNAME[0]} requires a git_ref argument." >&2
        return 1
    fi
    local tag="${2:-$(sanitize_tag "$ref")}"
    local repo_uri="${3:-${BSS_REPO_URI:-}}"
    echo "--- Building bss (ref: $ref) ---"
    run_with_retry "$BUILD_RETRY_ATTEMPTS" "$BUILD_RETRY_DELAY_SECONDS" prepare_repo "bss" "$ref" "$repo_uri"
    
    make clean || echo "Warning: make clean failed (non-fatal, continuing...)"
    run_with_retry "$BUILD_RETRY_ATTEMPTS" "$BUILD_RETRY_DELAY_SECONDS" make binaries
    run_with_retry "$BUILD_RETRY_ATTEMPTS" "$BUILD_RETRY_DELAY_SECONDS" "$CONTAINER_TOOL" build -t "localhost/bss:$tag" .

    echo "--- Finished bss ---"
    cd "$original_dir"
}

build_coresmd() {
    local original_dir=$(pwd)
    #set -euo pipefail
    local ref="${1:-}"
    if [ -z "${ref}" ]; then
        echo "Error: ${FUNCNAME[0]} requires a git_ref argument." >&2
        return 1
    fi
    local tag="${2:-local-build}"
    local repo_uri="${3:-${CORESMD_REPO_URI:-}}"
    echo "--- Building coresmd (ref: $ref) ---"
    run_with_retry "$BUILD_RETRY_ATTEMPTS" "$BUILD_RETRY_DELAY_SECONDS" prepare_repo "coresmd" "$ref" "$repo_uri"
    
    run_with_retry "$BUILD_RETRY_ATTEMPTS" "$BUILD_RETRY_DELAY_SECONDS" go install github.com/goreleaser/goreleaser/v2@latest
    # build locally
    # the --skip-publish is automatically handled by --snapshot in new version (error in README.md)
    # Set the missing variables
    export PATH=$PATH:$HOME/go/bin
    export BUILD_HOST=$(hostname)
    export BUILD_USER=$(whoami)
    export GO_VERSION=$(go version | awk '{print $3}')
    export DOCKER_TAG="$tag"
    run_with_retry "$BUILD_RETRY_ATTEMPTS" "$BUILD_RETRY_DELAY_SECONDS" ~/go/bin/goreleaser release --snapshot --clean

    run_with_retry "$BUILD_RETRY_ATTEMPTS" "$BUILD_RETRY_DELAY_SECONDS" "$CONTAINER_TOOL" tag "ghcr.io/openchami/coresmd:${DOCKER_TAG}-amd64" "localhost/coresmd:$DOCKER_TAG"

    
    echo "--- Finished coresmd ---"
    cd "$original_dir"
}

#build_configurator() {
#    local original_dir=$(pwd)
#    set -euo pipefail
#    local ref=$1
#    if [ -z "${ref}" ]; then
#        echo "Error: ${FUNCNAME[0]} requires a git_ref argument." >&2
#        return 1
#    fi
#    echo "--- Building configurator (ref: $ref) ---"
#    prepare_repo "configurator" "$ref"
#
#    local tag="${ref//\//-}"
#    $CONTAINER_TOOL build -t "localhost/configurator:$tag" .
#
#    echo "--- Finished configurator ---"
#    cd "$original_dir"
#}

build_cloud-init() {
    local original_dir=$(pwd)
    #set -euo pipefail
    local ref="${1:-}"
    if [ -z "${ref}" ]; then
        echo "Error: ${FUNCNAME[0]} requires a git_ref argument." >&2
        return 1
    fi
    local tag="${2:-$(sanitize_tag "$ref")}"
    local repo_uri="${3:-${CLOUD_INIT_REPO_URI:-}}"
    echo "--- Building cloud-init (ref: $ref) ---"
    run_with_retry "$BUILD_RETRY_ATTEMPTS" "$BUILD_RETRY_DELAY_SECONDS" prepare_repo "cloud-init" "$ref" "$repo_uri"

    run_with_retry "$BUILD_RETRY_ATTEMPTS" "$BUILD_RETRY_DELAY_SECONDS" "$CONTAINER_TOOL" build -t "localhost/cloud-init:$tag" .

    echo "--- Finished cloud-init ---"
    cd "$original_dir"
}

build_pcs() {
    local original_dir=$(pwd)
    local ref="${1:-}"
    if [ -z "${ref}" ]; then
        echo "Error: ${FUNCNAME[0]} requires a git_ref argument." >&2
        return 1
    fi
    local tag="${2:-$(sanitize_tag "$ref")}"
    local repo_uri="${3:-${PCS_REPO_URI:-}}"
    echo "--- Building pcs (ref: $ref) ---"
    run_with_retry "$BUILD_RETRY_ATTEMPTS" "$BUILD_RETRY_DELAY_SECONDS" prepare_repo "pcs" "$ref" "$repo_uri"

    run_with_retry "$BUILD_RETRY_ATTEMPTS" "$BUILD_RETRY_DELAY_SECONDS" "$CONTAINER_TOOL" build -f Dockerfile.build -t "localhost/pcs:$tag" .

    echo "--- Finished pcs ---"
    cd "$original_dir"
}

#build_opaal() {
#    local original_dir=$(pwd)
#    set -euo pipefail
#    local ref=$1
#    if [ -z "${ref}" ]; then
#        echo "Error: ${FUNCNAME[0]} requires a git_ref argument." >&2
#        return 1
#    fi
#    echo "--- Building opaal (ref: $ref) ---"
#    prepare_repo "opaal" "$ref"
#
#    local tag="${ref//\//-}"
#    $CONTAINER_TOOL build -t "localhost/opaal:$tag" .
#
#    echo "--- Finished opaal ---"
#    cd "$original_dir"
#}

#build_tpm-manager() {
#    local original_dir=$(pwd)
#    set -euo pipefail
#    local ref=$1
#    if [ -z "${ref}" ]; then
#        echo "Error: ${FUNCNAME[0]} requires a git_ref argument." >&2
#        return 1
#    fi
#    echo "--- Building tpm-manager (ref: $ref) ---"
#    prepare_repo "tpm-manager" "$ref"
#
#    local tag="${ref//\//-}"
#    $CONTAINER_TOOL build -t "localhost/tpm-manager:$tag" .
#
#    echo "--- Finished tpm-manager ---"
#    cd "$original_dir"
#}

# --- Aggregate Build Function ---

build_all() {
    # This function builds all enabled microservices from the same git ref.
    # It will stop if any individual build fails.
    local original_dir=$(pwd)
    #set -euo pipefail
    local git_ref=$1
    if [ -z "${git_ref}" ]; then
        echo "Error: ${FUNCNAME[0]} requires a git_ref argument." >&2
        return 1
    fi
    echo "--- Building all services (ref: $git_ref) ---"
    build_smd "$git_ref"
    build_bss "$git_ref"
    build_coresmd "$git_ref"
    build_cloud-init "$git_ref"
    build_pcs "$git_ref"
    #build_configurator "$git_ref"
    #build_opaal "$git_ref"
    #build_tpm-manager "$git_ref"
    echo "--- Finished building all services ---"
    # The individual build functions already return to the original directory
}
