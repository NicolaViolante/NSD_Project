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

