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
die(){ echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Jalankan sebagai root."

echo "============================================================"
echo "       CIRGANTENG - FINAL PHPMYADMIN INSTALLER - NO AWK - PHP 8.3"
echo "============================================================"

command -v nginx >/dev/null 2>&1 || die "Nginx belum terinstall."
systemctl is-active --quiet nginx || die "Nginx tidak aktif."

ok "Nginx aktif."

mkdir -p "$BACKUP_DIR"

# ============================================================
# DETEKSI CONFIG NGINX
# ============================================================

SERVER_FILE=""

for FILE in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [[ -f "$FILE" ]] || continue

    if grep -qE '^[[:space:]]*server_name[[:space:]]+' "$FILE" 2>/dev/null; then
        SERVER_FILE="$FILE"
        break
    fi
done

[[ -n "$SERVER_FILE" ]] || die "Config Nginx dengan server_name tidak ditemukan."

ok "Config Nginx : $SERVER_FILE"

# ============================================================
# DETEKSI DOMAIN TANPA AWK
# ============================================================

DOMAIN="$(
    grep -hE '^[[:space:]]*server_name[[:space:]]+' "$SERVER_FILE" 2>/dev/null |
    head -n1 |
    sed -E 's/^[[:space:]]*server_name[[:space:]]+//' |
    sed -E 's/[;[:space:]].*$//' |
    sed 's/^\*\.//' |
    tr -d '\r'
)"

[[ -n "$DOMAIN" ]] || die "Domain tidak ditemukan dari server_name."

case "$DOMAIN" in
    "_"|"localhost"|"127.0.0.1"|"0.0.0.0"|"*")
        die "server_name tidak berisi domain publik: $DOMAIN"
        ;;
esac

ok "Domain terdeteksi : $DOMAIN"

# ============================================================
# PHP 8.3
# ============================================================

PHP_VERSION="8.3"
PHP_BIN="/usr/bin/php8.3"
PHP_FPM_SOCKET="/run/php/php8.3-fpm.sock"

command -v "$PHP_BIN" >/dev/null 2>&1 ||
    die "PHP 8.3 tidak ditemukan."

[[ -S "$PHP_FPM_SOCKET" ]] ||
    die "Socket PHP-FPM 8.3 tidak ditemukan: $PHP_FPM_SOCKET"

systemctl is-active --quiet php8.3-fpm ||
    die "php8.3-fpm tidak aktif."

ok "PHP CLI  : $("$PHP_BIN" -r 'echo PHP_VERSION;')"
ok "PHP-FPM  : $PHP_FPM_SOCKET"

# ============================================================
# CEK EXTENSION PHP 8.3
# ============================================================

log "Cek extension PHP 8.3..."

MISSING=()

for EXT in mysqli mbstring zip; do
    if "$PHP_BIN" -r "exit(extension_loaded('$EXT') ? 0 : 1);"; then
        ok "Extension $EXT tersedia"
    else
        warn "Extension $EXT belum tersedia"
        MISSING+=("$EXT")
    fi
done

# ============================================================
# INSTALL EXTENSION JIKA KURANG
# ============================================================

