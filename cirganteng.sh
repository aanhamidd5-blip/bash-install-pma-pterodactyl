#!/usr/bin/env bash
set -Eeuo pipefail

PMA_DIR="/usr/share/phpmyadmin"
PMA_TMP="/usr/share/phpmyadmin/tmp"
PMA_ARCHIVE="/tmp/phpmyadmin-latest.tar.gz"
BACKUP_DIR="/root/cirganteng-pma-backups"
PMA_PATH="/pma"

log(){ echo -e "\033[1;36m[INFO]\033[0m $*"; }
ok(){ echo -e "\033[1;32m[OK]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARNING]\033[0m $*"; }
err(){ echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

[[ $EUID -eq 0 ]] || err "Jalankan installer sebagai root."

echo "============================================================"
echo "       CIRGANTENG - GENERIC PHPMYADMIN INSTALLER"
echo "============================================================"

command -v nginx >/dev/null 2>&1 || err "Nginx belum terinstall."
systemctl is-active --quiet nginx || err "Nginx tidak aktif."

ok "Nginx aktif."

mkdir -p "$BACKUP_DIR"

# ============================================================
# DETEKSI CONFIG NGINX
# ============================================================

SERVER_FILE=""

for FILE in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [[ -f "$FILE" ]] || continue

    if grep -qE 'root[[:space:]]+/var/www/pterodactyl/public' "$FILE" 2>/dev/null; then
        SERVER_FILE="$FILE"
        break
    fi
done

if [[ -z "$SERVER_FILE" ]]; then
    for FILE in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
        [[ -f "$FILE" ]] || continue

        if grep -qE 'server_name[[:space:]]+' "$FILE" 2>/dev/null; then
            SERVER_FILE="$FILE"
            break
        fi
    done
fi

[[ -n "$SERVER_FILE" ]] || err "Config server Nginx tidak ditemukan."

ok "Config Nginx : $SERVER_FILE"

# ============================================================
# AUTO-DETECT DOMAIN
# ============================================================

DOMAIN="$(
    awk '
    /^[[:space:]]*server_name[[:space:]]+/ {
        for (i=2; i<=NF; i++) {
            gsub(/;/,"",$i)
            if (
                $i !~ /^_/ &&
                $i !~ /^\$/ &&
                $i != "localhost" &&
                $i !~ /^\*/
            ) {
                print $i
                exit
            }
        }
    }' "$SERVER_FILE"
)"

[[ -n "$DOMAIN" ]] || err "Domain tidak ditemukan dari server_name Nginx."

ok "Domain terdeteksi : $DOMAIN"

# ============================================================
# AUTO-DETECT PHP-FPM
# ============================================================

PHP_FPM_SOCKET=""

for SOCK in /run/php/php*-fpm.sock; do
    [[ -S "$SOCK" ]] || continue
    PHP_FPM_SOCKET="$SOCK"
done

[[ -n "$PHP_FPM_SOCKET" ]] || err "Socket PHP-FPM tidak ditemukan."

PHP_VERSION="$(
    basename "$PHP_FPM_SOCKET" |
    sed -E 's/^php([0-9.]+)-fpm\.sock$/\1/'
)"

ok "PHP-FPM : $PHP_VERSION"
ok "Socket  : $PHP_FPM_SOCKET"

PHP_BIN="php${PHP_VERSION}"

if ! command -v "$PHP_BIN" >/dev/null 2>&1; then
    PHP_BIN="php"
fi

# ============================================================
# CEK / INSTALL EXTENSION
# ============================================================

log "Cek extension PHP..."

MISSING=()

for EXT in mysqli mbstring zip; do
    if "$PHP_BIN" -m 2>/dev/null | grep -qi "^${EXT}$"; then
        ok "Extension $EXT tersedia"
    else
        warn "Extension $EXT belum tersedia"
        MISSING+=("$EXT")
    fi
done

if (( ${#MISSING[@]} > 0 )); then
    log "Menginstall extension PHP..."

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y

    PACKAGES=()

    for EXT in "${MISSING[@]}"; do
        case "$EXT" in
            mysqli)
                PACKAGES+=("php${PHP_VERSION}-mysql")
                ;;
            mbstring)
                PACKAGES+=("php${PHP_VERSION}-mbstring")
                ;;
            zip)
                PACKAGES+=("php${PHP_VERSION}-zip")
                ;;
        esac
    done

    apt-get install -y "${PACKAGES[@]}"

    systemctl restart "php${PHP_VERSION}-fpm" 2>/dev/null || true

    for EXT in mysqli mbstring zip; do
        "$PHP_BIN" -m 2>/dev/null | grep -qi "^${EXT}$" ||
            err "Extension $EXT masih belum aktif."
    done
fi

ok "Semua extension utama tersedia."

# ============================================================
# BACKUP CONFIG
# ============================================================

BACKUP_FILE="$BACKUP_DIR/$(basename "$SERVER_FILE").$(date +%Y%m%d-%H%M%S).bak"

cp -a "$SERVER_FILE" "$BACKUP_FILE"

ok "Backup : $BACKUP_FILE"

# ============================================================
# DOWNLOAD PHPMYADMIN
# ============================================================

log "Download phpMyAdmin stable..."

rm -f "$PMA_ARCHIVE"

curl -fL --retry 3 \
    -o "$PMA_ARCHIVE" \
    "https://files.phpmyadmin.net/phpMyAdmin/latest/phpMyAdmin-latest-all-languages.tar.gz" ||
    err "Download phpMyAdmin gagal."

ok "Download berhasil."

tar -tzf "$PMA_ARCHIVE" >/dev/null 2>&1 ||
    err "Archive phpMyAdmin tidak valid."

