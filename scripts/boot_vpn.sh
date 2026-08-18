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

