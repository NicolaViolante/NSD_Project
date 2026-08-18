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
