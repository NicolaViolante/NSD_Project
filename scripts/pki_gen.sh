#!/bin/bash

echo "Generating PKI"

EASYRSA_DIR="/usr/share/easy-rsa/3"
OUT_DIR="../vpn-keys"

if [ ! -d "$EASYRSA_DIR" ]; then
    echo "ERROR: easy-rsa not found in $EASYRSA_DIR."
    exit 1
fi

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

echo "Initializing PKI..."
$EASYRSA_DIR/easyrsa init-pki > /dev/null

echo "Creating the Certification Authority (CA)..."
export EASYRSA_BATCH=1 
$EASYRSA_DIR/easyrsa build-ca nopass > /dev/null

echo "Generating server certificate (CE3)..."
$EASYRSA_DIR/easyrsa build-server-full CE3 nopass > /dev/null

echo "Generating clients certificates (CE1 and CE2)..."
$EASYRSA_DIR/easyrsa build-client-full CE1 nopass > /dev/null
$EASYRSA_DIR/easyrsa build-client-full CE2 nopass > /dev/null

echo "Generating Diffie-Hellman parameters..."
$EASYRSA_DIR/easyrsa gen-dh > /dev/null

echo "Generating TLS key..."
openvpn --genkey secret pki/ta.key

echo "Certificates saved"
