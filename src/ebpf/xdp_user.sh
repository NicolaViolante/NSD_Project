#!/bin/bash
echo "XDP userspace app"
ebtables -t filter -F
ebtables -t filter -P FORWARD DROP
hostapd_cli -i br0 -a /workspace/ebpf/action.sh
