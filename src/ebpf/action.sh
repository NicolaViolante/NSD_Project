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
