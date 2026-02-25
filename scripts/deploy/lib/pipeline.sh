#!/bin/bash
# Shared deployment lifecycle helpers for scripts/deploy/*.sh

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: scripts/deploy/lib/pipeline.sh must be sourced, not executed directly." >&2
    exit 1
fi

common_deploy_bootstrap() {
    local deployment_name="$1"
    shift

    local rc=0
    parse_common_deploy_args "$@" || rc=$?
    if [ $rc -eq 2 ]; then
        show_help
        exit 0
    elif [ $rc -ne 0 ]; then
        exit $rc
    fi

    validate_common_deploy_args
    ensure_generated_secrets

    info "=== ${deployment_name} ==="

    if [ "$FORCE_REBUILD" = true ]; then
        echo "Force rebuild enabled."
    fi
}

common_install_prerequisites() {
    local prereq_args=()
    if [ "$SET_FS_PROTECTED_REGULAR" = true ]; then
        prereq_args+=(--set-fs-protected-regular)
    fi
    "$PROJECT_ROOT/scripts/install_prerequisites.sh" "${prereq_args[@]}"
}

common_run_post_deploy_flow() {
    local orchestrator="$1"
    local host_ip="$2"
    local vm_creation_supported="${3:-true}"

    if [ "$DISCOVERY_METHOD" == "magellan" ]; then
        step "Running Magellan dynamic discovery..."
        export ORCHESTRATOR="$orchestrator"
        run_magellan_discovery "$host_ip"
    elif [ -n "$NODES_FILE" ]; then
        step "Registering hardware nodes from $NODES_FILE..."
        validate_nodes_file "$NODES_FILE"
        export ORCHESTRATOR="$orchestrator"
        register_hardware_nodes_from_file "$NODES_FILE" "$host_ip"
    fi

    if [ "$NUM_VMS" -gt 0 ]; then
        if [ "$vm_creation_supported" != "true" ]; then
            warn "VM creation via libvirt is not available on macOS."
            echo "Use ./scripts/register_hardware_node.sh to register physical nodes instead."
        elif [ "$DISCOVERY_METHOD" == "magellan" ]; then
            step "Creating $NUM_VMS VMs (Magellan discovery mode)..."
            create_vms_only "$NUM_VMS"
            step "Running Magellan discovery after VM creation..."
            export ORCHESTRATOR="$orchestrator"
            run_magellan_discovery "$host_ip"
        else
            step "Creating $NUM_VMS VMs..."
            export ORCHESTRATOR="$orchestrator"
            create_and_register_vms "$NUM_VMS" "$host_ip"
        fi
    fi
}

common_print_vm_instructions() {
    local vm_creation_supported="${1:-true}"

    if [ "$vm_creation_supported" != "true" ]; then
        echo "To register a hardware node:"
        echo "  ./scripts/register_hardware_node.sh <MAC_ADDRESS> <IP_ADDRESS> <COMPONENT_ID> <NID> <BMC_IP> <BMC_USER> <BMC_PASS>"
        echo ""
        echo "Note: VM creation via libvirt is not available on macOS."
        return 0
    fi

    if [ "$NUM_VMS" -gt 0 ]; then
        echo "To connect to the VM console, run:"
        for i in $(seq 0 $((NUM_VMS - 1))); do
            echo "  sudo virsh start --console virtual-compute-node-$i"
        done
    else
        echo "To create and boot a VM, run:"
        echo "  sudo ./scripts/create_vm.sh"
        echo "  sudo virsh start --console virtual-compute-node"
    fi
}
