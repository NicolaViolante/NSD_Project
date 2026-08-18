# NSD Project

This repository contains the final project for the **Network and System Defence** course (A.Y. 2025/2026). The project implements a secure, distributed corporate network infrastructure combining dynamic routing, VPN overlays, Mandatory Access Control, and a custom eBPF-based Data Plane security enforcement.

The network architecture is built upon the following logical blocks:
+ **AS100 (Provider Core):** The backbone network running OSPF and iBGP to interconnect the customer's sites
+ **VPN Overlay:** An OpenVPN Hub-And-Spoke topology secururing the communications between the corporate sites over the provider network
+ **Site 1 (MAC Enforcement):** A remote site containing a sensitive endpoint (Client-A1) hardened with a custom AppArmor profile
+ **Site 2 & Site 3 (802.1X & eBPF Security):** A secure branch setup where client access is authenticated via IEEE 802.1X (RADIUS) and dynamically enforced at Layer 2 using XDP/eBPF programs and ebtables

During the design phase, a discrepancy in the original assignment text was identified regarding the naming of the Customer Edge routers for Site 2 and Site 3. To ensure architectural coherence, this project strictly follows the visual diagram provided in the assignment.

## AS 100 (Provider core routing)
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
##### `pki_gen.sh`
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
##### `server.conf`
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
route 192.168.32.0 255.255.255.0
route 192.168.95.0 255.255.255.0

push "route 192.168.33.0 255.255.255.0"
push "route 192.168.11.0 255.255.255.0"
push "route 192.168.22.0 255.255.255.0"
push "route 192.168.32.0 255.255.255.0"
push "route 192.168.95.0 255.255.255.0"

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
##### `ccd/CE1`
```
iroute 192.168.11.0 255.255.255.0
```
##### `ccd/CE2`
```
iroute 192.168.22.0 255.255.255.0
iroute 192.168.32.0 255.255.255.0
iroute 192.168.95.0 255.255.255.0
```
### Spoke configurations (CE1 & CE2)
The clients connect to the Hub using UDP port 1194. Security is enforced using strong AEAD encryption and the `remote-cert-tls server directive`, which mitigates MITM attacks by verifying the server's certificate extension.
##### `client-CE1.conf`
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
##### `client-CE2.conf`
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

## VPN Site 1 (Mandatory access control)
VPN Site 1 consists of a Customer Edge router (CE1) and a highly sensitive endpoint (Client-A1). Because implementing kernel-level Mandatory Access Control (MAC) policies inside standard Docker containers can be problematic or require complex privileged modes, Client-A1 is deployed as a fully virtualized VMware machine (Lubuntu) directly connected to the GNS3 topology.
### Client A1 network initialization
To ensure that traffic routes correctly through the VPN overlay rather than escaping through the host's default NAT interface, the network is isolated and initialized manually on the VM using `nmcli` and `ip route`.
```
sudo nmcli con add con-name "LAN-GNS3" ifname ens34 type ethernet ip4 192.168.11.10/24 gw4 192.168.11.1
sudo nmcli con up "LAN-GNS3"

sudo ip route del default via 172.16.113.2 dev ens33
sudo ip route replace default via 192.168.11.1 dev ens34 metric 100
```
### DAC vs MAC Paradigm & vulnerable setup 
The chosen non-trivial program to confine is the **NGINX** web server. As a network-facing daemon responsible for parsing untrusted HTTP inputs, it represents a highly critical attack surface.
To explicitly demonstrate the superiority of mandatory access control over discretionary access control, the `setup.sh` script intentionally misconfigures NGINX to run as the root user instead of the unprivileged `www-data` user. Under normal Linux DAC rules, the root user has unrestricted access to the entire filesystem.
```sh
#!/bin/bash
echo "Preparing vulnerable environment"

sudo sed -i 's/user www-data;/user root;/g' /etc/nginx/nginx.conf

sudo mkdir -p /root/.ssh
echo "Private secret key" | sudo tee /root/.ssh/id_rsa >/dev/null
sudo chmod 600 /root/.ssh/id_rsa
echo -e '#!/bin/bash\necho "Malware executed"' | sudo tee /tmp/malware.sh >/dev/null
sudo chmod +x /tmp/malware.sh
echo "Test page working" | sudo tee /var/www/html/index.html >/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo cp "$SCRIPT_DIR/nginx_vulnerable.conf" /etc/nginx/sites-available/default
sudo aa-disable /usr/sbin/nginx >/dev/null 2>&1 || true
sudo systemctl restart nginx
sleep 2
echo "Environment ready. Nginx is vulnerable"
```
To simulate an attacker exploiting the web server, the loaded NGINX configuration purposely introduces severe vulnerabilities:
+ **Path Traversal:** The alias directive exposes critical OS files directly to the web interface (`/hacked_shadow` and `/hacked_ssh`)
+ **Arbitrary Write:** The `dav_methods` PUT directive allows an attacker to upload arbitrary files (e.g., backdoors or altered configurations) directly into the `/etc/` system folder
##### `nginx_vulnerable.conf`
```
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.html;
    server_name _;

    location / { try_files $uri $uri/ =404; }

    location /hacked_shadow { alias /etc/shadow; }
    location /hacked_ssh { alias /root/.ssh/id_rsa; }

    location /hacked_etc/ {
        alias /etc/;
        dav_methods PUT;
        create_full_put_path on;
    }
}

```
By applying AppArmor, we enforce a Zero-Trust perimeter: even if an attacker exploits these misconfigurations or achieves remote code execution as root, they will still be completely contained by the MAC profile.
### AppArmor profile and security objectives
To mitigate the vulnerabilities introduced in the setup, a custom AppArmor profile is tailored specifically for the `/usr/sbin/nginx` executable. The profile strictly defines what NGINX is allowed to read, write, and execute for its normal operations.

