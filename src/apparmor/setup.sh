#!/bin/bash
echo "Preparing vulnerable environment"

sudo sed -i 's/user www-data;/user root;/g' /etc/nginx/nginx.conf

sudo mkdir -p /root/.ssh
echo "Private secret key" | sudo tee /root/.ssh/id_rsa >/dev/null
sudo chmod 600 /root/.ssh/id_rsa
echo -e '#!/bin/bash\necho "Malware executed"' | sudo tee /tmp/malware.sh >/dev/null
sudo chmod +x /tmp/malware.sh
echo "Test page working" | sudo tee /var/www/html/index.html >/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo cp "$SCRIPT_DIR/nginx_vulnerable.conf" /etc/nginx/sites-available/default
sudo aa-disable /usr/sbin/nginx >/dev/null 2>&1 || true
sudo systemctl restart nginx
sleep 2
echo "Environment ready. Nginx is vulnerable"
