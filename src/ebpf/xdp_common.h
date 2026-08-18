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
