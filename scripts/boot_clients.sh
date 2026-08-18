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
