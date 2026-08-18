#!/bin/bash

echo "Deploy eBPF/XDP architecture in GNS3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EBPF_DIR="$SCRIPT_DIR/../src/ebpf"

echo "Compiling eBPF programs"
(cd "$EBPF_DIR" && make > /dev/null 2>&1)
if [ $? -ne 0 ]; then
    echo "Error in compilation"
    exit 1
fi

SW_CT=$(docker ps --format '{{.Names}}' | grep -i "eBPF-1" | head -n 1)

echo "Injecting files into the switch ($SW_CT)"
docker exec -it $SW_CT mkdir -p /workspace/ebpf
docker cp "$EBPF_DIR/xdp_radius.o" $SW_CT:/workspace/ebpf/
docker cp "$EBPF_DIR/xdp_eap.o" $SW_CT:/workspace/ebpf/
docker cp "$EBPF_DIR/xdp_user.sh" $SW_CT:/workspace/ebpf/
docker cp "$EBPF_DIR/action.sh" $SW_CT:/workspace/ebpf/

echo "Mounting BPF filesystem and loading shared maps"
docker exec -it $SW_CT mkdir -p /sys/fs/bpf
docker exec -it $SW_CT mount -t bpf bpf /sys/fs/bpf 2>/dev/null || true

# Cleaning up old attachments
docker exec -it $SW_CT ip link set dev eth0 xdp off 2>/dev/null || true
docker exec -it $SW_CT ip link set dev eth1 xdp off 2>/dev/null || true
docker exec -it $SW_CT ip link set dev eth2 xdp off 2>/dev/null || true
docker exec -it $SW_CT bash -c "rm -f /sys/fs/bpf/xdp_radius /sys/fs/bpf/xdp_eap /sys/fs/bpf/identity_map /sys/fs/bpf/auth_map"

# Loading and pinning
docker exec -it $SW_CT bpftool prog loadall /workspace/ebpf/xdp_radius.o /sys/fs/bpf/xdp_radius pinmaps /sys/fs/bpf
docker exec -it $SW_CT bpftool prog loadall /workspace/ebpf/xdp_eap.o /sys/fs/bpf/xdp_eap pinmaps /sys/fs/bpf

# Attaching to interfaces
docker exec -it $SW_CT bpftool net attach xdp pinned /sys/fs/bpf/xdp_radius/xdp_radius_parser dev eth0
docker exec -it $SW_CT bpftool net attach xdp pinned /sys/fs/bpf/xdp_eap/xdp_eapol_parser dev eth1
docker exec -it $SW_CT bpftool net attach xdp pinned /sys/fs/bpf/xdp_eap/xdp_eapol_parser dev eth2

echo "Starting the userspace daemon in the background"
docker exec -it $SW_CT chmod +x /workspace/ebpf/xdp_user.sh
docker exec -it $SW_CT chmod +x /workspace/ebpf/action.sh
docker exec -d $SW_CT bash /workspace/ebpf/xdp_user.sh

echo "Deploy completed"
