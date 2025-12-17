#!/bin/bash

# --- Configuration ---
# This script defines functions to build OpenCHAMI microservices.
#
# USAGE:
# 1. Source this script into your shell:
#    source ./build_microservices.sh
#
# 2. Call the desired build function with an explicit git_ref:
#    build_smd <git_ref>
#    build_bss main
#    build_all my-feature-branch

# Base URL for the GitHub organization where the forks reside
readonly ORG_URL="https://github.com/aescoubas"
readonly REPO_BASE_DIR="/tmp"

# Associative array mapping logical service names to their forked repository names
declare -A REPO_FORK_NAMES
REPO_FORK_NAMES["smd"]="ochami-smd"
REPO_FORK_NAMES["bss"]="ochami-bss"
REPO_FORK_NAMES["coresmd"]="ochami-coresmd"
#REPO_FORK_NAMES["configurator"]="ochami-configurator"
REPO_FORK_NAMES["cloud-init"]="ochami-cloud-init"
#REPO_FORK_NAMES["opaal"]="ochami-opaal"
#REPO_FORK_NAMES["tpm-manager"]="ochami-tpm-manager"


# --- Helper Functions ---

# Prints usage information.
usage() {
    echo "Usage: source this script, then call a build function with an explicit git_ref."
    echo
    echo "Available functions:"
    echo "  build_smd <git_ref>"
    echo "  build_bss <git_ref>"
    echo "  build_coresmd <git_ref>"
    echo "  build_cloud-init <git_ref>"
    echo "  build_all <git_ref>"
    echo
    echo "  <git_ref>: The git branch or tag to build from. This argument is now mandatory."
    return 1
}

# Clones a repository and cds into it. This function changes the current directory.
# Arguments:
#   $1: Logical service name (e.g., "smd")
#   $2: Git reference (branch or tag)
prepare_repo() {
    #set -euo pipefail
    local service_name=$1
    local git_ref=$2
    local forked_repo_name="${REPO_FORK_NAMES[$service_name]}"
    
    if [ -z "$forked_repo_name" ]; then
        echo "Error: No forked repository name defined for service '$service_name'." >&2
        return 1
    fi

    
    mkdir -p "$REPO_BASE_DIR"

    if [ ! -d "$REPO_BASE_DIR/$forked_repo_name" ]; then
        echo "Cloning repository: $ORG_URL/$forked_repo_name.git into $REPO_BASE_DIR"
        git clone "$ORG_URL/$forked_repo_name.git" "$REPO_BASE_DIR/$forked_repo_name"
    fi
    
    cd "$REPO_BASE_DIR/$forked_repo_name"
    echo "Fetching updates and checking out ref: '$git_ref'..."
    git fetch --all --tags
    git checkout "$git_ref"
    git pull || true
}


# --- Service-Specific Build Functions ---
# TODO: Modify the 'docker build' command within each function as needed.

build_smd() {
    local original_dir=$(pwd)
    #set -euo pipefail
    local ref=$1
    if [ -z "${ref}" ]; then
        echo "Error: ${FUNCNAME[0]} requires a git_ref argument." >&2
        return 1
    fi
    echo "--- Building smd (ref: $ref) ---"
    prepare_repo "smd" "$ref"
    
    local tag="${ref//\//-}"
    make clean && make binaries
    docker build -t "localhost/smd:$tag" .
    
    echo "--- Finished smd ---"
    cd "$original_dir"
}

build_bss() {
    local original_dir=$(pwd)
    #set -euo pipefail
    local ref=$1
    if [ -z "${ref}" ]; then
        echo "Error: ${FUNCNAME[0]} requires a git_ref argument." >&2
        return 1
    fi
    echo "--- Building bss (ref: $ref) ---"
    prepare_repo "bss" "$ref"
    
    local tag="${ref//\//-}"
    make clean && make binaries
    docker build -t "localhost/bss:$tag" .
    
    echo "--- Finished bss ---"
    cd "$original_dir"
}

build_coresmd() {
    local original_dir=$(pwd)
    #set -euo pipefail
    local ref=$1
    if [ -z "${ref}" ]; then
        echo "Error: ${FUNCNAME[0]} requires a git_ref argument." >&2
        return 1
    fi
    echo "--- Building coresmd (ref: $ref) ---"
    prepare_repo "coresmd" "$ref"
    
    go install github.com/goreleaser/goreleaser/v2@latest
    # build locally
    # the --skip-publish is automatically handled by --snapshot in new version (error in README.md)
    # Set the missing variables
    export PATH=$PATH:$HOME/go/bin
    export BUILD_HOST=$(hostname)
    export BUILD_USER=$(whoami)
    export GO_VERSION=$(go version | awk '{print $3}')
    export DOCKER_TAG=local-build
    ~/go/bin/goreleaser release --snapshot --clean

    #local tag="${ref//\//-}"
    docker tag "ghcr.io/openchami/coresmd:${DOCKER_TAG}-amd64" "localhost/coresmd:$DOCKER_TAG"

    
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
#    docker build -t "localhost/configurator:$tag" .
#
#    echo "--- Finished configurator ---"
#    cd "$original_dir"
#}

build_cloud-init() {
    local original_dir=$(pwd)
    #set -euo pipefail
    local ref=$1
    if [ -z "${ref}" ]; then
        echo "Error: ${FUNCNAME[0]} requires a git_ref argument." >&2
        return 1
    fi
    echo "--- Building cloud-init (ref: $ref) ---"
    prepare_repo "cloud-init" "$ref"

    local tag="${ref//\//-}"
    docker build -t "localhost/cloud-init:$tag" .

    echo "--- Finished cloud-init ---"
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
#    docker build -t "localhost/opaal:$tag" .
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
#    docker build -t "localhost/tpm-manager:$tag" .
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
    #build_configurator "$git_ref"
    #build_opaal "$git_ref"
    #build_tpm-manager "$git_ref"
    echo "--- Finished building all services ---"
    # The individual build functions already return to the original directory
}