ok "Archive valid."

# ============================================================
# INSTALL PHPMYADMIN
# ============================================================

log "Extract phpMyAdmin..."

TMP_EXTRACT="$(mktemp -d)"

tar -xzf "$PMA_ARCHIVE" -C "$TMP_EXTRACT"

PMA_SOURCE="$(find "$TMP_EXTRACT" -maxdepth 1 -type d -name 'phpMyAdmin-*' | head -n1)"

[[ -d "$PMA_SOURCE" ]] || err "Folder phpMyAdmin tidak ditemukan."

rm -rf "$PMA_DIR"

mkdir -p "$PMA_DIR"
cp -a "$PMA_SOURCE"/. "$PMA_DIR"/

mkdir -p "$PMA_TMP"

chown -R www-data:www-data "$PMA_TMP"

rm -rf "$TMP_EXTRACT" "$PMA_ARCHIVE"

ok "phpMyAdmin terpasang di $PMA_DIR"

# ============================================================
# CONFIG PHPMYADMIN
# ============================================================

BLOWFISH="$(
    head -c 64 /dev/urandom |
    base64 |
    tr -dc 'A-Za-z0-9' |
    head -c 32
)"

cat > "$PMA_DIR/config.inc.php" <<PHP
<?php

\$cfg['blowfish_secret'] = '$BLOWFISH';

\$i = 0;
\$i++;

\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = '127.0.0.1';
\$cfg['Servers'][\$i]['connect_type'] = 'tcp';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;

\$cfg['TempDir'] = '$PMA_TMP';
PHP

chown www-data:www-data "$PMA_DIR/config.inc.php"
chmod 640 "$PMA_DIR/config.inc.php"

ok "config.inc.php siap."

# ============================================================
# NGINX /PMA/
# ============================================================

if grep -qE 'location[[:space:]]+\^~[[:space:]]+/pma/' "$SERVER_FILE" 2>/dev/null ||
   grep -qE 'location[[:space:]]+/pma/' "$SERVER_FILE" 2>/dev/null; then

    warn "Location /pma/ sudah ada."
else

    NGINX_TMP="$(mktemp)"

    awk -v socket="$PHP_FPM_SOCKET" '
    BEGIN { inserted=0 }

    /^[[:space:]]*server[[:space:]]*\{/ && inserted==0 {
        print
        print ""
        print "    # CIRGANTENG PHPMYADMIN"
        print "    location /pma/ {"
        print "        alias /usr/share/phpmyadmin/;"
        print "        index index.php;"
        print "        try_files $uri $uri/ /pma/index.php?$query_string;"
        print "    }"
        print ""
        print "    location ~ ^/pma/(.+\\.php)$ {"
        print "        alias /usr/share/phpmyadmin/$1;"
        print "        include fastcgi_params;"
        print "        fastcgi_param SCRIPT_FILENAME /usr/share/phpmyadmin/$1;"
        print "        fastcgi_param SCRIPT_NAME /pma/$1;"
        print "        fastcgi_pass unix:" socket ";"
        print "    }"
        print ""
        inserted=1
        next
    }

    { print }
    ' "$SERVER_FILE" > "$NGINX_TMP"

    cp "$NGINX_TMP" "$SERVER_FILE"
    rm -f "$NGINX_TMP"

    ok "Location /pma/ ditambahkan."
fi

# ============================================================
# TEST NGINX
# ============================================================

log "Test konfigurasi Nginx..."

if nginx -t; then
    ok "Nginx syntax OK."
else
    cp -a "$BACKUP_FILE" "$SERVER_FILE"
    nginx -t || true
    err "Konfigurasi Nginx gagal. Backup dipulihkan."
fi

systemctl reload nginx

ok "Nginx reload berhasil."

# ============================================================
# LOCAL TEST
# ============================================================

log "Test phpMyAdmin local..."

HTTP_CODE="$(
    curl -ksS \
        -o /dev/null \
        -w '%{http_code}' \
        -H "Host: $DOMAIN" \
        "https://127.0.0.1/pma/" 2>/dev/null || true
)"

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]]; then
    ok "phpMyAdmin local HTTP $HTTP_CODE."
else
    HTTP_CODE="$(
        curl -sS \
            -o /dev/null \
            -w '%{http_code}' \
            -H "Host: $DOMAIN" \
            "http://127.0.0.1/pma/" 2>/dev/null || true
    )"

    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]]; then
        ok "phpMyAdmin local HTTP $HTTP_CODE."
    else
        warn "Test local menghasilkan HTTP $HTTP_CODE."
    fi
fi

# ============================================================
# SELESAI
# ============================================================

SCHEME="http"

if nginx -T 2>/dev/null |
    grep -qE 'listen[[:space:]]+443([^;]*ssl|[[:space:]]+ssl)'; then
    SCHEME="https"
fi

PMA_PUBLIC_URL="${SCHEME}://${DOMAIN}${PMA_PATH}/"

echo
echo "============================================================"
echo "              INSTALLASI SELESAI"
echo "============================================================"
echo "Domain      : $DOMAIN"
echo "phpMyAdmin  : $PMA_PUBLIC_URL"
echo "PHP-FPM     : $PHP_FPM_SOCKET"
echo "Directory   : $PMA_DIR"
echo "Nginx       : $SERVER_FILE"
echo "Backup      : $BACKUP_FILE"
echo
echo "Login menggunakan USER DATABASE MariaDB/MySQL."
echo
echo "Tidak menggunakan:"
echo "- Domain hardcoded"
echo "- Port 8081"
echo "- Apache"
echo "- apt upgrade"
echo "============================================================"
