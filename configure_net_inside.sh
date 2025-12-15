#!/bin/bash
set -e

MAC_ADDR=$1
IP_ADDR=$2
NETMASK="24"

echo "Inside Minikube: Configuring network..."
echo "Looking for MAC: $MAC_ADDR"

# Force PCI Rescan
echo 1 | tee /sys/bus/pci/rescan >/dev/null

# Wait a moment for device to appear
sleep 1

# Find interface
# We use ip -o link. Output format: "2: eth0: ..."
# grep case insensitive
INTERFACE_LINE=$(ip -o link | grep -i "$MAC_ADDR")

if [ -z "$INTERFACE_LINE" ]; then
    echo "Error: Interface with MAC $MAC_ADDR not found."
    ip link show
    exit 1
fi

# Extract interface name (field 2, remove colon)
INTERFACE=$(echo "$INTERFACE_LINE" | awk -F': ' '{print $2}')

if [ -z "$INTERFACE" ]; then
    echo "Error: Could not extract interface name."
    exit 1
fi

echo "Found interface: $INTERFACE"

# Bring Up
ip link set "$INTERFACE" up

# Assign IP if not already assigned
if ! ip addr show "$INTERFACE" | grep -q "$IP_ADDR"; then
    ip addr add "$IP_ADDR/$NETMASK" dev "$INTERFACE"
    echo "IP $IP_ADDR assigned to $INTERFACE."
else
    echo "IP $IP_ADDR already exists on $INTERFACE."
fi
