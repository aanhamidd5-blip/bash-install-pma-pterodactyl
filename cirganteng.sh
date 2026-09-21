#!/bin/bash
set -Eeuo pipefail

# ============================================================
# CIRGANTENG - PHPMYADMIN FOR PTERODACTYL
# Version : 3.0
# Route   : https://PANEL-DOMAIN/pma/
# PHP     : PHP 8.3 FPM
# NGINX   : Existing Pterodactyl server block
# ============================================================

PMA_VERSION="5.2.3"
PMA_DIR="/usr/share/phpmyadmin"
PMA_TMP="/tmp/phpmyadmin-install"
NGINX_CONF="/etc/nginx/sites-enabled/pterodactyl.conf"
PHP_FPM_SOCK="/run/php/php8.3-fpm.sock"
BACKUP_DIR="/root/cirganteng-pma-backups"

echo "============================================================"
echo "        CIRGANTENG - INSTALL PHPMYADMIN"
echo "============================================================"

# ------------------------------------------------------------
# ROOT CHECK
# ------------------------------------------------------------
if [ "$(id -u)" != "0" ]; then
    echo "[ERROR] Jalankan sebagai root."
    exit 1
fi

# ------------------------------------------------------------
# CEK PANEL
# ------------------------------------------------------------
if [ ! -f /var/www/pterodactyl/.env ]; then
    echo "[ERROR] /var/www/pterodactyl/.env tidak ditemukan."
    echo "Pastikan Pterodactyl sudah terinstall."
    exit 1
fi

APP_URL="$(grep -E '^APP_URL=' /var/www/pterodactyl/.env | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"

if [ -z "$APP_URL" ]; then
    echo "[ERROR] APP_URL tidak ditemukan."
    exit 1
fi

PANEL_DOMAIN="$(printf '%s' "$APP_URL" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##')"

if [ -z "$PANEL_DOMAIN" ]; then
    echo "[ERROR] Domain panel gagal dideteksi."
    exit 1
fi

echo "[OK] Panel domain : $PANEL_DOMAIN"
echo "[OK] PMA URL      : https://$PANEL_DOMAIN/pma/"

# ------------------------------------------------------------
# CEK NGINX
# ------------------------------------------------------------
if ! command -v nginx >/dev/null 2>&1; then
    echo "[ERROR] Nginx tidak ditemukan."
    exit 1
fi

if [ ! -f "$NGINX_CONF" ]; then
    echo "[ERROR] Config Nginx tidak ditemukan:"
    echo "$NGINX_CONF"
    exit 1
fi

# ------------------------------------------------------------
# CEK PHP 8.3
# ------------------------------------------------------------
if ! command -v php8.3 >/dev/null 2>&1; then
    echo "[ERROR] PHP 8.3 tidak ditemukan."
    exit 1
fi

if [ ! -S "$PHP_FPM_SOCK" ]; then
    echo "[INFO] Socket PHP-FPM belum tersedia. Restart PHP 8.3-FPM..."
    systemctl restart php8.3-fpm
    sleep 2
fi

if [ ! -S "$PHP_FPM_SOCK" ]; then
    echo "[ERROR] Socket PHP-FPM tidak ditemukan:"
    echo "$PHP_FPM_SOCK"
    exit 1
fi

echo "[OK] PHP-FPM : $PHP_FPM_SOCK"

# ------------------------------------------------------------
# CEK EXTENSION PHP
# ------------------------------------------------------------
echo
echo "[INFO] Cek extension PHP..."

php8.3 -m | grep -qi '^mysqli$' || {
    echo "[WARNING] Extension mysqli belum ditemukan."
}

php8.3 -m | grep -qi '^mbstring$' || {
    echo "[WARNING] Extension mbstring belum ditemukan."
}

php8.3 -m | grep -qi '^zip$' || {
    echo "[WARNING] Extension zip belum ditemukan."
}

# ------------------------------------------------------------
# BACKUP NGINX
# ------------------------------------------------------------
mkdir -p "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/pterodactyl.conf.$(date +%Y%m%d-%H%M%S).bak"

cp -a "$NGINX_CONF" "$BACKUP_FILE"

echo "[OK] Backup:"
echo "$BACKUP_FILE"

# ------------------------------------------------------------
# DOWNLOAD PHPMYADMIN
# ------------------------------------------------------------
echo
echo "[1/8] Download phpMyAdmin $PMA_VERSION..."

rm -rf "$PMA_TMP"
mkdir -p "$PMA_TMP"

cd "$PMA_TMP"

PMA_URL="https://files.phpmyadmin.net/phpMyAdmin-${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz"

curl -fL --retry 3 --connect-timeout 15 \
    "$PMA_URL" \
    -o phpmyadmin.tar.gz

if [ ! -s phpmyadmin.tar.gz ]; then
    echo "[ERROR] Download phpMyAdmin gagal."
    exit 1
fi

echo "[OK] Download selesai."

# ------------------------------------------------------------
# EXTRACT
# ------------------------------------------------------------
echo
echo "[2/8] Extract phpMyAdmin..."

tar -xzf phpmyadmin.tar.gz

EXTRACTED_DIR="$PMA_TMP/phpMyAdmin-${PMA_VERSION}-all-languages"

if [ ! -d "$EXTRACTED_DIR" ]; then
    echo "[ERROR] Folder hasil extract tidak ditemukan."
    exit 1
fi

# ------------------------------------------------------------
# INSTALL FILE
# ------------------------------------------------------------
echo
echo "[3/8] Install ke $PMA_DIR..."

