#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# CIRGANTENG - FINAL PHPMYADMIN INSTALLER FOR PTERODACTYL
# Ubuntu 22.04 / Nginx / PHP 8.3-FPM
#
# URL:
#   https://PANEL-DOMAIN/pma/
#
# Tidak:
#   - install Apache
#   - apt upgrade
#   - mengubah APP_URL Pterodactyl
#   - membuat port baru
#   - memakai port 8081
# ============================================================

PMA_DIR="/usr/share/phpmyadmin"
PMA_TMP="/usr/share/phpmyadmin/tmp"
PMA_DOWNLOAD="/tmp/phpmyadmin-latest.tar.gz"
BACKUP_DIR="/root/cirganteng-pma-backups"
NGINX_AVAILABLE="/etc/nginx/sites-available/pterodactyl.conf"

PMA_URL_PATH="/pma/"
PMA_DOWNLOAD_URL="https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.tar.gz"

PHP_VERSION="8.3"
PHP_FPM_SOCKET="/run/php/php8.3-fpm.sock"

MARK_START="# CIRGANTENG-PMA-START"
MARK_END="# CIRGANTENG-PMA-END"

log() {
    echo "[INFO] $*"
}

ok() {
    echo "[OK] $*"
}

warn() {
    echo "[WARNING] $*"
}

die() {
    echo
    echo "[ERROR] $*"
    echo
    exit 1
}

trap 'echo; echo "[ERROR] Installer berhenti pada baris $LINENO."; exit 1' ERR

# ------------------------------------------------------------
# ROOT
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "Jalankan sebagai root."
fi

clear

echo "============================================================"
echo "        CIRGANTENG - INSTALL PHPMYADMIN FINAL"
echo "============================================================"
echo

# ------------------------------------------------------------
# CEK PTERODACTYL
# ------------------------------------------------------------

if [[ ! -f "/var/www/pterodactyl/.env" ]]; then
    die "File /var/www/pterodactyl/.env tidak ditemukan."
fi

if [[ ! -f "$NGINX_AVAILABLE" ]]; then
    die "Config Nginx Pterodactyl tidak ditemukan: $NGINX_AVAILABLE"
fi

# ------------------------------------------------------------
# DETEKSI DOMAIN DARI APP_URL
# ------------------------------------------------------------

APP_URL="$(
    grep -E '^APP_URL=' /var/www/pterodactyl/.env \
    | tail -n1 \
    | cut -d= -f2- \
    | tr -d '"' \
    | tr -d "'" \
    | sed 's/[[:space:]]*$//'
)"

if [[ -z "$APP_URL" ]]; then
    die "APP_URL tidak ditemukan di /var/www/pterodactyl/.env"
fi

APP_URL="${APP_URL%/}"

PANEL_DOMAIN="$(
    printf '%s\n' "$APP_URL" \
    | sed -E 's#^https?://##; s#/.*$##'
)"

if [[ -z "$PANEL_DOMAIN" ]]; then
    die "Gagal mendeteksi domain panel dari APP_URL."
fi

PMA_PUBLIC_URL="${APP_URL}${PMA_URL_PATH}"

ok "Panel domain : $PANEL_DOMAIN"
ok "PMA URL      : $PMA_PUBLIC_URL"

# ------------------------------------------------------------
# CEK NGINX
# ------------------------------------------------------------

if ! command -v nginx >/dev/null 2>&1; then
    die "Nginx tidak ditemukan."
fi

if ! systemctl is-active --quiet nginx; then
    die "Nginx tidak aktif."
fi

ok "Nginx aktif"

# ------------------------------------------------------------
# CEK PHP
# ------------------------------------------------------------

if ! command -v php >/dev/null 2>&1; then
    die "PHP tidak ditemukan."
fi

PHP_CLI_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"

if [[ "$PHP_CLI_VERSION" != "$PHP_VERSION" ]]; then
    warn "PHP CLI terdeteksi: $PHP_CLI_VERSION"
    warn "Installer menargetkan PHP $PHP_VERSION."
