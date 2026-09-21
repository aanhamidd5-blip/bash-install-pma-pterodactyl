#!/usr/bin/env bash
set -e

# ============================================================
#              CIRGANTENG - PMA INSTALLER
#        PHPMyAdmin -> https://PANEL-DOMAIN/pma
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PTERO_DIR="/var/www/pterodactyl"
PTERO_ENV="$PTERO_DIR/.env"
PMA_DIR="/usr/share/phpmyadmin"
BACKUP_DIR="/root/cirganteng-pma-backups"

clear

echo -e "${CYAN}"
echo "=================================================="
echo "          CIRGANTENG PMA INSTALLER"
echo "=================================================="
echo -e "${NC}"

# ============================================================
# ROOT CHECK
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[!] Jalankan sebagai root.${NC}"
    exit 1
fi

# ============================================================
# OS CHECK
# ============================================================

if [ ! -f /etc/os-release ]; then
    echo -e "${RED}[!] OS tidak dapat dideteksi.${NC}"
    exit 1
fi

. /etc/os-release

case "$ID" in
    ubuntu|debian)
        ;;
    *)
        echo -e "${RED}[!] OS tidak didukung: $PRETTY_NAME${NC}"
        echo "    Support: Ubuntu / Debian"
        exit 1
        ;;
esac

echo -e "${GREEN}[✓] OS: $PRETTY_NAME${NC}"

# ============================================================
# CEK PTERODACTYL
# ============================================================

if [ ! -f "$PTERO_ENV" ]; then
    echo -e "${RED}[!] Pterodactyl tidak ditemukan:${NC}"
    echo "$PTERO_ENV"
    exit 1
fi

# ============================================================
# AMBIL DOMAIN DARI APP_URL
# ============================================================

PANEL_URL=$(grep -E '^APP_URL=' "$PTERO_ENV" | head -1 | cut -d= -f2-)
PANEL_URL=$(printf '%s' "$PANEL_URL" | tr -d '"' | tr -d "'")

if [ -z "$PANEL_URL" ]; then
    echo -e "${RED}[!] APP_URL tidak ditemukan.${NC}"
    exit 1
fi

PANEL_DOMAIN=$(printf '%s' "$PANEL_URL" \
    | sed -E 's#^[a-zA-Z]+://##' \
    | sed -E 's#/.*$##' \
    | sed -E 's/:.*$//')

if [ -z "$PANEL_DOMAIN" ]; then
    echo -e "${RED}[!] Domain panel gagal dibaca.${NC}"
    exit 1
fi

echo -e "${GREEN}[✓] Domain panel: $PANEL_DOMAIN${NC}"

# ============================================================
# CEK / INSTALL NGINX
# ============================================================

if ! command -v nginx >/dev/null 2>&1; then
    echo -e "${YELLOW}[!] Nginx belum ada. Menginstall...${NC}"

    apt-get update -y
    apt-get install -y nginx
fi

# ============================================================
# CARI CONFIG NGINX PANEL
# ============================================================

NGINX_CONF=""

for conf in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [ -f "$conf" ] || continue

    if grep -qE "server_name[[:space:]].*${PANEL_DOMAIN}" "$conf" 2>/dev/null; then
        NGINX_CONF="$conf"
        break
    fi
done

if [ -z "$NGINX_CONF" ]; then
    for conf in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
        [ -f "$conf" ] || continue

        if grep -qE '/var/www/pterodactyl|pterodactyl' "$conf" 2>/dev/null; then
            NGINX_CONF="$conf"
            break
        fi
    done
fi

if [ -z "$NGINX_CONF" ]; then
    echo -e "${RED}[!] Config Nginx Pterodactyl tidak ditemukan.${NC}"
    exit 1
fi

echo -e "${GREEN}[✓] Config Nginx: $NGINX_CONF${NC}"

# ============================================================
# BACKUP
# ============================================================

mkdir -p "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/pterodactyl-$(date +%Y%m%d-%H%M%S).bak"