if [ -d "$PMA_DIR" ]; then
    OLD_BACKUP="$BACKUP_DIR/phpmyadmin-old-$(date +%Y%m%d-%H%M%S)"
    mv "$PMA_DIR" "$OLD_BACKUP"
    echo "[OK] PMA lama dipindahkan ke:"
    echo "$OLD_BACKUP"
fi

mv "$EXTRACTED_DIR" "$PMA_DIR"

chown -R root:root "$PMA_DIR"

find "$PMA_DIR" -type d -exec chmod 755 {} \;
find "$PMA_DIR" -type f -exec chmod 644 {} \;

mkdir -p "$PMA_DIR/tmp"

chmod 777 "$PMA_DIR/tmp"

echo "[OK] File phpMyAdmin terpasang."

# ------------------------------------------------------------
# CONFIG NGINX
# ------------------------------------------------------------
echo
echo "[4/8] Pasang routing Nginx..."

python3 - "$NGINX_CONF" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

START = "    # CIRGANTENG-PMA-START"
END   = "    # CIRGANTENG-PMA-END"

# Hapus block PMA lama kalau ada
start = s.find(START)
end = s.find(END)

if start != -1 and end != -1:
    end += len(END)
    s = s[:start] + s[end:]

block = r'''
    # CIRGANTENG-PMA-START

    # /pma -> /pma/
    location = /pma {
        return 301 /pma/;
    }

    # phpMyAdmin halaman utama
    # Sengaja direct FastCGI agar tidak terjadi
    # "Primary script unknown".
    location = /pma/ {
        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME /usr/share/phpmyadmin/index.php;
        fastcgi_param SCRIPT_NAME /pma/index.php;
        fastcgi_param DOCUMENT_ROOT /usr/share/phpmyadmin;
        fastcgi_param REQUEST_URI $request_uri;

        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    # phpMyAdmin PHP files
    location ~ ^/pma/(.+\.php)$ {
        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME /usr/share/phpmyadmin/$1;
        fastcgi_param SCRIPT_NAME /pma/$1;
        fastcgi_param DOCUMENT_ROOT /usr/share/phpmyadmin;
        fastcgi_param REQUEST_URI $request_uri;

        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    # Static files phpMyAdmin
    location /pma/ {
        alias /usr/share/phpmyadmin/;
    }

    # CIRGANTENG-PMA-END
'''

# Sisipkan sebelum penutup server terakhir
pos = s.rfind("}")
if pos == -1:
    raise SystemExit("Penutup server Nginx tidak ditemukan.")

s = s[:pos] + block + "\n" + s[pos:]

p.write_text(s)
PY

echo "[OK] Routing PMA terpasang."

# ------------------------------------------------------------
# NGINX TEST
# ------------------------------------------------------------
echo
echo "[5/8] Test konfigurasi Nginx..."

if ! nginx -t; then
    echo
    echo "[ERROR] Nginx config gagal."
    echo "[INFO] Restore backup:"
    echo "$BACKUP_FILE"

    cp -a "$BACKUP_FILE" "$NGINX_CONF"
    nginx -t || true
    exit 1
fi

systemctl reload nginx

echo "[OK] Nginx berhasil reload."

# ------------------------------------------------------------
# PHP-FPM
# ------------------------------------------------------------
echo
echo "[6/8] Restart PHP-FPM..."

systemctl restart php8.3-fpm
sleep 2

if ! systemctl is-active --quiet php8.3-fpm; then
    echo "[ERROR] PHP 8.3-FPM tidak aktif."
    exit 1
fi

if [ ! -S "$PHP_FPM_SOCK" ]; then
    echo "[ERROR] Socket PHP-FPM tidak tersedia."
    exit 1
fi

echo "[OK] PHP-FPM aktif."

# ------------------------------------------------------------
# LOCAL TEST
# ------------------------------------------------------------
echo
echo "[7/8] Test phpMyAdmin dari localhost..."

TEST_OUTPUT="$(curl -sS -D - \
    -H "Host: $PANEL_DOMAIN" \
    --max-time 15 \
    http://127.0.0.1/pma/index.php \
    -o /tmp/cirganteng-pma-test.html || true)"

HTTP_CODE="$(printf '%s\n' "$TEST_OUTPUT" | head -1 | awk '{print $2}')"

if [ "$HTTP_CODE" = "200" ]; then
    echo "[OK] phpMyAdmin HTTP 200."
else
    echo "[ERROR] phpMyAdmin tidak menghasilkan HTTP 200."
    echo
    echo "$TEST_OUTPUT"
    echo
    echo "===== ERROR NGINX TERBARU ====="
    tail -30 /var/log/nginx/pterodactyl.app-error.log || true
    echo
    echo "[INFO] Config tidak diubah lagi."
    exit 1
fi

# ------------------------------------------------------------
# CLEANUP
# ------------------------------------------------------------
echo
echo "[8/8] Cleanup..."

rm -rf "$PMA_TMP"
rm -f /tmp/cirganteng-pma-test.html

echo
echo "============================================================"
echo "              INSTALLASI BERHASIL"
echo "============================================================"
echo
echo "phpMyAdmin : $PMA_VERSION"
echo "Panel      : https://$PANEL_DOMAIN"
echo "phpMyAdmin : https://$PANEL_DOMAIN/pma/"
echo
echo "PHP-FPM    : $PHP_FPM_SOCK"
echo "Nginx      : OK"
echo "Local Test : HTTP 200"
echo
echo "Backup     : $BACKUP_FILE"
echo
echo "============================================================"
echo "AKSES:"
echo "https://$PANEL_DOMAIN/pma/"
echo "============================================================"