fi

if [[ ! -S "$PHP_FPM_SOCKET" ]]; then
    die "Socket PHP-FPM tidak ditemukan: $PHP_FPM_SOCKET"
fi

if ! systemctl is-active --quiet "php${PHP_VERSION}-fpm"; then
    die "php${PHP_VERSION}-fpm tidak aktif."
fi

ok "PHP-FPM : $PHP_FPM_SOCKET"

# ------------------------------------------------------------
# CEK EXTENSION
# ------------------------------------------------------------

echo
echo "[INFO] Cek extension PHP..."

MISSING_EXT=()

for EXT in mysqli mbstring zip; do
    if php -m 2>/dev/null | grep -qi "^${EXT}$"; then
        ok "Extension $EXT tersedia"
    else
        warn "Extension $EXT belum ditemukan."
        MISSING_EXT+=("$EXT")
    fi
done

# ------------------------------------------------------------
# INSTALL EXTENSION YANG KURANG
# HANYA PACKAGE PHP 8.3
# TIDAK APT UPGRADE
# ------------------------------------------------------------

if [[ "${#MISSING_EXT[@]}" -gt 0 ]]; then
    echo
    log "Mencoba memasang extension PHP 8.3 yang diperlukan..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -o Acquire::Retries=3

    PACKAGES=()

    for EXT in "${MISSING_EXT[@]}"; do
        case "$EXT" in
            mysqli)
                PACKAGES+=("php8.3-mysql")
                ;;
            mbstring)
                PACKAGES+=("php8.3-mbstring")
                ;;
            zip)
                PACKAGES+=("php8.3-zip")
                ;;
        esac
    done

    # Hapus duplikat package
    mapfile -t PACKAGES < <(printf '%s\n' "${PACKAGES[@]}" | sort -u)

    apt-get install -y --no-install-recommends "${PACKAGES[@]}"

    systemctl restart "php${PHP_VERSION}-fpm"

    echo
    log "Verifikasi extension..."

    for EXT in mysqli mbstring zip; do
        if php -m 2>/dev/null | grep -qi "^${EXT}$"; then
            ok "Extension $EXT aktif"
        else
            die "Extension $EXT masih belum aktif setelah instalasi."
        fi
    done
else
    ok "Semua extension utama tersedia."
fi

# ------------------------------------------------------------
# CEK TAR/CURL
# ------------------------------------------------------------

command -v curl >/dev/null 2>&1 || die "curl tidak ditemukan."
command -v tar >/dev/null 2>&1 || die "tar tidak ditemukan."

# ------------------------------------------------------------
# BACKUP NGINX
# ------------------------------------------------------------

mkdir -p "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/pterodactyl.conf.$(date +%Y%m%d-%H%M%S).bak"

cp -a "$NGINX_AVAILABLE" "$BACKUP_FILE"

ok "Backup:"
echo "$BACKUP_FILE"

# ------------------------------------------------------------
# DOWNLOAD PHPMYADMIN
# ------------------------------------------------------------

echo
echo "[1/8] Download phpMyAdmin stable..."

rm -f "$PMA_DOWNLOAD"

curl -fL --retry 3 --retry-delay 2 \
    "$PMA_DOWNLOAD_URL" \
    -o "$PMA_DOWNLOAD"

if [[ ! -s "$PMA_DOWNLOAD" ]]; then
    die "Download phpMyAdmin gagal."
fi

ok "Download berhasil."

# ------------------------------------------------------------
# VALIDASI TAR.GZ
# ------------------------------------------------------------

echo "[2/8] Validasi archive..."

if ! tar -tzf "$PMA_DOWNLOAD" >/dev/null 2>&1; then
    rm -f "$PMA_DOWNLOAD"
    die "Archive phpMyAdmin tidak valid."
fi

ok "Archive valid."

# ------------------------------------------------------------
# EXTRACT KE TEMP
# ------------------------------------------------------------

echo "[3/8] Extract phpMyAdmin..."

