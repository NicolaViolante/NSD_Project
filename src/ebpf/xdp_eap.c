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
