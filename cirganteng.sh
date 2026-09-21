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

PMA_DIR="/usr/share/phpmyadmin"
PMA_MARKER="CIRGANTENG-PMA-START"
BACKUP_DIR="/root/cirganteng-pma-backups"

clear

echo -e "${CYAN}"
echo "=================================================="
echo "             CIRGANTENG PMA INSTALLER"
echo "=================================================="
echo -e "${NC}"

# ============================================================
# ROOT CHECK
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[!] Jalankan sebagai root.${NC}"
    exit 1
fi

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
# CEK NGINX
# ============================================================

if ! command -v nginx >/dev/null 2>&1; then
    echo -e "${YELLOW}[!] Nginx belum ada. Menginstall...${NC}"
    apt-get update -y
    apt-get install -y nginx
fi

# ============================================================
# CARI DOMAIN PTERODACTYL
# ============================================================

PTERO_DIR="/var/www/pterodactyl"
PTERO_ENV="$PTERO_DIR/.env"
PANEL_DOMAIN=""

if [ ! -f "$PTERO_ENV" ]; then
    echo -e "${RED}[!] File Pterodactyl tidak ditemukan:${NC}"
    echo "$PTERO_ENV"
    exit 1
fi

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

echo -e "${GREEN}[✓] Domain panel : $PANEL_DOMAIN${NC}"

# ============================================================
# CARI CONFIG NGINX PANEL
# ============================================================

NGINX_PANEL_CONF=""

for conf in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [ -f "$conf" ] || continue

    if grep -qE "server_name[[:space:]].*${PANEL_DOMAIN}" "$conf" 2>/dev/null; then
        NGINX_PANEL_CONF="$conf"
        break
    fi
done

if [ -z "$NGINX_PANEL_CONF" ]; then
    for conf in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
        [ -f "$conf" ] || continue

        if grep -qE 'pterodactyl|/var/www/pterodactyl|public/index.php' "$conf" 2>/dev/null; then
            NGINX_PANEL_CONF="$conf"
            break
        fi
    done
fi

if [ -z "$NGINX_PANEL_CONF" ]; then
    echo -e "${RED}[!] Config Nginx Pterodactyl tidak ditemukan.${NC}"
    exit 1
fi

echo -e "${GREEN}[✓] Nginx config : $NGINX_PANEL_CONF${NC}"

# ============================================================
# BACKUP
# ============================================================

mkdir -p "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/pterodactyl.conf.$(date +%Y%m%d-%H%M%S).bak"

cp -a "$NGINX_PANEL_CONF" "$BACKUP_FILE"

echo -e "${GREEN}[✓] Backup dibuat:${NC}"
echo "$BACKUP_FILE"

# ============================================================
# UPDATE PACKAGE
# ============================================================

echo
echo -e "${YELLOW}[1/7] Update package...${NC}"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y

# ============================================================
# CATAT STATUS APACHE
# ============================================================

APACHE_EXISTED="no"

if dpkg-query -W -f='${Status}' apache2 2>/dev/null | grep -q "install ok installed"; then
    APACHE_EXISTED="yes"
fi

# ============================================================
# INSTALL PHP + PHPMYADMIN
# ============================================================

echo
echo -e "${YELLOW}[2/7] Install PHPMyAdmin...${NC}"

apt-get install -y --no-install-recommends \
    phpmyadmin \
    php-mysql \
    php-mbstring \
    php-zip \
    php-gd \
    php-curl \
    php-xml \
    php-bcmath \
    php-intl \
    unzip \
    curl \
    ca-certificates

# Pastikan PHP-FPM tersedia
apt-get install -y --no-install-recommends php-fpm

if [ ! -d "$PMA_DIR" ]; then
    echo -e "${RED}[!] PHPMyAdmin gagal terinstall.${NC}"
    exit 1
fi

echo -e "${GREEN}[✓] PHPMyAdmin terinstall.${NC}"

# ============================================================
# MATIKAN APACHE JIKA TERPASANG OLEH INSTALLER
# ============================================================

if [ "$APACHE_EXISTED" = "no" ] && dpkg-query -W -f='${Status}' apache2 2>/dev/null | grep -q "install ok installed"; then

    echo
    echo -e "${YELLOW}[3/7] Menghapus Apache yang ikut terpasang...${NC}"

    systemctl stop apache2 2>/dev/null || true
    systemctl disable apache2 2>/dev/null || true

    apt-get purge -y \
        apache2 \
        apache2-bin \
        apache2-data \
        apache2-utils \
        libapache2-mod-php8.4 \
        libapache2-mod-php8.3 \
        2>/dev/null || true

    apt-get autoremove -y 2>/dev/null || true

    echo -e "${GREEN}[✓] Apache tidak digunakan.${NC}"

else
    echo
    echo -e "${YELLOW}[3/7] Apache tidak diubah.${NC}"
fi

# ============================================================
# CARI PHP-FPM SOCKET
# ============================================================

echo
echo -e "${YELLOW}[4/7] Mendeteksi PHP-FPM...${NC}"

PHP_SOCKET=""