EXTRACT_DIR="/tmp/cirganteng-phpmyadmin-$$"

rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

tar -xzf "$PMA_DOWNLOAD" -C "$EXTRACT_DIR"

EXTRACTED_DIR="$(
    find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d \
    | head -n1
)"

if [[ -z "$EXTRACTED_DIR" || ! -f "$EXTRACTED_DIR/index.php" ]]; then
    rm -rf "$EXTRACT_DIR" "$PMA_DOWNLOAD"
    die "Folder phpMyAdmin hasil extract tidak valid."
fi

ok "Extract berhasil."

# ------------------------------------------------------------
# BACKUP INSTALASI LAMA JIKA ADA
# ------------------------------------------------------------

echo "[4/8] Siapkan directory phpMyAdmin..."

if [[ -d "$PMA_DIR" ]]; then
    OLD_BACKUP="$BACKUP_DIR/phpmyadmin-old-$(date +%Y%m%d-%H%M%S)"

    mv "$PMA_DIR" "$OLD_BACKUP"

    ok "Instalasi lama dipindahkan ke:"
    echo "$OLD_BACKUP"
fi

mv "$EXTRACTED_DIR" "$PMA_DIR"

rm -rf "$EXTRACT_DIR" "$PMA_DOWNLOAD"

# ------------------------------------------------------------
# TEMP DIRECTORY
# ------------------------------------------------------------

mkdir -p "$PMA_TMP"

chown -R root:root "$PMA_DIR"
chown -R www-data:www-data "$PMA_TMP"

chmod 755 "$PMA_DIR"
chmod 770 "$PMA_TMP"

ok "phpMyAdmin terpasang di $PMA_DIR"

# ------------------------------------------------------------
# CONFIG INC
# ------------------------------------------------------------

echo "[5/8] Buat config phpMyAdmin..."

if [[ ! -f "$PMA_DIR/config.inc.php" ]]; then
cat > "$PMA_DIR/config.inc.php" <<'PHP'
<?php

declare(strict_types=1);

/*
 * CIRGANTENG phpMyAdmin configuration
 */

$cfg['blowfish_secret'] = 'CIRGANTENG-CHANGE-THIS-SECRET-32-CHARS';

$i = 0;
$i++;

$cfg['Servers'][$i]['auth_type'] = 'cookie';
$cfg['Servers'][$i]['host'] = 'localhost';
$cfg['Servers'][$i]['connect_type'] = 'tcp';
$cfg['Servers'][$i]['compress'] = false;
$cfg['Servers'][$i]['AllowNoPassword'] = false;

$cfg['TempDir'] = '/usr/share/phpmyadmin/tmp';

PHP
fi

# Generate secret acak 32 karakter
SECRET="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"

if [[ "${#SECRET}" -lt 32 ]]; then
    SECRET="CIRGANTENG-$(date +%s)-$(printf '%s' "$RANDOM$RANDOM" | sha256sum | cut -c1-20)"
fi

sed -i \
    "s#CIRGANTENG-CHANGE-THIS-SECRET-32-CHARS#$SECRET#" \
    "$PMA_DIR/config.inc.php"

chown root:www-data "$PMA_DIR/config.inc.php"
chmod 640 "$PMA_DIR/config.inc.php"

ok "config.inc.php siap."

# ------------------------------------------------------------
# HAPUS BLOCK CIRGANTENG LAMA
# ------------------------------------------------------------

echo "[6/8] Update konfigurasi Nginx..."

python3 - "$NGINX_AVAILABLE" <<'PY'
import sys
import re

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

start = "# CIRGANTENG-PMA-START"
end = "# CIRGANTENG-PMA-END"

pattern = re.escape(start) + r".*?" + re.escape(end) + r"\n?"

data = re.sub(pattern, "", data, flags=re.S)

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY

# ------------------------------------------------------------
# INSERT PMA BLOCK SEBELUM PENUTUP SERVER
# ------------------------------------------------------------

