#!/bin/bash

echo "Initializing network"

run_cmd() {
    local node=$1
    shift
    local container=$(docker ps --format '{{.Names}}' | grep -i "$node" | head -n 1)
    
    if [ -z "$container" ]; then
        echo "ERROR: Container Docker for '$node' not found"
        return 1
    fi
    
    echo "Configuration on $node (container: $container)..."
    docker exec "$container" "$@"
}

# ------------------------------------------------ AS 100 (ROUTER CORE) ------------------------------------------------

run_cmd R101 ip addr add 1.0.0.1/32 dev lo
run_cmd R101 ip addr add 172.16.100.1/30 dev eth0
run_cmd R101 ip link set dev eth0 up
run_cmd R101 ip addr add 172.16.100.10/30 dev eth1
run_cmd R101 ip link set dev eth1 up
run_cmd R101 ip addr add 10.255.1.1/30 dev eth2
run_cmd R101 ip link set dev eth2 up

run_cmd R102 ip addr add 1.0.0.2/32 dev lo
run_cmd R102 ip addr add 172.16.100.2/30 dev eth0
run_cmd R102 ip link set dev eth0 up
run_cmd R102 ip addr add 172.16.100.5/30 dev eth1
run_cmd R102 ip link set dev eth1 up
run_cmd R102 ip addr add 10.255.3.1/30 dev eth2
run_cmd R102 ip link set dev eth2 up

run_cmd R103 ip addr add 1.0.0.3/32 dev lo
run_cmd R103 ip addr add 172.16.100.6/30 dev eth0
run_cmd R103 ip link set dev eth0 up
run_cmd R103 ip addr add 172.16.100.9/30 dev eth1
run_cmd R103 ip link set dev eth1 up
run_cmd R103 ip addr add 10.255.2.1/30 dev eth2
run_cmd R103 ip link set dev eth2 up

# ------------------------------------------------ CUSTOMER EDGE ------------------------------------------------

# CE1
run_cmd CE1 ip addr add 10.255.1.2/30 dev eth0
run_cmd CE1 ip link set dev eth0 up
run_cmd CE1 ip addr add 192.168.11.1/24 dev eth1
run_cmd CE1 ip link set dev eth1 up
run_cmd CE1 ip route add default via 10.255.1.1
run_cmd CE1 sysctl -w net.ipv4.ip_forward=1

# CE2
run_cmd CE2 ip addr add 10.255.2.2/30 dev eth0
run_cmd CE2 ip link set dev eth0 up
run_cmd CE2 ip addr add 192.168.22.1/24 dev eth1
run_cmd CE2 ip link set dev eth1 up

run_cmd CE2 ip link add link eth1 name eth1.32 type vlan id 32
run_cmd CE2 ip addr add 192.168.32.1/24 dev eth1.32
run_cmd CE2 ip link set dev eth1.32 up

run_cmd CE2 ip link add link eth1 name eth1.95 type vlan id 95
run_cmd CE2 ip addr add 192.168.95.1/24 dev eth1.95
run_cmd CE2 ip link set dev eth1.95 up
run_cmd CE2 ip route add default via 10.255.2.1
run_cmd CE2 sysctl -w net.ipv4.ip_forward=1

# CE3
run_cmd CE3 ip addr add 10.255.3.2/30 dev eth0
run_cmd CE3 ip link set dev eth0 up
run_cmd CE3 ip addr add 192.168.33.1/24 dev eth1
run_cmd CE3 ip link set dev eth1 up
run_cmd CE3 ip route add default via 10.255.3.1
run_cmd CE3 sysctl -w net.ipv4.ip_forward=1

# ------------------------------------------------ HOSTS, SWITCH AND SERVERS ------------------------------------------------

# RADIUS Server
run_cmd RADIUS ip addr add 192.168.33.10/24 dev eth0
run_cmd RADIUS ip link set dev eth0 up
run_cmd RADIUS ip route add default via 192.168.33.1

# eBPF Switch
run_cmd eBPF-1 ip link add name br0 type bridge vlan_filtering 1
run_cmd eBPF-1 ip link set dev eth0 master br0
run_cmd eBPF-1 ip link set dev eth1 master br0
run_cmd eBPF-1 ip link set dev eth2 master br0
run_cmd eBPF-1 ip link set dev eth0 up
run_cmd eBPF-1 ip link set dev eth1 up
run_cmd eBPF-1 ip link set dev eth2 up
run_cmd eBPF-1 ip link set br0 up
run_cmd eBPF-1 bash -c "echo 8 > /sys/class/net/br0/bridge/group_fwd_mask"
run_cmd eBPF-1 ip addr flush dev eth0 2>/dev/null || true
run_cmd eBPF-1 ip addr add 192.168.22.2/24 dev br0
run_cmd eBPF-1 ip route add default via 192.168.22.1
run_cmd eBPF-1 bridge vlan add dev eth0 vid 32
run_cmd eBPF-1 bridge vlan add dev eth0 vid 95

# Client B1 (VLAN 32)
run_cmd client-B1 ip addr add 192.168.32.10/24 dev eth0
run_cmd client-B1 ip link set dev eth0 up
run_cmd client-B1 ip route add default via 192.168.32.1

# Client B2 (VLAN 95)
run_cmd client-B2 ip addr add 192.168.95.10/24 dev eth0
run_cmd client-B2 ip link set dev eth0 up
run_cmd client-B2 ip route add default via 192.168.95.1

echo "IP initialization completed (Beware: Configure IP 192.168.11.10 on Client-A1 VM)"
