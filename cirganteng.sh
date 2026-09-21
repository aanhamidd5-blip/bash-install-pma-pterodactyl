#!/usr/bin/env bash
set -e

# ============================================================
#                  CIRGANTENG - PMA INSTALLER
#        PHPMyAdmin installer for Debian / Ubuntu
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PMA_DIR="/usr/share/phpmyadmin"
PMA_CONF="/etc/nginx/snippets/phpmyadmin.conf"
NGINX_CONF="/etc/nginx/sites-enabled/phpmyadmin.conf"
PMA_PORT="8081"

clear

echo -e "${CYAN}"
echo "=================================================="
echo "              CIRGANTENG PMA INSTALLER"
echo "=================================================="
echo -e "${NC}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[!] Jalankan script sebagai root.${NC}"
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    echo -e "${RED}[!] OS tidak dapat dideteksi.${NC}"
    exit 1
fi

. /etc/os-release

case "$ID" in
    debian|ubuntu)
        ;;
    *)
        echo -e "${RED}[!] OS tidak didukung: $PRETTY_NAME${NC}"
        echo "    Support: Debian / Ubuntu"
        exit 1
        ;;
esac

echo -e "${GREEN}[✓] OS: $PRETTY_NAME${NC}"

export DEBIAN_FRONTEND=noninteractive

echo
echo -e "${YELLOW}[1/7] Update package...${NC}"
apt-get update -y

echo
echo -e "${YELLOW}[2/7] Install dependency...${NC}"
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
    wget \
    ca-certificates

echo
echo -e "${YELLOW}[3/7] Install PHPMyAdmin...${NC}"
apt-get install -y phpmyadmin

if [ ! -d "$PMA_DIR" ]; then
    echo -e "${RED}[!] PHPMyAdmin gagal ditemukan setelah instalasi.${NC}"
    exit 1
fi

echo -e "${GREEN}[✓] PHPMyAdmin terinstall.${NC}"

echo
echo -e "${YELLOW}[4/7] Mendeteksi PHP-FPM socket...${NC}"

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

echo
echo -e "${YELLOW}[5/7] Membuat konfigurasi Nginx...${NC}"

mkdir -p /etc/nginx/snippets

cat > "$PMA_CONF" <<EOF
# CIRGANTENG PHPMyAdmin
location /phpmyadmin {
    alias $PMA_DIR;
    index index.php;

    location ~ ^/phpmyadmin/(.+\.php)$ {
        alias $PMA_DIR/\$1;
        include snippets/fastcgi-php.conf;
        fastcgi_param SCRIPT_FILENAME $PMA_DIR/\$1;
        fastcgi_pass unix:$PHP_SOCKET;
    }

    location ~ ^/phpmyadmin/(.+\.(jpg|jpeg|gif|css|png|js|ico|html|xml|txt|svg|woff|woff2|ttf))$ {
        alias $PMA_DIR/\$1;
    }
}
EOF

cat > "$NGINX_CONF" <<EOF
# CIRGANTENG PHPMyAdmin
server {
    listen $PMA_PORT;
    listen [::]:$PMA_PORT;

    server_name _;

    root $PMA_DIR;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCKET;
    }

    location ~* \.(css|js|jpg|jpeg|gif|png|ico|svg|woff|woff2|ttf)$ {
        try_files \$uri =404;
    }
}
EOF

echo
echo -e "${YELLOW}[6/7] Test konfigurasi Nginx...${NC}"

if ! nginx -t; then
    echo -e "${RED}[!] Konfigurasi Nginx error.${NC}"
    exit 1
fi

echo -e "${GREEN}[✓] Nginx config valid.${NC}"

echo
echo -e "${YELLOW}[7/7] Restart service...${NC}"

systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

for service in /etc/systemd/system/php*-fpm.service /lib/systemd/system/php*-fpm.service; do
    [ -e "$service" ] || continue
    service_name=$(basename "$service")
    systemctl restart "$service_name" 2>/dev/null || true
done

if command -v ufw >/dev/null 2>&1; then
    ufw allow ${PMA_PORT}/tcp >/dev/null 2>&1 || true
fi

SERVER_IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

echo
echo -e "${GREEN}"
echo "=================================================="
echo "           CIRGANTENG PMA SELESAI"
echo "=================================================="
echo -e "${NC}"
echo
echo "PHPMyAdmin : $PMA_DIR"
echo "Port       : $PMA_PORT"
echo
echo -e "${CYAN}Akses:${NC}"
echo "http://${SERVER_IP}:${PMA_PORT}"
echo
echo -e "${YELLOW}Login menggunakan akun database MySQL/MariaDB.${NC}"
echo
echo "=================================================="
