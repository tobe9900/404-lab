#!/usr/bin/env bash
set -e

echo "===== 开始清理 Xray / Nginx / Certbot ====="

# 必须 root
if [[ $EUID -ne 0 ]]; then
  echo "请用 root 执行"
  exit 1
fi

echo "==> 停止服务"
systemctl stop xray 2>/dev/null || true
systemctl disable xray 2>/dev/null || true

systemctl stop nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true

echo "==> 删除 Xray"
bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) remove || true

rm -rf /usr/local/etc/xray
rm -rf /usr/local/bin/xray
rm -rf /usr/bin/xray

rm -f /etc/systemd/system/xray.service
rm -f /usr/lib/systemd/system/xray.service
rm -f /lib/systemd/system/xray.service

echo "==> 删除 Nginx"
apt-get remove --purge -y nginx nginx-common nginx-core || true
rm -rf /etc/nginx
rm -rf /var/www/html

echo "==> 删除 Certbot 和证书"
apt-get remove --purge -y certbot python3-certbot-nginx || true

rm -rf /etc/letsencrypt
rm -rf /var/lib/letsencrypt
rm -rf /var/log/letsencrypt

echo "==> 清理残留依赖"
apt-get autoremove -y
apt-get autoclean

echo "==> 重载 systemd"
systemctl daemon-reexec
systemctl daemon-reload

echo "==> 重置防火墙（UFW）"
ufw disable || true
ufw --force reset || true

echo "===== 清理完成 ✅ ====="