More importantly, the profile enforces 4 explicit security objectives. To guarantee that any violation attempt is actively logged by the kernel for evidence gathering, the `audit deny` directive is systematically used instead of a simple `deny`.

+ **Objective 1 (Deny OS credentials read):** `audit deny /etc/{passwd,shadow,gshadow} r` prevents an attacker from dumping password hashes or user enumerations for offline cracking. This is a critical mitigation since NGINX runs as root and the configuration exposes `/etc/shadow` via path traversal
+ **Objective 2 (Deny SSH keys read/write/execute):** `audit deny /{root,home/*}/.ssh/** rwlkx` prevents the theft or manipulation of private SSH keys
+ **Objective 3 (Config Integrity):** `audit deny /etc/** w` ensures that system configuration files cannot be modified. Even though the WebDAV PUT vulnerability allows arbitrary uploads, this rule stops the attacker from dropping backdoors or altering system behavior in the `/etc/` directory
+ **Objective 4 (Deny execution from world-writable paths):** `audit deny /tmp/** x` and `audit deny /var/tmp/** x` prevent the execution of malicious payloads, scripts, or reverse shells dropped into temporary, world-writable directories
```
#include <tunables/global>

/usr/sbin/nginx {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  #include <abstractions/nis>

  capability net_bind_service,
  capability setgid,
  capability setuid,
  capability dac_override,

  # Objective 1
  audit deny /etc/shadow r,
  audit deny /etc/passwd r,
  audit deny /etc/gshadow r,

  # Objective 2
  audit deny /home/*/.ssh/** rwlkx,
  audit deny /root/.ssh/** rwlkx,

  # Objective 3
  audit deny /etc/** w,

  # Objective 4
  audit deny /tmp/** x,
  audit deny /var/tmp/** x,

  # Allowed resources
  /usr/sbin/nginx mr,
  /etc/nginx/** r,
  /var/log/nginx/** w,
  /var/www/html/ r,
  /var/www/html/** r,
  /run/nginx.pid rw,
  /var/lib/nginx/** rw,
  /usr/share/nginx/modules-available/*.conf r,
}
```
### Enforcement and testing
The AppArmor profile is parsed and loaded into enforce mode using the `enable_aa.sh` script. It utilizes standard AppArmor utilities (`apparmor_parser` and `aa-enforce`) to ensure the MAC policy is strictly applied to the NGINX daemon.
```sh
#!/bin/bash
echo "Loading AppArmor profile"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo cp "$SCRIPT_DIR/usr.sbin.nginx" /etc/apparmor.d/usr.sbin.nginx
sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.nginx
sudo aa-enforce /usr/sbin/nginx >/dev/null 2>&1
sudo systemctl restart nginx
sleep 2

echo "Profile loaded. Loaded profiles:"
sudo aa-status | grep -i nginx
```
To validate the configuration and provide the evidence required by the project specifications, the `test.sh` script automates a series of attacks against the server. The script utilizes a dual-testing approach:
+ **HTTP Requests (curl):** Used to test the web-facing restrictions
  + **The Allowed Action (Success):** To prove that the MAC profile does not break the legitimate intended purpose of the software, the script performs a standard HTTP request to the root directory. Because the AppArmor profile explicitly allows reading `/var/www/html/`, the kernel permits the action, returning an `HTTP 200`
  + **The Forbidden Actions (Blocked):** When the script attempts to exploit the path traversal vulnerabilities or the WebDAV arbitrary write, the Linux kernel intercepts the syscalls. Even though NGINX is running as root, AppArmor blocks the access and forces NGINX to return an `HTTP 403` error
