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
