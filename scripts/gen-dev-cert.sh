#!/usr/bin/env bash
# Самоподписанный сертификат для локальной разработки (только localhost).
# IP-адреса в сертификат не включены: по IP клиенты не отправляют SNI, и такое
# соединение отклоняет catch-all сервер. Открывайте https://localhost:<порт>/.
#
#   scripts/gen-dev-cert.sh [каталог]     # по умолчанию rootfs/etc/nginx/ssl
#
# Создаёт fullchain.pem и privkey.pem — пути, которые ждёт https_server.conf.
# Файлы *.pem в .gitignore. Не используйте этот сертификат в продакшене.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

out="${1:-rootfs/etc/nginx/ssl}"
mkdir -p "$out"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -days 30 -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost" \
    -addext "basicConstraints=critical,CA:true" \
    -keyout "$out/privkey.pem" -out "$out/fullchain.pem" 2>/dev/null

# Контейнер работает без CAP_DAC_OVERRIDE: root внутри не прочитает файл
# чужого владельца с правами 600. Для dev-ключа это допустимо; в продакшене
# сделайте владельцем ключа root (или группу, в которой состоит root) и 640.
chmod 644 "$out/privkey.pem" "$out/fullchain.pem"

echo "Сертификат: $out/fullchain.pem"
echo "Ключ:       $out/privkey.pem"