+ **Context Execution (aa-exec):** Used to simulate an attacker who has successfully exploited NGINX and achieved a reverse shell. The script uses `sudo aa-exec -p /usr/sbin/nginx` to force a command to run under the confined NGINX profile context. This proves that executing malicious scripts in `/tmp` is actively blocked by the kernel, successfully demonstrating Objective 4

Finally, the script automatically extracts the undeniable evidence of this MAC enforcement from the kernel audit logs, searching for the DENIED keywords generated by the profile's audit directives.
```sh
#!/bin/bash
echo "Starting test"

sudo dmesg -c > /dev/null 2>&1

if sudo aa-status 2>/dev/null | grep -q "/usr/sbin/nginx"; then
    echo "AppArmor profile active. Using aa-exec for local tests."
    EXEC_CMD="sudo aa-exec -p /usr/sbin/nginx"
    MAC_ACTIVE=1
else
    echo "No AppArmor profile active. Using sudo for local tests (DAC bypass)."
    EXEC_CMD="sudo"
    MAC_ACTIVE=0
fi

echo ""
echo "Allowed action (Default Web Page):"
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost/

echo "Obj 1 e 2: Read critical files (Shadow e SSH Key):"
curl -s -o /dev/null -w "/etc/shadow: HTTP %{http_code}\n" http://localhost/hacked_shadow
curl -s -o /dev/null -w "SSH Key: HTTP %{http_code}\n" http://localhost/hacked_ssh

echo "Obj 3: Write in /etc (WebDAV PUT):"
curl -s -X PUT -d "Pwned" -o /dev/null -w "HTTP %{http_code}\n" http://localhost/hacked_etc/pwned.txt
if [ -f /etc/pwned.txt ]; then 
    echo "pwned.txt wrote in /etc"
    sudo rm -f /etc/pwned.txt
fi

echo "Obj 4: Execute script from /tmp:"
$EXEC_CMD /tmp/malware.sh 2>&1


# Log se MAC attivo
if [ "$MAC_ACTIVE" -eq 1 ]; then
    echo "KERNEL LOG APPARMOR (DENIED) ==="
    sudo dmesg | grep -i apparmor | grep -i "DENIED" | grep -vE "tty|pts" | tail -n 30
fi
```
## VPN Site 3 (RADIUS authentication server)
VPN Site 3 acts as the Hub for the overlay network and hosts the central FreeRADIUS server. Its role is to process Access-Request packets coming from the 802.1X Authenticator (the eBPF switch located in site 2) over the OpenVPN tunnel and to enforce the dynamic VLAN assignment.
### RADIUS clients configuration
To secure the authentication infrastructure, the RADIUS server is configured to accept requests exclusively from the eBPF switch (192.168.22.2). This is defined in the `clients.conf` file using a shared secret.
```
client 192.168.22.2 {
    secret = sharedsecret123
    shortname = eBPF-Switch
}
```
### Authentication and VLAN enforcement
The access policy is defined in the users configuration file. Instead of just returning an Access-Accept message, the RADIUS server is configured to append specific tunnel attributes to the response.

