#!/bin/bash
echo "Starting test"

sudo dmesg -c > /dev/null 2>&1

if sudo aa-status 2>/dev/null | grep -q "/usr/sbin/nginx"; then
    echo "AppArmor profile active. Using aa-exec for local tests."
    EXEC_CMD="sudo aa-exec -p /usr/sbin/nginx"
    MAC_ACTIVE=1
else
    echo "No AppArmor profile active. Using sudo for local tests (DAC bypass)."
    EXEC_CMD="sudo"
    MAC_ACTIVE=0
fi

echo ""
echo "Allowed action (Default Web Page):"
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost/

echo "Obj 1 e 2: Read critical files (Shadow e SSH Key):"
curl -s -o /dev/null -w "/etc/shadow: HTTP %{http_code}\n" http://localhost/hacked_shadow
curl -s -o /dev/null -w "SSH Key: HTTP %{http_code}\n" http://localhost/hacked_ssh

echo "Obj 3: Write in /etc (WebDAV PUT):"
curl -s -X PUT -d "Pwned" -o /dev/null -w "HTTP %{http_code}\n" http://localhost/hacked_etc/pwned.txt
if [ -f /etc/pwned.txt ]; then 
    echo "pwned.txt wrote in /etc"
    sudo rm -f /etc/pwned.txt
fi

echo "Obj 4: Execute script from /tmp:"
$EXEC_CMD /tmp/malware.sh 2>&1


# Log se MAC attivo
if [ "$MAC_ACTIVE" -eq 1 ]; then
    echo "KERNEL LOG APPARMOR (DENIED) ==="
    sudo dmesg | grep -i apparmor | grep -i "DENIED" | grep -vE "tty|pts" | tail -n 30
fi