python3 - "$NGINX_AVAILABLE" <<'PY'
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

block = r'''
    # CIRGANTENG-PMA-START

    # /pma -> /pma/
    location = /pma {
        return 301 /pma/;
    }

    # phpMyAdmin utama
    location = /pma/ {
        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME /usr/share/phpmyadmin/index.php;
        fastcgi_param SCRIPT_NAME /pma/index.php;
        fastcgi_param DOCUMENT_ROOT /usr/share/phpmyadmin;
        fastcgi_param REQUEST_URI $request_uri;

        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    # PHP phpMyAdmin lainnya
    location ~ ^/pma/(.+\.php)$ {
        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME /usr/share/phpmyadmin/$1;
        fastcgi_param SCRIPT_NAME /pma/$1;
        fastcgi_param DOCUMENT_ROOT /usr/share/phpmyadmin;
        fastcgi_param REQUEST_URI $request_uri;

        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    # CSS / JS / image / static files
    location /pma/ {
        alias /usr/share/phpmyadmin/;
    }

    # CIRGANTENG-PMA-END
'''

# Cari penutup server terakhir.
pos = data.rfind("}")

if pos == -1:
    raise SystemExit("Tidak menemukan penutup server block Nginx.")

data = data[:pos] + block + "\n" + data[pos:]

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY

# ------------------------------------------------------------
# NGINX TEST
# ------------------------------------------------------------

echo "[7/8] Test konfigurasi Nginx..."

if ! nginx -t; then
    echo
    echo "[ERROR] Nginx config gagal."
    echo "[INFO] Restore backup:"
    echo "$BACKUP_FILE"

    cp -a "$BACKUP_FILE" "$NGINX_AVAILABLE"
    nginx -t || true

    exit 1
fi

ok "Nginx syntax OK."

systemctl reload nginx

ok "Nginx reload berhasil."

# ------------------------------------------------------------
# TEST LOCAL
# ------------------------------------------------------------

echo "[8/8] Test phpMyAdmin local..."

sleep 2

LOCAL_HEADERS="$(
    curl -sS \
        --max-time 15 \
        -H "Host: $PANEL_DOMAIN" \
        -D - \
        -o /tmp/cirganteng-pma-test.html \
        "http://127.0.0.1/pma/" \
    || true
)"

if grep -qE '^HTTP/[0-9.]+ 200 ' <<< "$LOCAL_HEADERS"; then
    ok "phpMyAdmin local HTTP 200."
elif grep -qE '^HTTP/[0-9.]+ 30[127] ' <<< "$LOCAL_HEADERS"; then
    ok "phpMyAdmin local redirect terdeteksi."
else
    echo
    warn "Response local tidak 200/redirect."

    echo
    echo "=== RESPONSE ==="
    echo "$LOCAL_HEADERS"

    echo
    echo "=== NGINX ERROR TERAKHIR ==="
    tail -n 30 /var/log/nginx/pterodactyl.app-error.log 2>/dev/null || true

    echo
    warn "Instalasi tetap selesai, tetapi test lokal perlu diperiksa."
fi

# ------------------------------------------------------------
# CLEAN
# ------------------------------------------------------------

rm -f /tmp/cirganteng-pma-test.html

echo
echo "============================================================"
echo "              INSTALLASI SELESAI"
echo "============================================================"
echo
echo "phpMyAdmin : $PMA_PUBLIC_URL"
echo "Panel      : $APP_URL"
echo "PHP-FPM    : $PHP_FPM_SOCKET"
echo "Directory  : $PMA_DIR"
echo "Backup     : $BACKUP_FILE"
echo
echo "Login phpMyAdmin menggunakan USER DATABASE MariaDB/MySQL."
echo
echo "Catatan:"
echo "- Tidak menggunakan port 8081."
echo "- Tidak menginstall Apache."
echo "- Tidak menjalankan apt upgrade."
echo "- Cloudflare dapat menampilkan challenge pada /pma/."
echo
echo "============================================================"