cp -a "$NGINX_CONF" "$BACKUP_FILE"

echo -e "${GREEN}[✓] Backup dibuat:${NC}"
echo "$BACKUP_FILE"

# ============================================================
# INSTALL PHPMyAdmin
# ============================================================

echo
echo -e "${YELLOW}[1/6] Install PHPMyAdmin...${NC}"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y

apt-get install -y \
    phpmyadmin \
    php-mysql \
    php-mbstring \
    php-zip \
    php-gd \
    php-curl \
    php-xml \
    php-bcmath \
    php-intl \
    php-fpm \
    curl \
    ca-certificates

if [ ! -d "$PMA_DIR" ]; then
    echo -e "${RED}[!] PHPMyAdmin gagal terinstall.${NC}"
    exit 1
fi

echo -e "${GREEN}[✓] PHPMyAdmin terinstall.${NC}"

# ============================================================
# CARI PHP-FPM SOCKET
# ============================================================

echo
echo -e "${YELLOW}[2/6] Mendeteksi PHP-FPM...${NC}"

PHP_SOCKET=""

for socket in /run/php/php*-fpm.sock; do
    if [ -S "$socket" ]; then
        PHP_SOCKET="$socket"
        break
    fi
done

if [ -z "$PHP_SOCKET" ]; then

    echo -e "${YELLOW}[!] Socket PHP-FPM belum ditemukan.${NC}"
    echo "    Mencoba restart PHP-FPM..."

    for service in php8.4-fpm php8.3-fpm php8.2-fpm php8.1-fpm; do
        systemctl restart "$service" 2>/dev/null || true
    done

    for socket in /run/php/php*-fpm.sock; do
        if [ -S "$socket" ]; then
            PHP_SOCKET="$socket"
            break
        fi
    done
fi

if [ -z "$PHP_SOCKET" ]; then
    echo -e "${RED}[!] PHP-FPM socket tidak ditemukan.${NC}"
    exit 1
fi

echo -e "${GREEN}[✓] PHP-FPM: $PHP_SOCKET${NC}"

# ============================================================
# HAPUS CONFIG PMA LAMA
# ============================================================

echo
echo -e "${YELLOW}[3/6] Membersihkan konfigurasi PMA lama...${NC}"

python3 - "$NGINX_CONF" <<'PY'
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

pairs = [
    ("# CIRGANTENG-PMA-START", "# CIRGANTENG-PMA-END"),
    ("# === CIRGANTENG-PMA-START ===", "# === CIRGANTENG-PMA-END ==="),
    ("# === CIRGANTENG-PMA-START ===", "# CIRGANTENG-PMA-END"),
]

changed = False

for start_marker, end_marker in pairs:
    while start_marker in data:

        start = data.find(start_marker)

        line_start = data.rfind("\n", 0, start) + 1

        end = data.find(end_marker, start)

        if end == -1:
            break

        end += len(end_marker)

        if end < len(data) and data[end] == "\n":
            end += 1

        data = data[:line_start] + data[end:]

        changed = True

with open(path, "w", encoding="utf-8") as f:
    f.write(data)

if changed:
    print("[✓] Config PMA lama dibersihkan.")
else:
    print("[✓] Tidak ada config PMA lama.")
PY

# ============================================================
# PASANG ROUTE /PMA
# ============================================================

echo
echo -e "${YELLOW}[4/6] Memasang route /pma...${NC}"

python3 - "$NGINX_CONF" "$PHP_SOCKET" "$PMA_DIR" <<'PY'
import sys

path = sys.argv[1]
php_socket = sys.argv[2]
pma_dir = sys.argv[3]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

# Cari server block
server_pos = data.find("server")

if server_pos == -1:
    raise SystemExit("server block tidak ditemukan.")

open_pos = data.find("{", server_pos)

if open_pos == -1:
    raise SystemExit("Pembuka server block tidak ditemukan.")

depth = 0
close_pos = -1

in_comment = False
in_single = False
in_double = False
escape = False