# Cari socket aktif
for socket in /run/php/php*-fpm.sock; do
    if [ -S "$socket" ]; then
        PHP_SOCKET="$socket"
        break
    fi
done

if [ -z "$PHP_SOCKET" ]; then
    echo -e "${YELLOW}[!] PHP-FPM socket belum ditemukan, mencoba restart...${NC}"

    systemctl restart php8.4-fpm 2>/dev/null || true
    systemctl restart php8.3-fpm 2>/dev/null || true
    systemctl restart php8.2-fpm 2>/dev/null || true
    systemctl restart php8.1-fpm 2>/dev/null || true

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
echo -e "${YELLOW}[5/7] Menyiapkan konfigurasi /pma...${NC}"

python3 - "$NGINX_PANEL_CONF" "$PMA_MARKER" <<'PY'
import sys

path = sys.argv[1]
marker = sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

start = data.find(marker)

if start != -1:
    start = data.rfind("#", 0, start)

    end_marker = "# CIRGANTENG-PMA-END"

    end = data.find(end_marker, start)

    if end != -1:
        end = data.find("\n", end)

        if end == -1:
            end = len(data)

        data = data[:start] + data[end + 1:]

        with open(path, "w", encoding="utf-8") as f:
            f.write(data)

        print("[✓] Config PMA lama dihapus.")
    else:
        print("[!] Marker lama tidak lengkap, tidak diubah.")
else:
    print("[✓] Tidak ada config PMA lama.")
PY

# ============================================================
# MASUKKAN LOCATION KE DALAM SERVER BLOCK
# ============================================================

echo -e "${YELLOW}[6/7] Memasang route /pma ke Nginx...${NC}"

python3 - "$NGINX_PANEL_CONF" "$PHP_SOCKET" "$PMA_DIR" "$PMA_MARKER" <<'PY'
import sys

path = sys.argv[1]
php_socket = sys.argv[2]
pma_dir = sys.argv[3]
marker = sys.argv[4]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

block = f'''
    # {marker}

    # PHPMyAdmin CIRGANTENG
    # URL: /pma

    location = /pma {{
        return 301 /pma/;
    }}

    location /pma/ {{
        alias {pma_dir}/;
        index index.php;
    }}

    location ~ ^/pma/(.+\\.php)$ {{
        alias {pma_dir}/$1;

        include snippets/fastcgi-php.conf;

        fastcgi_param SCRIPT_FILENAME {pma_dir}/$1;
        fastcgi_param SCRIPT_NAME /pma/$1;
        fastcgi_param REQUEST_URI $request_uri;

        fastcgi_pass unix:{php_socket};
    }}

    location ~ ^/pma/(.+\\.(?:css|js|jpg|jpeg|gif|png|ico|svg|woff|woff2|ttf|html|xml|txt))$ {{
        alias {pma_dir}/$1;
    }}

    # CIRGANTENG-PMA-END
'''

# ------------------------------------------------------------
# Cari server { pertama dan matching closing brace.
# Mengabaikan komentar dan string sederhana.
# ------------------------------------------------------------

server_start = data.find("server")
if server_start == -1:
    raise SystemExit("server block tidak ditemukan.")

brace_start = data.find("{", server_start)
if brace_start == -1:
    raise SystemExit("Pembuka server block tidak ditemukan.")

depth = 0
in_single = False
in_double = False
in_comment = False
escape = False
end_pos = -1

i = brace_start

while i < len(data):
    c = data[i]
    n = data[i + 1] if i + 1 < len(data) else ""

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

    if c == "#" :
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
            end_pos = i
            break

    i += 1

if end_pos == -1:
    raise SystemExit("Closing server block tidak ditemukan.")

new_data = data[:end_pos] + "\n" + block + "\n" + data[end_pos:]

with open(path, "w", encoding="utf-8") as f:
    f.write(new_data)

print("[✓] Route /pma berhasil dimasukkan.")
PY

# ============================================================
# TEST NGINX
# ============================================================

echo
echo -e "${YELLOW}[7/7] Test konfigurasi Nginx...${NC}"

if ! nginx -t; then

    echo
    echo -e "${RED}=================================================="
    echo "[!] NGINX ERROR"
    echo "==================================================${NC}"

    echo
    echo "Rollback otomatis..."

    cp -f "$BACKUP_FILE" "$NGINX_PANEL_CONF"

    nginx -t || true

    echo
    echo -e "${YELLOW}Backup:${NC}"
    echo "$BACKUP_FILE"

    exit 1
fi

echo -e "${GREEN}[✓] Nginx configuration OK.${NC}"

# ============================================================
# RESTART PHP-FPM
# ============================================================

for service in php8.4-fpm php8.3-fpm php8.2-fpm php8.1-fpm; do
    if systemctl list-unit-files "$service" 2>/dev/null | grep -q "$service"; then
        systemctl restart "$service" 2>/dev/null || true
    fi
done

# ============================================================
# RESTART NGINX
# ============================================================

systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

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
echo -e "${YELLOW}Login menggunakan akun MySQL/MariaDB.${NC}"

echo
echo -e "${CYAN}Backup Nginx:${NC}"
echo "$BACKUP_FILE"

echo
echo "=================================================="