if (( ${#MISSING[@]} > 0 )); then
    log "Menginstall extension PHP 8.3..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -o Acquire::Retries=3

    PACKAGES=()

    for EXT in "${MISSING[@]}"; do
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

    apt-get install -y --no-install-recommends "${PACKAGES[@]}"

    systemctl restart php8.3-fpm

    log "Verifikasi extension..."

    for EXT in mysqli mbstring zip; do
        "$PHP_BIN" -r "exit(extension_loaded('$EXT') ? 0 : 1);" ||
            die "Extension $EXT masih belum aktif setelah instalasi."

        ok "Extension $EXT aktif"
    done
else
    ok "Semua extension utama tersedia."
fi

# ============================================================
# BACKUP NGINX
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
    die "Download phpMyAdmin gagal."

ok "Download berhasil."

tar -tzf "$PMA_ARCHIVE" >/dev/null 2>&1 ||
    die "Archive phpMyAdmin tidak valid."

ok "Archive valid."

# ============================================================
# INSTALL PHPMYADMIN
# ============================================================

TMP_EXTRACT="$(mktemp -d)"

cleanup(){
    rm -rf "$TMP_EXTRACT"
}
trap cleanup EXIT

tar -xzf "$PMA_ARCHIVE" -C "$TMP_EXTRACT"

PMA_SOURCE="$(
    find "$TMP_EXTRACT" \
        -maxdepth 1 \
        -type d \
        -name 'phpMyAdmin-*' |
    head -n1
)"

[[ -d "$PMA_SOURCE" ]] ||
    die "Folder phpMyAdmin tidak ditemukan."

rm -rf "$PMA_DIR"

mkdir -p "$PMA_DIR"

cp -a "$PMA_SOURCE"/. "$PMA_DIR"/

mkdir -p "$PMA_TMP"

chown -R www-data:www-data "$PMA_TMP"

rm -f "$PMA_ARCHIVE"

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
# TANPA AWK
# ============================================================

if grep -q "CIRGANTENG-PMA-START" "$SERVER_FILE" 2>/dev/null; then
    warn "Konfigurasi PMA lama ditemukan. Membersihkan block lama."

    python3 - "$SERVER_FILE" <<'PY'
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text()

start = s.find("    # CIRGANTENG-PMA-START")
end = s.find("    # CIRGANTENG-PMA-END")

if start != -1 and end != -1:
    end += len("    # CIRGANTENG-PMA-END")
    s = s[:start] + s[end:]

p.write_text(s)
PY
fi

if ! command -v python3 >/dev/null 2>&1; then
    die "python3 diperlukan untuk update konfigurasi Nginx."
fi

python3 - "$SERVER_FILE" <<'PY'
import sys
import re
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

if "CIRGANTENG-PMA-START" in text:
    raise SystemExit("Block PMA masih terdeteksi.")

match = re.search(
    r'(?m)^[ \t]*server\s*\{',
    text
)

if not match:
    raise SystemExit("Block server Nginx tidak ditemukan.")

start = match.end()

block = r'''
    # CIRGANTENG-PMA-START

    location = /pma {
        return 301 /pma/;
    }

    location ^~ /pma/ {
        alias /usr/share/phpmyadmin/;
        index index.php;
    }

    location ~ ^/pma/(.+\.php)$ {
        alias /usr/share/phpmyadmin/$1;

        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME /usr/share/phpmyadmin/$1;
        fastcgi_param SCRIPT_NAME /pma/$1;

        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    # CIRGANTENG-PMA-END
'''

text = text[:start] + "\n" + block + text[start:]

path.write_text(text)
PY

ok "Konfigurasi Nginx /pma/ dibuat."

# ============================================================
# TEST NGINX
# ============================================================

log "Test konfigurasi Nginx..."

if ! nginx -t; then
    warn "Nginx gagal. Mengembalikan backup..."

    cp -a "$BACKUP_FILE" "$SERVER_FILE"

    nginx -t || true

    die "Konfigurasi Nginx gagal dan sudah dikembalikan."
fi

ok "Nginx syntax OK."

systemctl reload nginx

ok "Nginx reload berhasil."

# ============================================================
# TEST LOCAL
# ============================================================

log "Test phpMyAdmin local..."

HTTP_CODE="$(
    curl -ksS \
        -o /dev/null \
        -w '%{http_code}' \
        "https://127.0.0.1/pma/" \
        -H "Host: $DOMAIN" \
    || true
)"

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" ]]; then
    ok "phpMyAdmin local HTTP $HTTP_CODE"
else
    warn "HTTP local: $HTTP_CODE"
    warn "Cek manual: curl -kI https://$DOMAIN/pma/"
fi

echo
echo "============================================================"
echo "              INSTALLASI SELESAI"
echo "============================================================"
echo "phpMyAdmin : https://$DOMAIN/pma/"
echo "Panel      : https://$DOMAIN"
echo "PHP-FPM    : $PHP_FPM_SOCKET"
echo "Directory  : $PMA_DIR"
echo "Backup     : $BACKUP_FILE"
echo
echo "Login phpMyAdmin menggunakan USER DATABASE MariaDB/MySQL."
echo
echo "Catatan:"
echo "- PHP CLI installer dipaksa menggunakan PHP 8.3."
echo "- Extension dicek dengan extension_loaded()."
echo "- Tidak menggunakan awk."
echo "- Tidak menggunakan port 8081."
echo "- Tidak menginstall Apache."
echo "- Tidak menjalankan apt upgrade."
echo "============================================================"