When B1 or B2 successfully authenticate, the server dictates their network segmentation by passing the `Tunnel-Private-Group-ID` attribute (VLAN 32 for B1, VLAN 95 for B2). This specific attribute will later be intercepted and parsed by the eBPF data plane in Site 2.
```
B1 Cleartext-Password := "passwordB1"
    Service-Type = Framed-User,
    Tunnel-Type = 13,
    Tunnel-Medium-Type = 6,
    Tunnel-Private-Group-ID = 32

B2 Cleartext-Password := "passwordB2"
    Service-Type = Framed-User,
    Tunnel-Type = 13,
    Tunnel-Medium-Type = 6,
    Tunnel-Private-Group-ID = 95
```
## VPN Site 2 (802.1X & eBPF)
VPN Site 2 contains a customer edge router, an eBPF-enabled layer 2 switch, and two clients. The switch acts as the 802.1X Authenticator for the local network, serving the two clients and communicating with the central RADIUS server in Site 3 through the OpenVPN tunnel.
### 802.1X supplicants and authenticator
To initiate the authentication process, the network utilizes the IEEE 802.1X standard over a wired connection.
### The Authenticator (hostapd)
The eBPF switch runs hostapd configured with the wired driver on its br0 bridge interface. It intercepts EAPOL frames sent by the clients and securely proxies them to the RADIUS server. Crucially, the configuration enables the ctrl_interface directive: this exposes a control socket that will be essential for our custom userspace application to listen for successful authentication events.
`hostapd.conf`
```
interface=br0
driver=wired
ieee8021x=1
use_pae_group_addr=1
own_ip_addr=192.168.22.2
auth_server_addr=192.168.33.10
auth_server_port=1812
auth_server_shared_secret=sharedsecret123
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
```
### The Supplicants (wpa_supplicant)
Client-B1 and Client-B2 act as the supplicants. They run wpa_supplicant configured to trigger wired 802.1X authentication. The clients provide their respective identities and passwords using the EAP-MD5 challenge.
`wpa_supplicant-B1.conf`
```
ap_scan=0
network={
    key_mgmt=IEEE8021X
    eap=MD5
    identity="B1"
    password="passwordB1"
    eapol_flags=0
}
```
`wpa_supplicant-B2.conf`
```
ap_scan=0
network={
    key_mgmt=IEEE8021X
    eap=MD5
    identity="B2"
    password="passwordB2"
    eapol_flags=0
}
```
### The eBPF Data Plane (XDP Programs)
The core requirement of the Data Plane security is to parse RADIUS and 802.1X messages in the kernel to extract authentication information and the assigned VLAN.

However, a major architectural challenge exists: the final RADIUS Access-Accept message contains the Username and the VLAN, but it does not contain the client's MAC address. To dynamically assign the VLAN to a physical port, we need to bridge this information gap.

