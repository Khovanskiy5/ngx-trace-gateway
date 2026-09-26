#!/usr/bin/env bash
# Создаёт новый сайт из шаблона sites-available/default.
#
#   scripts/new-site.sh <имя> <домен> <upstream-адрес>
#   scripts/new-site.sh shop shop.example.com shop-app:8080
#
# Имена upstream глобальны для всего http{}, поэтому группа получает префикс
# сайта (shop_backend). Пути include, root и server_name заменяются, веб-корень
# создаётся в rootfs/var/www/<имя>/public, сайт включается файлом
# sites-enabled/<имя>.conf. После — `make reload`.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

name="${1:-}"; domain="${2:-}"; upstream="${3:-}"
if ! [[ "$name" =~ ^[a-z][a-z0-9_]{0,31}$ ]] || [ -z "$domain" ] || [ -z "$upstream" ]; then
    echo "Использование: $0 <имя: [a-z][a-z0-9_]*> <домен> <upstream host:port>" >&2
    exit 2
fi

src=rootfs/etc/nginx/sites-available/default
dst=rootfs/etc/nginx/sites-available/$name
if [ -e "$dst" ]; then
    echo "Сайт $name уже существует: $dst" >&2
    exit 1
fi

cp -R "$src" "$dst"
for f in "$dst"/*.conf; do
    sed -e "s#/etc/nginx/sites-available/default/#/etc/nginx/sites-available/$name/#g" \
        -e "s#backend_upstream#${name}_backend#g" \
        -e "s#server_name localhost 127.0.0.1;#server_name $domain;#g" \
        -e "s#server_name localhost;#server_name $domain;#g" \
        -e "s#/var/www/default/public#/var/www/$name/public#g" \
        -e "s#server backend:8080 resolve#server $upstream resolve#g" \
        "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

mkdir -p "rootfs/var/www/$name/public"
[ -e "rootfs/var/www/$name/public/index.html" ] || \
    printf '<!DOCTYPE html>\n<html lang="ru"><head><meta charset="utf-8"><title>%s</title></head><body><h1>%s</h1></body></html>\n' "$domain" "$domain" \
    > "rootfs/var/www/$name/public/index.html"

printf 'include /etc/nginx/sites-available/%s/default.conf;\n' "$name" > "rootfs/etc/nginx/sites-enabled/$name.conf"

echo "Сайт создан: $dst"
echo "Включён:     rootfs/etc/nginx/sites-enabled/$name.conf"
echo "Проверьте и примените: make reload"