i = open_pos

while i < len(data):

    c = data[i]

    if in_comment:
        if c == "\n":
            in_comment = False

        i += 1
        continue

    if in_single:

        if escape:
            escape = False

        elif c == "\\":
            escape = True

        elif c == "'":
            in_single = False

        i += 1
        continue

    if in_double:

        if escape:
            escape = False

        elif c == "\\":
            escape = True

        elif c == '"':
            in_double = False

        i += 1
        continue

    if c == "#":
        in_comment = True
        i += 1
        continue

    if c == "'":
        in_single = True
        i += 1
        continue

    if c == '"':
        in_double = True
        i += 1
        continue

    if c == "{":
        depth += 1

    elif c == "}":

        depth -= 1

        if depth == 0:
            close_pos = i
            break

    i += 1

if close_pos == -1:
    raise SystemExit("Closing server block tidak ditemukan.")

block = f'''

    # CIRGANTENG-PMA-START

    # PHPMyAdmin
    # URL: /pma/

    location = /pma {{
        return 301 /pma/;
    }}

    location /pma/ {{
        alias {pma_dir}/;
        index index.php;
    }}

    location ~ ^/pma/(.+\\.php)$ {{
        alias {pma_dir}/$1;

        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME {pma_dir}/$1;
        fastcgi_param SCRIPT_NAME /pma/$1;
        fastcgi_param REQUEST_URI $request_uri;

        fastcgi_pass unix:{php_socket};
    }}

    # CIRGANTENG-PMA-END
'''

data = data[:close_pos] + block + "\n" + data[close_pos:]

with open(path, "w", encoding="utf-8") as f:
    f.write(data)

print("[✓] Route /pma berhasil dipasang.")
PY

# ============================================================
# PERMISSION
# ============================================================

echo
echo -e "${YELLOW}[5/6] Menyiapkan permission...${NC}"

chown -R root:root "$PMA_DIR"

find "$PMA_DIR" -type d -exec chmod 755 {} \;
find "$PMA_DIR" -type f -exec chmod 644 {} \;

echo -e "${GREEN}[✓] Permission selesai.${NC}"

# ============================================================
# TEST NGINX
# ============================================================

echo
echo -e "${YELLOW}[6/6] Test konfigurasi Nginx...${NC}"

if ! nginx -t; then

    echo
    echo -e "${RED}=================================================="
    echo " NGINX ERROR - ROLLBACK"
    echo "==================================================${NC}"

    cp -f "$BACKUP_FILE" "$NGINX_CONF"

    echo
    echo "Config dikembalikan ke backup:"
    echo "$BACKUP_FILE"

    nginx -t || true

    exit 1
fi

echo -e "${GREEN}[✓] Nginx configuration OK.${NC}"

# ============================================================
# RESTART PHP-FPM
# ============================================================

for service in php8.4-fpm php8.3-fpm php8.2-fpm php8.1-fpm; do

    if systemctl list-unit-files "$service" >/dev/null 2>&1; then
        systemctl restart "$service" 2>/dev/null || true
    fi

done

# ============================================================
# RELOAD NGINX
# ============================================================

systemctl enable nginx >/dev/null 2>&1 || true
systemctl reload nginx

# ============================================================
# SELESAI
# ============================================================

echo
echo -e "${GREEN}"
echo "=================================================="
echo "       CIRGANTENG PMA BERHASIL DIPASANG"
echo "=================================================="
echo -e "${NC}"

echo
echo -e "${CYAN}Panel:${NC}"
echo "https://$PANEL_DOMAIN"

echo
echo -e "${CYAN}PHPMyAdmin:${NC}"
echo "https://$PANEL_DOMAIN/pma/"

echo
echo -e "${CYAN}PHP-FPM:${NC}"
echo "$PHP_SOCKET"

echo
echo -e "${CYAN}Backup Nginx:${NC}"
echo "$BACKUP_FILE"

echo
echo -e "${GREEN}Selesai.${NC}"