This is solved using two specialized eBPF/XDP programs that communicate via shared BPF maps defined in `xdp_common.h`.
```
#ifndef __XDP_COMMON_H
#define __XDP_COMMON_H

#include <linux/types.h>

#define MAX_ENTRIES 16
#define ID_MAX 8  // Lunghezza massima username

// Auth map (w: xdp_radius.c r: action.sh)
struct mac_address {
    __u8 mac[6];
};

struct auth_info {
    __u32 vlan_id;
    __u8 is_authenticated;
};

// Identity map (w: xdp_eap.c r: xdp_radius.c)
struct identity_key {
    char username[ID_MAX];
};

struct identity_claim {
    struct mac_address client_mac;
};

#endif
```
### Identity tracking (xdp_eap.c)
The first XDP program intercepts EAPOL frames coming from the clients before they reach the hostapd authenticator. It specifically targets the EAP Response/Identity packets. When a client sends its username, the XDP program extracts it and maps it to the client's Source MAC address. This state is saved in a pinned BPF map called `identity_map`.
```c
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>
#include "xdp_common.h"

#ifndef ETH_P_PAE
#define ETH_P_PAE 0x888E // Ethertype standard per EAPOL
#endif

struct eapol_hdr {
    __u8 version;
    __u8 type;
    __be16 length;
} __attribute__((packed));

struct eap_hdr {
    __u8 code;
    __u8 id;
    __be16 length;
    __u8 type;
} __attribute__((packed));

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, MAX_ENTRIES);
    __type(key, struct identity_key);
    __type(value, struct identity_claim);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} identity_map SEC(".maps");

SEC("xdp")
int xdp_eapol_parser(struct xdp_md *ctx) {
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return XDP_PASS;

    if (eth->h_proto == bpf_htons(ETH_P_PAE)) {
        struct eapol_hdr *eapol = (void *)(eth + 1);
        if ((void *)(eapol + 1) > data_end) return XDP_PASS;

        // EAP Packet = type 0
        if (eapol->type == 0) {
            struct eap_hdr *eap = (void *)(eapol + 1);
            if ((void *)(eap + 1) > data_end) return XDP_PASS;

            // EAP Response = code 2, Identity = type 1
            if (eap->code == 2 && eap->type == 1) {
                struct identity_key key = {0};
                struct identity_claim claim = {0};

                __builtin_memcpy(claim.client_mac.mac, eth->h_source, 6);

                // Il payload dell'identità inizia subito dopo l'header EAP
                void *id_ptr = (void *)(eap + 1);
                int id_len = bpf_ntohs(eap->length) - 5;
                
                if (id_len > 0) {
                    #pragma unroll
                    for (int i = 0; i < ID_MAX; i++) {
                        if (i < id_len && (void *)id_ptr + i + 1 <= data_end) {
                            key.username[i] = *((char *)id_ptr + i);
                        }
                    }
                    bpf_map_update_elem(&identity_map, &key, &claim, BPF_ANY);
                    bpf_printk("XDP_EAP: Saved username '%s' associated to MAC %02x:%02x\n", 
                               key.username, eth->h_source[4], eth->h_source[5]);
                }
            }
        }
    }
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```
### RADIUS parsing and correlation (xdp_prog_kern.c)
The second XDP program intercepts the UDP packets returning from the RADIUS server. It searches for Access-Accept messages and iterates through the RADIUS attributes to extract two pieces of data:
+ User-Name (Type 1)
+ Tunnel-Private-Group-ID (Type 81)
Once both are extracted, the program performs the crucial eBPF Correlation. It looks up the Username in the `identity_map` to retrieve the associated MAC address. Finally, it creates the ultimate security decision (MAC -> VLAN) and stores it in the `auth_map`, where it awaits the userspace application.
```c
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>
#include "xdp_common.h"

#define RADIUS_PORT 1812
#define RADIUS_CODE_ACCESS_ACCEPT 2
#define RADIUS_ATTR_USER_NAME 1
#define RADIUS_ATTR_TUNNEL_PVT_GRP_ID 81

struct radius_hdr {
    __u8 code;
    __u8 id;
    __be16 length;
    __u8 authenticator[16];
} __attribute__((packed));

struct radius_attr {
    __u8 type;
    __u8 length;
} __attribute__((packed));

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, MAX_ENTRIES);
    __type(key, struct identity_key);
    __type(value, struct identity_claim);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} identity_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, MAX_ENTRIES);
    __type(key, struct mac_address);
    __type(value, struct auth_info);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} auth_map SEC(".maps");

SEC("xdp")
int xdp_radius_parser(struct xdp_md *ctx) {
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return XDP_PASS;
    if (eth->h_proto != bpf_htons(ETH_P_IP)) return XDP_PASS;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end) return XDP_PASS;
    if (ip->protocol != IPPROTO_UDP) return XDP_PASS;

    struct udphdr *udp = (void *)ip + (ip->ihl * 4);
    if ((void *)(udp + 1) > data_end) return XDP_PASS;
    if (udp->source != bpf_htons(RADIUS_PORT)) return XDP_PASS;

    struct radius_hdr *rad = (void *)(udp + 1);
    if ((void *)(rad + 1) > data_end) return XDP_PASS;

    if (rad->code == RADIUS_CODE_ACCESS_ACCEPT) {
        void *attr_ptr = (void *)(rad + 1);
        struct identity_key key = {0};
        __u32 vlan_id = 0;
        int found_user = 0;
        
        #pragma unroll
        for (int i = 0; i < 20; i++) {
            struct radius_attr *attr = attr_ptr;
            if ((void *)(attr + 1) > data_end) break;
            if (attr->length < 2) break;
            if ((void *)attr + attr->length > data_end) break;

            // Username
            if (attr->type == RADIUS_ATTR_USER_NAME) {
                __u8 *val = (__u8 *)(attr + 1);
                int name_len = attr->length - 2;
                #pragma unroll
                for (int j = 0; j < ID_MAX; j++) {
                    if (j < name_len && (void *)(val + j + 1) <= data_end) {
                        key.username[j] = val[j];
                    }
                }
                found_user = 1;
            }
            // VLAN ID
            else if (attr->type == RADIUS_ATTR_TUNNEL_PVT_GRP_ID) {
                __u8 *val = (__u8 *)(attr + 1);
                if ((void *)(val + 1) <= data_end) {
                    vlan_id = val[0] - '0';
                    if ((void *)(val + 2) <= data_end && val[1] >= '0' && val[1] <= '9') {
                        vlan_id = (vlan_id * 10) + (val[1] - '0');
                    }
                }
            }
            attr_ptr += attr->length;
        }

        // Correlazione
        if (found_user && vlan_id != 0) {
            struct identity_claim *claim = bpf_map_lookup_elem(&identity_map, &key);
            if (claim) {
                struct auth_info info = {
                    .vlan_id = vlan_id,
                    .is_authenticated = 1
                };
                bpf_map_update_elem(&auth_map, &claim->client_mac, &info, BPF_ANY);
                bpf_printk("XDP_RADIUS: Correlation OK! User '%s' -> VLAN %d\n", key.username, vlan_id);
                
                bpf_map_delete_elem(&identity_map, &key);
            }
        }
    }
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```
### Userspace enforcer (Dynamic VLAN & Security)
While the XDP programs perform packet parsing and logic correlation at the kernel level, a userspace component is required to apply the actual system changes (VLAN tagging and MAC filtering).
### Zero-Trust default state (xdp_user.sh)
The `xdp_user.sh` script initializes the environment by flushing any previous ebtables rules and enforcing a strict Zero-Trust policy.

