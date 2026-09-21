#!/usr/bin/env bash
set -e

# ============================================================
#             CIRGANTENG - PMA INSTALLER
#       PHPMyAdmin -> panel-domain.tld/pma
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PMA_DIR="/usr/share/phpmyadmin"
PMA_MARKER="# === CIRGANTENG-PMA-START ==="

clear

echo -e "${CYAN}"
echo "=================================================="
echo "             CIRGANTENG PMA INSTALLER"
echo "=================================================="
echo -e "${NC}"

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
    debian|ubuntu) ;;
    *)
        echo -e "${RED}[!] OS tidak didukung: $PRETTY_NAME${NC}"
        echo "    Support: Debian / Ubuntu"
        exit 1
        ;;
esac

echo -e "${GREEN}[✓] OS: $PRETTY_NAME${NC}"

# ============================================================
# CARI DOMAIN PANEL
# ============================================================

PTERO_DIR="/var/www/pterodactyl"
PTERO_ENV="$PTERO_DIR/.env"
PANEL_DOMAIN=""
NGINX_PANEL_CONF=""

if [ -f "$PTERO_ENV" ]; then
    PANEL_URL=$(grep -E '^APP_URL=' "$PTERO_ENV" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")

    if [ -n "$PANEL_URL" ]; then
        PANEL_DOMAIN=$(printf '%s' "$PANEL_URL" \
            | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s/:.*$//')
    fi
fi

if [ -z "$PANEL_DOMAIN" ]; then
    echo -e "${RED}[!] Domain panel tidak ditemukan dari APP_URL.${NC}"
    echo
    echo "Pastikan:"
    echo "  $PTERO_ENV"
    echo
    echo "memiliki contoh:"
    echo '  APP_URL="https://panel.domain.com"'
    exit 1
fi

# Cari konfigurasi nginx yang memiliki domain panel
for conf in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [ -f "$conf" ] || continue

    if grep -qE "server_name[[:space:]].*${PANEL_DOMAIN}" "$conf" 2>/dev/null; then
        NGINX_PANEL_CONF="$conf"
        break
    fi
done

# Fallback berdasarkan konfigurasi Pterodactyl
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
    echo -e "${RED}[!] Konfigurasi Nginx panel tidak ditemukan.${NC}"
    exit 1
fi

echo -e "${GREEN}[✓] Domain panel : $PANEL_DOMAIN${NC}"
echo -e "${GREEN}[✓] Nginx config : $NGINX_PANEL_CONF${NC}"

# ============================================================
# INSTALL DEPENDENCY
# ============================================================

export DEBIAN_FRONTEND=noninteractive

echo
echo -e "${YELLOW}[1/6] Update package...${NC}"

apt-get update -y

echo
echo -e "${YELLOW}[2/6] Install PHPMyAdmin...${NC}"

apt-get install -y \
    nginx \
    php \
    php-fpm \
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
    ca-certificates \
    phpmyadmin

if [ ! -d "$PMA_DIR" ]; then
    echo -e "${RED}[!] PHPMyAdmin gagal ditemukan.${NC}"
    exit 1
fi

echo -e "${GREEN}[✓] PHPMyAdmin terinstall.${NC}"

# ============================================================
# CARI PHP-FPM
# ============================================================

echo
echo -e "${YELLOW}[3/6] Mendeteksi PHP-FPM...${NC}"

PHP_SOCKET=""

for socket in /run/php/php*-fpm.sock; do
    if [ -S "$socket" ]; then
        PHP_SOCKET="$socket"
        break
    fi
done

if [ -z "$PHP_SOCKET" ]; then
    systemctl restart php*-fpm 2>/dev/null || true

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
# BACKUP NGINX
# ============================================================

echo
echo -e "${YELLOW}[4/6] Backup konfigurasi Nginx...${NC}"

BACKUP="${NGINX_PANEL_CONF}.cirganteng-backup-$(date +%Y%m%d-%H%M%S)"

cp -a "$NGINX_PANEL_CONF" "$BACKUP"

echo -e "${GREEN}[✓] Backup: $BACKUP${NC}"

# Hapus konfigurasi PMA lama jika pernah dipasang
if grep -q "$PMA_MARKER" "$NGINX_PANEL_CONF" 2>/dev/null; then
    sed -i \
        "/$PMA_MARKER/,/# === CIRGANTENG-PMA-END ===/d" \
        "$NGINX_PANEL_CONF"
fi

# ============================================================
# BUAT CONFIG /PMA
# ============================================================

echo
echo -e "${YELLOW}[5/6] Memasang PHPMyAdmin ke /pma...${NC}"

PMA_BLOCK=$(cat <<EOF
$PMA_MARKER

    # ========================================================
    # CIRGANTENG PHPMyAdmin
    # URL: https://$PANEL_DOMAIN/pma
    # ========================================================

    location /pma {
        alias $PMA_DIR;
        index index.php;
    }

    location ~ ^/pma/(.+\\.php)\$ {
        alias $PMA_DIR/\$1;

        include snippets/fastcgi-php.conf;

        fastcgi_param SCRIPT_FILENAME $PMA_DIR/\$1;
        fastcgi_param SCRIPT_NAME /pma/\$1;
        fastcgi_param REQUEST_URI \$request_uri;

        fastcgi_pass unix:$PHP_SOCKET;
    }

    location ~ ^/pma/(.+\\.(css|js|jpg|jpeg|gif|png|ico|svg|woff|woff2|ttf|html|xml|txt))\$ {
        alias $PMA_DIR/\$1;
    }

    # === CIRGANTENG-PMA-END ===

EOF
)

python3 - "$NGINX_PANEL_CONF" "$PMA_BLOCK" <<'PY'
import sys

path = sys.argv[1]
block = sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

pos = data.rfind("}")

if pos == -1:
    raise SystemExit("Penutup konfigurasi Nginx tidak ditemukan.")

data = data[:pos] + "\n" + block + data[pos:]

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY

# ============================================================
# TEST NGINX
# ============================================================

echo
echo -e "${YELLOW}[6/6] Test & restart Nginx...${NC}"

if ! nginx -t; then
    echo
    echo -e "${RED}[!] Nginx ERROR.${NC}"
    echo "Mengembalikan konfigurasi backup..."

    cp -f "$BACKUP" "$NGINX_PANEL_CONF"

    nginx -t || true

    exit 1
fi

systemctl restart nginx

for service_file in /etc/systemd/system/php*-fpm.service \
                    /lib/systemd/system/php*-fpm.service; do

    [ -e "$service_file" ] || continue

    service_name=$(basename "$service_file")

    systemctl restart "$service_name" 2>/dev/null || true
done

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
echo "https://$PANEL_DOMAIN/pma"

echo
echo -e "${YELLOW}Login menggunakan akun MySQL/MariaDB.${NC}"

echo
echo -e "${CYAN}Backup Nginx:${NC}"
echo "$BACKUP"

echo
echo "=================================================="
