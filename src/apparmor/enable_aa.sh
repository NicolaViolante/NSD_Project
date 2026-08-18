#!/bin/bash
echo "Loading AppArmor profile"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo cp "$SCRIPT_DIR/usr.sbin.nginx" /etc/apparmor.d/usr.sbin.nginx
sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.nginx
sudo aa-enforce /usr/sbin/nginx >/dev/null 2>&1
sudo systemctl restart nginx
sleep 2

echo "Profile loaded. Loaded profiles:"
sudo aa-status | grep -i nginx