The default policy for the **FORWARD** chain is set to **DROP**, meaning no traffic is allowed to traverse the switch. It then starts hostapd_cli in daemon mode, instructing it to listen for 802.1X events on br0 and trigger the `action.sh` script whenever an event occurs.
```sh
#!/bin/bash
echo "XDP userspace app"
ebtables -t filter -F
ebtables -t filter -P FORWARD DROP
hostapd_cli -i br0 -a /workspace/ebpf/action.sh
```
### The action script (action.sh)
When a client successfully authenticates, hostapd fires an **AP-STA-CONNECTED** event, passing the client's MAC address to the `action.sh` script. The script then performs the following operations:
+ **Map lookup:** It uses a Python snippet calling bpftool to read the pinned BPF map. It searches for the given MAC address to retrieve the dynamically assigned VLAN ID
+ **MAC authorization:** It dynamically inserts **ACCEPT** rules into ebtables for that specific MAC address, allowing the authenticated client to bypass the default DROP policy
+ **Physical port resolution:** It queries the Linux Bridge Forwarding Database to find out exactly on which physical port the MAC address is connected
+ **Dynamic VLAN assignment:** Finally, it uses the bridge vlan add command to configure the switch port as an untagged access port for the retrieved VLAN
```sh
#!/bin/bash
exec >> /tmp/action.log 2>&1

IFACE=$1
EVENT=$2
MAC=$3

if [[ "$EVENT" == *"AP-STA-CONNECTED"* ]]; then
    
    if [ -z "$MAC" ]; then
         exit 0
    fi

    echo "Usefull event detected ($EVENT) for mac: $MAC on $IFACE"
    
    VLAN=$(python3 -c "
import json, sys, subprocess
try:
    out = subprocess.check_output(['bpftool', 'map', 'dump', 'pinned', '/sys/fs/bpf/auth_map', '-j']).decode('utf-8')
    data = json.loads(out)
    mac_parts = [int(x, 16) for x in '$MAC'.split(':')]
    
    for entry in data:
        if 'formatted' in entry:
            fmt = entry['formatted']
            if fmt['key']['mac'] == mac_parts:
                print(fmt['value']['vlan_id'])
                sys.exit(0)
except Exception as e:
    pass
print('')
")
    
    if [ -z "$VLAN" ] || [ "$VLAN" == "0" ]; then
        echo "Error, mac not found in auth_map or parsing error"
        exit 1
    fi
    
    echo "Vlan $VLAN retrived via eBPF map"
    
    # Sblocco Ebtables
    echo "Authorizing MAC on ebtables"
    ebtables -t filter -I FORWARD -s "$MAC" -j ACCEPT
    ebtables -t filter -I FORWARD -d "$MAC" -j ACCEPT
    
    echo "Searching physical port for mac $MAC in FDB"
    
    PORT=$(bridge fdb show | grep -i "$MAC" | grep -v "self" | head -n 1 | awk '{print $3}')
    
    if [ -z "$PORT" ]; then
        echo "Mac $MAC not found in FDB. Fallback to default port br0."
        PORT="br0"
    else
        echo "Found mac $MAC on interface: $PORT"
    fi
    
    echo "Applying vlan $VLAN on port $PORT"
    bridge vlan add dev "$PORT" vid "$VLAN" pvid untagged
    
    echo "Data plane access granted"
fi
```
## Deployment and automation
To ensure the reproducibility of the entire infrastructure without manual intervention, a suite of bash scripts has been developed in the `scripts/` directory. These scripts orchestrate the deployment of routing protocols, VPN overlays, and the data plane security mechanisms.
### eBPF compilation and injection
The `deploy_ebpf.sh` script automates the full lifecycle of the eBPF Data Plane on the switch.

First, it locally triggers the Makefile to compile the C programs into BPF object files (.o). Once compiled, it pushes both the object files and the userspace shell scripts into the target Docker container.

The most critical part of the script is the BPF map pinning. To allow the two XDP programs (in the kernel) and the Python script (in userspace) to share the same memory states, the script mounts the `bpf` virtual filesystem. It then uses `bpftool` to load the programs and explicitly pin the maps to `/sys/fs/bpf`.

