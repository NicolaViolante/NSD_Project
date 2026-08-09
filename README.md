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
#!/bin/bash

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
## Overlay VPN
To securely interconnect the three customer sites across the AS100 provider network, an overlay VPN is implemented using OpenVPN. The architecture strictly follows a Hub-and-Spoke topology:
+ **CE3 (Site 3):** Acts as the central VPN server (hub)
+ **CE1 (Site 1) & CE2 (Site 2):** Act as VPN clients (spokes) connecting to the hub.
### PKI Generation
A custom bash script automates the creation of the Public Key Infrastructure using `easy-rsa`. It generates the root CA, the server/client certificates, and the Diffie-Hellman parameters. Additionally, it creates a `ta.key` used for tls-auth, which acts as an HMAC firewall to drop unauthenticated packets.
`pki_gen.sh`
```sh
#!/bin/bash

EASYRSA_DIR="/usr/share/easy-rsa/3"
OUT_DIR="../vpn-keys"

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

$EASYRSA_DIR/easyrsa init-pki > /dev/null
export EASYRSA_BATCH=1 
$EASYRSA_DIR/easyrsa build-ca nopass > /dev/null
$EASYRSA_DIR/easyrsa build-server-full CE3 nopass > /dev/null
$EASYRSA_DIR/easyrsa build-client-full CE1 nopass > /dev/null
$EASYRSA_DIR/easyrsa build-client-full CE2 nopass > /dev/null
$EASYRSA_DIR/easyrsa gen-dh > /dev/null
openvpn --genkey secret pki/ta.key
```
### Hub configuration (CE3)
The Hub router manages the 192.168.100.0/24 VPN subnet. It relies on the client-to-client directive to allow Spoke-to-Spoke communication and pushes the required static routes to all clients so they know how to reach the other sites.
`server.conf`
```
port 1194
proto udp
dev tun0

ca /etc/openvpn/certs/ca.crt
cert /etc/openvpn/certs/CE3.crt
key /etc/openvpn/certs/CE3.key
dh /etc/openvpn/certs/dh.pem
tls-auth /etc/openvpn/certs/ta.key 0

server 192.168.100.0 255.255.255.0
topology subnet

route 192.168.11.0 255.255.255.0
route 192.168.22.0 255.255.255.0

push "route 192.168.33.0 255.255.255.0"
push "route 192.168.11.0 255.255.255.0"
push "route 192.168.22.0 255.255.255.0"

client-config-dir /etc/openvpn/ccd
client-to-client

keepalive 10 120
cipher AES-256-GCM
persist-key
persist-tun
status /var/log/openvpn-status.log
verb 3
```
### Internal routing (client config directory)
For the Hub-and-Spoke routing to work properly, OpenVPN's internal routing table must know which LAN sits behind which Spoke. This is achieved using iroute directives inside the client config directory (ccd).
`ccd/CE1`
```
iroute 192.168.11.0 255.255.255.0
```
`ccd/CE2`
```
iroute 192.168.22.0 255.255.255.0
```
### Spoke configurations (CE1 & CE2)
The clients connect to the Hub using UDP port 1194. Security is enforced using strong AEAD encryption and the `remote-cert-tls server directive`, which mitigates MITM attacks by verifying the server's certificate extension.
`client-CE1.conf`
```
client
dev tun0
proto udp
remote 10.255.3.2 1194
resolv-retry infinite
nobind
persist-key
persist-tun

ca /etc/openvpn/certs/ca.crt
cert /etc/openvpn/certs/CE1.crt
key /etc/openvpn/certs/CE1.key
tls-auth /etc/openvpn/certs/ta.key 1

remote-cert-tls server
cipher AES-256-GCM
verb 3
```
`client-CE2.conf`
```
client
dev tun0
proto udp
remote 10.255.3.2 1194
resolv-retry infinite
nobind
persist-key
persist-tun

ca /etc/openvpn/certs/ca.crt
cert /etc/openvpn/certs/CE2.crt
key /etc/openvpn/certs/CE2.key
tls-auth /etc/openvpn/certs/ta.key 1

remote-cert-tls server
cipher AES-256-GCM
verb 3
```
