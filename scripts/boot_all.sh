#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Starting complete deploy"

"$SCRIPT_DIR/net_init.sh"

"$SCRIPT_DIR/boot_frr.sh"

echo -e "\nWaiting BGP convergence"
sleep 35

"$SCRIPT_DIR/boot_vpn.sh"

echo -e "\nWaiting VPN initialization"
sleep 10

"$SCRIPT_DIR/boot_radius.sh"
sleep 2

"$SCRIPT_DIR/deploy_ebpf.sh"
sleep 2

"$SCRIPT_DIR/boot_clients.sh"

echo "Complete deploy finished"