Finally, `bpftool net attach` hooks the parsers to the correct physical interfaces, and the userspace orchestrator is spawned in the background.
```sh
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
```
### Network initialization
While the AS100 core routing setup was discussed in the architectural overview, the `net_init.sh` script does much more than assigning IP addresses to the core routers. It fully provisions the logical interfaces for the entire topology:
+ Configures the IPs and default routes for the Customer edges, enabling kernel IPv4 forwarding.
+ It configures the VLAN sub-interfaces on the CE2 router to act as default gateways for the segmented clients
+ It configures the eBPF-1 switch by creating the br0 bridge, enabling vlan_filtering, and importantly, applying the `group_fwd_mask=8` directive. This specific kernel parameter is required to allow the Linux bridge to forward EAPOL frames to the hostapd authenticator
```sh
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
```
### Core routing injection
To deploy the OSPF and iBGP protocols without manual configuration, the `boot_frr.sh` script iterates over the core routers. It uses docker cp to push the specific FRR configuration files into the containers. Then, it leverages the FRRouting integrated shell to apply the rules at runtime and saves them persistently to memory.
```sh
#!/bin/bash

echo "Initializing core routing"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTERS=("R101" "R102" "R103")

for node in "${ROUTERS[@]}"; do
    container=$(docker ps --format '{{.Names}}' | grep -i "$node" | head -n 1)
    
    if [ -z "$container" ]; then
        echo "ERROR: Container Docker for '$node' not found"
        continue
    fi
    
    echo "Applying configuration on $node"
    
    CONF_FILE="$SCRIPT_DIR/../configs/frr/${node}_frr.conf"
    
    if [ ! -f "$CONF_FILE" ]; then
        echo "ERROR: $CONF_FILE not found"
        continue
    fi
    
    # 1. Copia il file
    docker cp "$CONF_FILE" "$container:/etc/frr/frr.conf"
    
    # 2. Applica la configurazione
    docker exec "$container" vtysh -f /etc/frr/frr.conf
    
    # 3. Salva in memoria
    docker exec "$container" vtysh -c "write memory" > /dev/null
done

echo "OSPF e BGP succesfully configurated"
```
### VPN overlay deployment
This script automates the OpenVPN deployment. It dynamically resolves the container IDs for CE1, CE2, and CE3. It injects the pre-generated PKI files (certificates, private keys, DH parameters, and TLS-auth keys) along with the configuration files (including the ccd directory for the hub) into the respective containers. It safely kills any previous instances and starts the openvpn processes in the background, specifically injecting a 3-second delay after starting the hub to ensure it is fully initialized before the spokes attempt to connect.
```sh
#!/bin/bash

echo "Starting overlay VPN"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="$SCRIPT_DIR/../vpn-keys/pki"

CE1_CT=$(docker ps --format '{{.Names}}' | grep -i "CE1" | head -n 1)
CE2_CT=$(docker ps --format '{{.Names}}' | grep -i "CE2" | head -n 1)
CE3_CT=$(docker ps --format '{{.Names}}' | grep -i "CE3" | head -n 1)

echo "Configuring server hub (CE3)"
docker exec "$CE3_CT" mkdir -p /etc/openvpn/certs /etc/openvpn/ccd
docker cp "$PKI_DIR/ca.crt" "$CE3_CT:/etc/openvpn/certs/"
docker cp "$PKI_DIR/issued/CE3.crt" "$CE3_CT:/etc/openvpn/certs/"
docker cp "$PKI_DIR/private/CE3.key" "$CE3_CT:/etc/openvpn/certs/"
docker cp "$PKI_DIR/dh.pem" "$CE3_CT:/etc/openvpn/certs/"
docker cp "$PKI_DIR/ta.key" "$CE3_CT:/etc/openvpn/certs/"
docker cp "$SCRIPT_DIR/../configs/openvpn/server.conf" "$CE3_CT:/etc/openvpn/server.conf"
docker cp "$SCRIPT_DIR/../configs/openvpn/ccd/CE1" "$CE3_CT:/etc/openvpn/ccd/CE1"
docker cp "$SCRIPT_DIR/../configs/openvpn/ccd/CE2" "$CE3_CT:/etc/openvpn/ccd/CE2"

echo "Configuring spoke 1 (CE1)"
docker exec "$CE1_CT" mkdir -p /etc/openvpn/certs
docker cp "$PKI_DIR/ca.crt" "$CE1_CT:/etc/openvpn/certs/"
docker cp "$PKI_DIR/issued/CE1.crt" "$CE1_CT:/etc/openvpn/certs/"
docker cp "$PKI_DIR/private/CE1.key" "$CE1_CT:/etc/openvpn/certs/"
docker cp "$PKI_DIR/ta.key" "$CE1_CT:/etc/openvpn/certs/"
docker cp "$SCRIPT_DIR/../configs/openvpn/client-CE1.conf" "$CE1_CT:/etc/openvpn/client.conf"

echo "Configuring spoke 2 (CE2)"
docker exec "$CE2_CT" mkdir -p /etc/openvpn/certs
docker cp "$PKI_DIR/ca.crt" "$CE2_CT:/etc/openvpn/certs/"
docker cp "$PKI_DIR/issued/CE2.crt" "$CE2_CT:/etc/openvpn/certs/"
docker cp "$PKI_DIR/private/CE2.key" "$CE2_CT:/etc/openvpn/certs/"
docker cp "$PKI_DIR/ta.key" "$CE2_CT:/etc/openvpn/certs/"
docker cp "$SCRIPT_DIR/../configs/openvpn/client-CE2.conf" "$CE2_CT:/etc/openvpn/client.conf"

echo "Starting OpenVPN deamons"
docker exec "$CE3_CT" pkill openvpn 2>/dev/null
docker exec "$CE1_CT" pkill openvpn 2>/dev/null
docker exec "$CE2_CT" pkill openvpn 2>/dev/null
sleep 2

docker exec -d "$CE3_CT" openvpn --config /etc/openvpn/server.conf
sleep 3
docker exec -d "$CE1_CT" openvpn --config /etc/openvpn/client.conf
docker exec -d "$CE2_CT" openvpn --config /etc/openvpn/client.conf

echo "VPN tunnels configured"
```
### Authentication services
Targets the authentication infrastructure. It pushes the `clients.conf` and `users` policies to the FreeRADIUS container in Site 3 and restarts the `freeradius` service. Concurrently, it pushes the `hostapd.conf` file to the eBPF switch in Site 2 and starts the Authenticator daemon.
```sh
#!/bin/bash

echo "Starting 802.1X auth"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$SCRIPT_DIR/../configs"

RAD_CT=$(docker ps --format '{{.Names}}' | grep -i "RADIUS" | head -n 1)
SW_CT=$(docker ps --format '{{.Names}}' | grep -i "eBPF-1" | head -n 1)

echo "Configuring FreeRADIUS Server (Site 3)"
docker cp "$CONF_DIR/radius/clients.conf" "$RAD_CT:/etc/freeradius/3.0/clients.conf"
docker cp "$CONF_DIR/radius/users" "$RAD_CT:/etc/freeradius/3.0/mods-config/files/authorize"
docker exec "$RAD_CT" pkill freeradius 2>/dev/null || true
docker exec -d "$RAD_CT" freeradius

echo "Configuring hostapd"
docker exec "$SW_CT" pkill hostapd 2>/dev/null || true
docker cp "$CONF_DIR/hostapd/hostapd.conf" "$SW_CT:/etc/hostapd.conf"
docker exec -d "$SW_CT" hostapd /etc/hostapd.conf

echo "802.1X and RADIUS activated"
```
### Client trigger
Acts as the mechanical trigger for the Data Plane security. It copies the `wpa_supplicant.conf` files into Client-B1 and Client-B2 and executes the supplicant daemon in the background, which physically forces the interfaces to inject the EAPOL identity frames and initiate the 802.1X handshake.
```sh
#!/bin/bash

echo "Connecting clients 802.1X"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$SCRIPT_DIR/../configs"

B1_CT=$(docker ps --format '{{.Names}}' | grep -i "client-B1" | head -n 1)
B2_CT=$(docker ps --format '{{.Names}}' | grep -i "client-B2" | head -n 1)

echo "Preparing wpa_supplicant on client (Site 2)..."
docker cp "$CONF_DIR/wpa_supplicant/wpa_supplicant-B1.conf" "$B1_CT:/etc/wpa_supplicant.conf"
docker cp "$CONF_DIR/wpa_supplicant/wpa_supplicant-B2.conf" "$B2_CT:/etc/wpa_supplicant.conf"

docker exec "$B1_CT" pkill wpa_supplicant 2>/dev/null || true
docker exec "$B2_CT" pkill wpa_supplicant 2>/dev/null || true

echo "Starting wpa_supplicant on Client"
docker exec -d "$B1_CT" wpa_supplicant -i eth0 -D wired -c /etc/wpa_supplicant.conf
docker exec -d "$B2_CT" wpa_supplicant -i eth0 -D wired -c /etc/wpa_supplicant.conf

echo "Clients are negotiating access"
```
### Master orchestrator
To provide a flawless, one-click deployment experience, the `boot_all.sh` script acts as the master orchestrator.
```sh
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
```
