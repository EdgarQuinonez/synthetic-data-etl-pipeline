#!/usr/bin/env bash
set -euxo pipefail

apt-get update
apt-get install -y nginx

cat > /etc/nginx/sites-available/synthetic <<'NGINX'
server {
    listen 80;
    server_name _;

    location /synthetic {
        proxy_pass http://127.0.0.1:19090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location / {
        return 404;
    }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/synthetic /etc/nginx/sites-enabled/synthetic

nginx -t
systemctl enable nginx
systemctl restart nginx