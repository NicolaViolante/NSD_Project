# NSD Project

This repository contains the final project for the **Network and System Defence** course (A.Y. 2025/2026). The project implements a secure, distributed corporate network infrastructure combining dynamic routing, VPN overlays, Mandatory Access Control, and a custom eBPF-based Data Plane security enforcement.

The network architecture is built upon the following logical blocks:
+ **AS100 (Provider Core):** The backbone network running OSPF and iBGP to interconnect the customer's sites
+ **VPN Overlay:** An OpenVPN Hub-And-Spoke topology secururing the communications between the corporate sites over the provider network
+ **Site 1 (MAC Enforcement):** A remote site containing a sensitive endpoint (Client-A1) hardened with a custom AppArmor profile
+ **Site 2 & Site 3 (802.1X & eBPF Security):** A secure branch setup where client access is authenticated via IEEE 802.1X (RADIUS) and dynamically enforced at Layer 2 using XDP/eBPF programs and ebtables

During the design phase, a discrepancy in the original assignment text was identified regarding the naming of the Customer Edge routers for Site 2 and Site 3. To ensure architectural coherence, this project strictly follows the visual diagram provided in the assignment.

## AS 100 (Provider Core Routing)
The AS100 backbone acts as the Internet Service Provider (ISP) connecting the three customer sites. It is composed of three Core Routers (R101, R102, R103) running Free Range Routing (FRR).
### Network initialization
To ensure automation and portability, the network interfaces and IP addresses are not statically bound to hardcoded Docker container names. Instead, a custom bash script dynamically resolves the containers running in GNS3 and applies the /30 point-to-point links and /32 loopback addresses.
```sh
run_cmd() {
    local node=$1
    shift
    local container=$(docker ps --format '{{.Names}}' | grep -i "$node" | head -n 1)
    
    if [ -z "$container" ]; then
        echo "[-] ERROR: Container Docker for '$node' not found"
        return 1
    fi
    
    echo "[*] Configuration on $node (container: $container)..."
    docker exec "$container" "$@"
}

# ------------------------------------------------ AS 100 (ROUTING CORE) ------------------------------------------------

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
```
### Dynamic Routing (OSPF & iBGP)
The routing architecture inside the provider network is based on two protocols:
1. **OSPF**: Used as the Interior Gateway Protocol (IGP) to ensure reachability between the loopback addresses of the core routers over the internal /30 links
2. **iBGP:** Used to exchange the external customer-facing networks (10.255.x.0/30)
A full-mesh iBGP peering is established using the routers' loopback addresses (update-source) to guarantee session resiliency. Furthermore, the next-hop-self directive is strictly enforced so that routes injected into BGP are recursively resolvable via OSPF.
###### `R101_frr.conf`
```
frr defaults datacenter
hostname R101
service integrated-vtysh-config
!
router ospf
 ospf router-id 1.0.0.1
 network 1.0.0.1/32 area 0
 network 172.16.100.0/30 area 0
 network 172.16.100.8/30 area 0
!
router bgp 100
 bgp router-id 1.0.0.1
 neighbor 1.0.0.2 remote-as 100
 neighbor 1.0.0.2 update-source 1.0.0.1
 neighbor 1.0.0.3 remote-as 100
 neighbor 1.0.0.3 update-source 1.0.0.1
 !
 address-family ipv4 unicast
  network 10.255.1.0/30
  neighbor 1.0.0.2 next-hop-self
  neighbor 1.0.0.3 next-hop-self
 exit-address-family
!
```
###### `R102_frr.conf`
```
frr defaults datacenter
hostname R102
service integrated-vtysh-config
!
router ospf
 ospf router-id 1.0.0.2
 network 1.0.0.2/32 area 0
 network 172.16.100.0/30 area 0
 network 172.16.100.4/30 area 0
!
router bgp 100
 bgp router-id 1.0.0.2
 neighbor 1.0.0.1 remote-as 100
 neighbor 1.0.0.1 update-source 1.0.0.2
 neighbor 1.0.0.3 remote-as 100
 neighbor 1.0.0.3 update-source 1.0.0.2
 !
 address-family ipv4 unicast
  network 10.255.3.0/30
  neighbor 1.0.0.1 next-hop-self
  neighbor 1.0.0.3 next-hop-self
 exit-address-family
!
```
###### `R103_frr.conf`
```
frr defaults datacenter
hostname R103
service integrated-vtysh-config
!
router ospf
 ospf router-id 1.0.0.3
 network 1.0.0.3/32 area 0
 network 172.16.100.4/30 area 0
 network 172.16.100.8/30 area 0
!
router bgp 100
 bgp router-id 1.0.0.3
 neighbor 1.0.0.1 remote-as 100
 neighbor 1.0.0.1 update-source 1.0.0.3
 neighbor 1.0.0.2 remote-as 100
 neighbor 1.0.0.2 update-source 1.0.0.3
 !
 address-family ipv4 unicast
  network 10.255.2.0/30
  neighbor 1.0.0.1 next-hop-self
  neighbor 1.0.0.2 next-hop-self
 exit-address-family
!
```
