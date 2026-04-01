 #!/usr/bin/env bash
set -euo pipefail

# ===== 可修改参数 =====
DOMAIN="域名"
EMAIL="service@域名"
UUID="随意或生成uuid即可"
WS_PATH="/路径随意"
XRAY_PORT="10000"
XRAY_EMAIL_TAG="user@域名"

# ===== 基础检查 =====
if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行"
  exit 1
fi

if [[ -z "${DOMAIN}" || -z "${EMAIL}" || -z "${UUID}" ]]; then
  echo "DOMAIN / EMAIL / UUID 不能为空"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> 更新系统并安装依赖"
apt-get update
apt-get install -y curl wget unzip socat nginx certbot python3-certbot-nginx ufw ca-certificates

mkdir -p /var/www/html
mkdir -p /usr/local/etc/xray
mkdir -p /etc/nginx/conf.d
mkdir -p /etc/systemd/system/certbot-renew.service.d

# ===== 1. 安装 Xray（官方安装脚本）=====
if ! command -v xray >/dev/null 2>&1; then
  echo "==> 安装 Xray"
  wget -O /tmp/install-release.sh https://github.com/XTLS/Xray-install/raw/main/install-release.sh
  bash /tmp/install-release.sh install
else
  echo "==> 检测到 xray 已安装，跳过安装"
fi

# 某些环境 xray 装在 /usr/local/bin 或 /usr/bin，做个兜底
XRAY_BIN="$(command -v xray || true)"
if [[ -z "${XRAY_BIN}" ]]; then
  echo "xray 安装失败，未找到可执行文件"
  exit 1
fi

# ===== 2. 写 Xray 配置 =====
echo "==> 写入 Xray 配置"
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "email": "${XRAY_EMAIL_TAG}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${WS_PATH}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

# ===== 3. systemd 服务（如官方未创建则兜底）=====
if [[ ! -f /etc/systemd/system/xray.service && ! -f /usr/lib/systemd/system/xray.service && ! -f /lib/systemd/system/xray.service ]]; then
  echo "==> 写入 xray systemd 服务"
  cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=${XRAY_BIN} run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# ===== 4. 先写 HTTP-only nginx 配置，用于 ACME 验证 =====
echo "==> 写入 nginx HTTP 验证配置"
cat > /etc/nginx/conf.d/${DOMAIN}.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root /var/www/html;

    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        allow all;
        try_files \$uri =404;
    }

    location / {
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }
}
EOF

# 如果默认站点存在，禁掉，避免冲突
if [[ -L /etc/nginx/sites-enabled/default || -f /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
fi

nginx -t
systemctl enable nginx
systemctl restart nginx

# ===== 5. 申请证书 =====
if [[ ! -f /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ]]; then
  echo "==> 申请 Let's Encrypt 证书"
  certbot certonly --webroot \
    -w /var/www/html \
    -d "${DOMAIN}" \
    --email "${EMAIL}" \
    --agree-tos \
    --non-interactive
else
  echo "==> 检测到证书已存在，跳过申请"
fi

# ===== 6. 写 HTTPS + WS 反代配置 =====
echo "==> 写入 nginx HTTPS 配置"
cat > /etc/nginx/conf.d/${DOMAIN}.conf <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root /var/www/html;

    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        allow all;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_prefer_server_ciphers off;

    location = ${WS_PATH} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${XRAY_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        proxy_buffering off;
    }

    location / {
        return 403;
    }
}
EOF

nginx -t
systemctl reload nginx

# ===== 7. 配置 certbot 自动续期后 reload nginx =====
echo "==> 配置 certbot 续期后的 nginx reload"
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/usr/bin/env bash
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# ===== 8. 配置 UFW =====
echo "==> 配置防火墙"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# ===== 9. 检查状态 =====
echo "==> 服务状态"
systemctl --no-pager --full status xray | sed -n '1,20p' || true
systemctl --no-pager --full status nginx | sed -n '1,20p' || true

echo
echo "===== 完成 ====="
echo "域名: ${DOMAIN}"
echo "UUID: ${UUID}"
echo "WS Path: ${WS_PATH}"
echo "TLS: 开启"
echo "客户端端口: 443"
echo
echo "记得确认："
echo "1) DNS 已解析到本机公网 IP"
echo "2) 云厂商安全组已放行 80/443"
echo "3) 客户端参数与上面完全一致"
echo
echo "v2rayN 链接："
echo "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=${WS_PATH}#${DOMAIN}"