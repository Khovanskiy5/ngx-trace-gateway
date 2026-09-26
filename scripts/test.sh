#!/usr/bin/env bash
# Smoke-тесты шлюза на одном образе: проверка конфигурации, запуск через
# docker compose и проверки поведения curl'ом с хоста.
#
#   scripts/test.sh                                  # образ из .env / по умолчанию
#   NGX_IMAGE=nginx:1.30.5 NGX_BIN=nginx scripts/test.sh
#   SKIP_HTTPS=1 scripts/test.sh                     # без HTTPS-фазы
#
# Требуются: docker (compose v2), curl, python3, openssl.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

export NGX_IMAGE="${NGX_IMAGE:-openresty/openresty:1.31.1.1-bookworm}"
export NGX_BIN="${NGX_BIN:-openresty}"
export HTTP_PORT="${TEST_HTTP_PORT:-28080}"
export HTTPS_PORT="${TEST_HTTPS_PORT:-28443}"
export BIND_ADDR=127.0.0.1
export HOP_NAME="${HOP_NAME:-edge-test}"
export NGX_WORKER_PROCESSES="${NGX_WORKER_PROCESSES:-2}"
project_suffix=$(printf '%s' "$NGX_IMAGE" | tr -c 'a-z0-9' '-' | cut -c1-40)
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-ngxtg-test-${project_suffix}}"

BASE="http://localhost:${HTTP_PORT}"
TLS_BASE="https://localhost:${HTTPS_PORT}"
RID=0123456789abcdef0123456789abcdef
HEX32='[0-9a-f]{32}'

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/ngxtg-test.XXXXXX")
failures=0
total=0

pass() { total=$((total + 1)); printf 'ok    %s\n' "$1"; }
fail() { total=$((total + 1)); failures=$((failures + 1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
check() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

# Заголовки ответа (без \r), тело игнорируется.
headers() { curl -sS -o /dev/null -D - "$@" | tr -d '\r'; }
# Код ответа.
code() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }
# Значение заголовка (первое вхождение).
header_value() { local name=$1; shift; headers "$@" | awk -v n="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" 'BEGIN{FS=": "} tolower($1)==n {sub(/^[^:]*: /,""); print; exit}'; }
# Сколько раз встречается заголовок.
header_count() { local name=$1; shift; headers "$@" | grep -ci "^$name:"; }
gateway_logs() { docker compose logs --no-color --no-log-prefix gateway 2>&1; }

# HTTP-запрос изнутри контейнера шлюза (с loopback-адреса). В образах разный
# набор утилит: curl, wget (busybox) или только bash. Печатает ответ целиком:
# заголовки (без \r), пустая строка, тело.
#   in_gateway <порт> <путь> [Host]
in_gateway() {
    docker compose exec -T gateway sh -c '
        port=$1; path=$2; host=$3
        if command -v curl >/dev/null 2>&1; then
            curl -sS -i -H "Host: $host" "http://127.0.0.1:$port$path"
        elif command -v wget >/dev/null 2>&1; then
            wget -q -S -O - --header "Host: $host" "http://127.0.0.1:$port$path" 2>&1 | sed "s/^  //"
        else
            bash -c "exec 3<>/dev/tcp/127.0.0.1/$port; printf \"GET $path HTTP/1.0\r\nHost: $host\r\n\r\n\" >&3; cat <&3"
        fi' sh "$1" "$2" "${3:-localhost}" 2>/dev/null | tr -d '\r'
}

cleanup() {
    if [ -n "${LOG_FILE:-}" ]; then gateway_logs > "$LOG_FILE" 2>&1 || true; fi
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

start_stack() {
    docker compose up -d --wait --wait-timeout 120 >/dev/null 2>"$WORKDIR/up.err" || {
        echo "docker compose up failed:"; cat "$WORKDIR/up.err"; gateway_logs | tail -n 50; exit 1; }
}

echo "# image=$NGX_IMAGE bin=$NGX_BIN project=$COMPOSE_PROJECT_NAME"

# ---------------------------------------------------------------------------
# 0. Статические проверки и nginx -t
# ---------------------------------------------------------------------------
check "lint (scripts/lint.sh)" scripts/lint.sh
check "docker compose config" docker compose config -q
if docker compose run --rm --no-deps -T gateway "$NGX_BIN" -c /etc/nginx/nginx.conf -t \
        -g 'worker_processes 1; pid /run/nginx.pid;' >"$WORKDIR/t.out" 2>&1; then
    pass "$NGX_BIN -t"
else
    fail "$NGX_BIN -t" "$(tail -n 5 "$WORKDIR/t.out")"; exit 1
fi
check "no [warn] from -t" bash -c "! grep -E '\[(warn|emerg|alert|crit)\]' '$WORKDIR/t.out'"

# ---------------------------------------------------------------------------
# 1. HTTP: сайт, заголовки, трассировка
# ---------------------------------------------------------------------------
start_stack
check "container healthy (healthcheck via 127.0.0.1:8080/healthz)" \
    test "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q gateway)")" = healthy
check "/healthz answers inside container"  grep -q '{"status":"ok"}' <<<"$(in_gateway 8080 /healthz)"
check "/nginx_status answers inside container" grep -q '^Active connections' <<<"$(in_gateway 8080 /nginx_status)"

check "GET / → 200"                        test "$(code "$BASE/")" = 200
check "HTML has charset=utf-8"             grep -qi '^content-type: text/html; charset=utf-8$' <(headers "$BASE/")
check "Server without version"             bash -c "! grep -Eiq '^server: .*[0-9]' <(curl -sS -o /dev/null -D - '$BASE/')"
check "X-Content-Type-Options: nosniff"    grep -qi '^x-content-type-options: nosniff$' <(headers "$BASE/")
check "X-Frame-Options: SAMEORIGIN"        grep -qi '^x-frame-options: SAMEORIGIN$' <(headers "$BASE/")
check "Referrer-Policy"                    grep -qi '^referrer-policy: strict-origin-when-cross-origin$' <(headers "$BASE/")
check "Permissions-Policy"                 grep -qi '^permissions-policy: camera=()' <(headers "$BASE/")
check "X-XSS-Protection: 0"                grep -qi '^x-xss-protection: 0$' <(headers "$BASE/")
check "no HSTS over plain HTTP"            bash -c "! grep -qi '^strict-transport-security' <(curl -sS -o /dev/null -D - '$BASE/')"

check "X-Request-ID generated (32 hex)"    grep -Eq "^$HEX32\$" <<<"$(header_value X-Request-ID "$BASE/")"
# Имя узла, цепочка и X-Prev-Request-ID показываются только loopback-клиентам:
# запросы с хоста приходят через NAT Docker и доверенными не считаются.
check "X-HOP-Name hidden from non-loopback" test -z "$(header_value X-HOP-Name "$BASE/")"
check "X-Request-Chain hidden from non-loopback" test -z "$(header_value X-Request-Chain "$BASE/")"
check "X-Prev-Request-ID hidden from non-loopback" test -z "$(header_value X-Prev-Request-ID -H "X-Prev-Request-ID: $RID" "$BASE/")"
loop=$(in_gateway 80 /)
check "loopback client sees X-HOP-Name"    grep -qi "^x-hop-name: $HOP_NAME\$" <<<"$loop"
check "loopback client sees X-Request-Chain" grep -Eqi "^x-request-chain: $HOP_NAME:$HEX32\$" <<<"$loop"
check "valid X-Request-ID propagated"      test "$(header_value X-Request-ID -H "X-Request-ID: $RID" "$BASE/")" = "$RID"
UUID=3f2504e0-4f89-11d3-9a0c-0305e82c3301
check "UUID X-Request-ID accepted"         test "$(header_value X-Request-ID -H "X-Request-ID: $UUID" "$BASE/")" = "$UUID"
check "invalid X-Request-ID regenerated"   grep -Eq "^$HEX32\$" <<<"$(header_value X-Request-ID -H 'X-Request-ID: a"b<script>' "$BASE/")"
long_id=$(printf 'a%.0s' $(seq 1 129))
check "129-char X-Request-ID regenerated"  grep -Eq "^$HEX32\$" <<<"$(header_value X-Request-ID -H "X-Request-ID: $long_id" "$BASE/")"
check "duplicate X-Request-ID regenerated" grep -Eq "^$HEX32\$" <<<"$(header_value X-Request-ID -H 'X-Request-ID: aaa' -H 'X-Request-ID: bbb' "$BASE/")"
TP_TRACE=4bf92f3577b34da6a3ce929d0e0e4736
check "traceparent trace-id used as fallback" \
    test "$(header_value X-Request-ID -H "traceparent: 00-$TP_TRACE-00f067aa0ba902b7-01" "$BASE/")" = "$TP_TRACE"
check "X-Request-ID wins over traceparent" \
    test "$(header_value X-Request-ID -H "X-Request-ID: $RID" -H "traceparent: 00-$TP_TRACE-00f067aa0ba902b7-01" "$BASE/")" = "$RID"
check "all-zero traceparent ignored" \
    bash -c "v=\$(curl -sS -o /dev/null -D - -H 'traceparent: 00-00000000000000000000000000000000-00f067aa0ba902b7-01' '$BASE/' | tr -d '\r' | awk -F': ' 'tolower(\$1)==\"x-request-id\"{print \$2}'); [ \"\$v\" != 00000000000000000000000000000000 ] && [[ \$v =~ ^[0-9a-f]{32}\$ ]]"
# Цепочку, которую получил бэкенд, показывает эхо whoami.
backend_chain() { curl -sS "$@" "$BASE/api/chain" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-request-chain"{print $2; exit}'; }
check "chain appended"                     grep -Eq "^up:1, $HOP_NAME:$HEX32\$" <<<"$(backend_chain -H 'X-Request-Chain: up:1')"
check "garbage chain replaced by marker"   grep -Eq "^~, $HOP_NAME:$HEX32\$" <<<"$(backend_chain -H 'X-Request-Chain: evil", "admin":"x')"
long_chain=$(for i in $(seq 1 20); do printf 'h%s:%s, ' "$i" "$i"; done | sed 's/, $//')
chain_out=$(backend_chain -H "X-Request-Chain: $long_chain")
check "long chain truncated to 16 elements" bash -c "[[ '$chain_out' == '~, h6:6, '* ]] && [ \$(tr ',' '\n' <<<'$chain_out' | wc -l) -eq 17 ]"
check "X-Mobile-* echoed when valid"       test "$(header_value X-Mobile-Launch-ID -H 'X-Mobile-Launch-ID: launch-1' "$BASE/")" = launch-1
check "no h2c on port 80"                  bash -c "! curl -sS -o /dev/null --http2-prior-knowledge '$BASE/' 2>/dev/null"

# ---------------------------------------------------------------------------
# 2. Статика, служебные файлы, каноничные URL
# ---------------------------------------------------------------------------
check "static asset → 200"                 test "$(code "$BASE/assets/site.css")" = 200
check "static keeps X-Request-ID"          grep -qi '^x-request-id:' <(headers "$BASE/assets/site.css")
check "static keeps nosniff"               grep -qi '^x-content-type-options: nosniff' <(headers "$BASE/assets/site.css")
check "static: one Cache-Control max-age"  test "$(header_count Cache-Control "$BASE/assets/site.css")" = 1
check "static: long cache"                 grep -qi '^cache-control: max-age=2592000' <(headers "$BASE/assets/site.css")
check ".mjs served as JavaScript"          grep -qi '^content-type: application/javascript' <(headers "$BASE/assets/app.mjs")
check "/.git/config → 403 (no redirect)"   test "$(code "$BASE/.git/config")" = 403
check "/.env → 403"                        test "$(code "$BASE/.env")" = 403
check "/assets/.hidden.css → 403"          test "$(code "$BASE/assets/.hidden.css")" = 403
check "/backup.sql → 403"                  test "$(code "$BASE/backup.sql")" = 403
check "/composer.json → 403"               test "$(code "$BASE/composer.json")" = 403
check "/uploads/shell.php → 403"           test "$(code "$BASE/uploads/shell.php")" = 403
check "/uploads/photo.jpg not blocked"     test "$(code "$BASE/uploads/photo.jpg")" = 404
check "/app.php not served as source"      test "$(code "$BASE/app.php")" = 404
check "/files/a..b.txt not blocked"        test "$(code "$BASE/files/a..b.txt")" = 404
check "?q=concatenate( not blocked"        test "$(code "$BASE/?q=concatenate(1)")" = 200
check "/index.html → 301 Location: /"      test "$(header_value Location "$BASE/index.html")" = /
check "index redirect keeps query"         test "$(header_value Location "$BASE/docs/index.html?a=1&b=2")" = "/docs/?a=1&b=2"
check "/a//b → /a/b"                       test "$(header_value Location "$BASE/a//b")" = /a/b
check "empty ? stripped"                   test "$(header_value Location "$BASE/page?")" = /page
check "no trailing-slash redirect"         test "$(code "$BASE/catalog")" = 404
check "CRLF injection blocked"             bash -c "! curl -sS -o /dev/null -D - '$BASE/x%0d%0aSet-Cookie:%20pwned=1/index.html' | grep -qi '^set-cookie'"
check "no open redirect via //host"        bash -c "! curl -sS --path-as-is -o /dev/null -D - '$BASE//evil.example/index.html' | tr -d '\r' | grep -Eiq '^location: //'"
check "no open redirect via /\\host"       bash -c "! curl -sS --path-as-is -o /dev/null -D - '$BASE/%5Cevil.example/index.html' '$BASE/\\evil.example/index.html' | tr -d '\r' | grep -Eiq '^location: /[/\\\\]'"
check "POST to page → no redirect"         test "$(code -X POST "$BASE/index.html")" = 405
check "405 has Allow: GET, HEAD"           grep -qi '^allow: GET, HEAD$' <(headers -X POST "$BASE/")
check "unknown Host → 444 (closed)"        bash -c "! curl -sS -o /dev/null -H 'Host: evil.example' '$BASE/' 2>/dev/null"
check "ACME path is not redirected"        test "$(code "$BASE/.well-known/acme-challenge/token123")" = 404

# Страница 404 с ID запроса (SSI).
body404=$(curl -sS -H "X-Request-ID: $RID" "$BASE/missing-page")
check "404 status preserved"               test "$(code "$BASE/missing-page")" = 404
check "404 page shows request id (SSI)"    grep -q "$RID" <<<"$body404"
check "404 page shows title"               grep -q 'Страница не найдена' <<<"$body404"
check "error page keeps security headers"  grep -qi '^x-content-type-options: nosniff' <(headers "$BASE/missing-page")
check "Accept: application/json → JSON 404" grep -qi '^content-type: application/problem+json' <(headers -H 'Accept: application/json' "$BASE/missing-page")
bad_request=$(python3 - "$HTTP_PORT" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.sendall(b"GET x HTTP/1.1\r\nHost: localhost\r\n\r\n")
data = b""
while True:
    chunk = s.recv(65536)
    if not chunk:
        break
    data += chunk
print(data.decode("utf-8", "replace"))
PY
)
check "malformed request → 400"            grep -q '^HTTP/1.1 400' <<<"$bad_request"
check "400 page shows request id"          grep -q 'ID запроса' <<<"$bad_request"

# ---------------------------------------------------------------------------
# 3. API: проксирование в бэкенд (traefik/whoami отражает заголовки запроса)
# ---------------------------------------------------------------------------
api=$(curl -sS -H "X-Request-ID: $RID" -H 'X-Forwarded-For: 6.6.6.6' -H 'Proxy: http://evil:3128' \
      -H 'Forwarded: for=6.6.6.6' -H 'Upgrade: h2c' -H 'Connection: Upgrade' -H 'Cookie: session=secret' \
      "$BASE/api/v1.0/users?access_token=topsecret")
check "GET /api/v1.0/users → 200 (no slash redirect)" test "$(code "$BASE/api/v1.0/users")" = 200
check "backend got X-Request-ID"           grep -qi "^x-request-id: $RID" <<<"$api"
check "backend got X-Prev-Request-ID = local id" grep -Eqi "^x-prev-request-id: $HEX32" <<<"$api"
check "backend got X-Request-Chain"        grep -Eqi "^x-request-chain: $HOP_NAME:$HEX32" <<<"$api"
check "backend got X-HOP-Name"             grep -qi "^x-hop-name: $HOP_NAME" <<<"$api"
check "client XFF discarded at edge"       bash -c "! grep -qi '6.6.6.6' <<<'$api'"
check "Proxy header stripped (httpoxy)"    bash -c "! grep -qi '^proxy:' <<<'$api'"
check "h2c Upgrade not forwarded"          bash -c "! grep -qi '^upgrade:' <<<'$api'"
check "X-Forwarded-Proto: http"            grep -qi '^x-forwarded-proto: http' <<<"$api"
for m in PUT PATCH DELETE OPTIONS POST; do
    check "$m /api/ allowed"               test "$(code -X "$m" "$BASE/api/items/1")" = 200
done
check "API: Cache-Control: no-store"       grep -qi '^cache-control: no-store' <(headers "$BASE/api/demo")
check "API: single X-Request-ID"           test "$(header_count X-Request-ID "$BASE/api/demo")" = 1

# WebSocket: whoami на обычном пути отражает заголовки — проверяем, что nginx
# передал Upgrade: websocket и Connection: upgrade.
ws=$(curl -sS --max-time 3 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
     -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$BASE/api/ws-probe" | tr -d '\r' || true)
check "WebSocket Upgrade forwarded"        grep -qi '^upgrade: websocket$' <<<"$ws"
check "WebSocket Connection: upgrade"      grep -qi '^connection: upgrade$' <<<"$ws"

# ---------------------------------------------------------------------------
# 4. JSON access-лог
# ---------------------------------------------------------------------------
curl -sS -o /dev/null "$BASE/%FF%FE?x=1"
curl -sS -o /dev/null -A $'bad\xff\xfeagent' "$BASE/"
curl -sS -o /dev/null -H "X-Request-ID: $RID" -e "https://ref.example/cb?code=abc" "$BASE/login?password=hunter2&next=/"
LONG_RID=1111111111111111111111111111aaaa
long_ua=$(python3 -c "print('я' * 3000)")
long_path=$(python3 -c "print('b' * 5000)")
curl -sS -o /dev/null -H "X-Request-ID: $LONG_RID" -A "$long_ua" "$BASE/$long_path?q=$(python3 -c "print('c' * 3000)")"
sleep 1
gateway_logs | grep '^{' > "$WORKDIR/access.log"
check "access log is not empty"            test -s "$WORKDIR/access.log"
if python3 - "$WORKDIR/access.log" "$RID" "$LONG_RID" <<'PY'
import json, sys
path, rid, long_rid = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, 'rb').read().splitlines()
errors = []
records = []
for n, raw in enumerate(lines, 1):
    try:
        records.append(json.loads(raw.decode('utf-8')))
    except Exception as e:
        errors.append(f"line {n}: {e}: {raw[:120]!r}")
if errors:
    print("\n".join(errors[:5])); sys.exit(1)
r = next(x for x in records if x['trace']['trace_request_id'] == rid and x['http']['request']['uri'] == '/login')
assert isinstance(r['http']['response']['status'], int), 'status must be int'
assert isinstance(r['http']['response']['time_sec'], (int, float)), 'time_sec must be number'
assert isinstance(r['http']['request']['size_bytes'], int)
assert isinstance(r['network']['connection']['requests'], int)
assert r['http']['request']['args'] == '[REDACTED]', r['http']['request']['args']
assert not any(x['http']['request']['uri'].startswith('/__errors/') for x in records), 'error page URI leaked into log'
assert all(x['http']['request']['args'] != '[invalid-utf8]' or x['http']['request']['uri'] == '[invalid-utf8]' for x in records), 'empty args flagged as invalid'
assert r['http']['request']['uri_raw'] == '/login', r['http']['request']['uri_raw']
assert r['http']['request']['headers']['referer'] == 'https://ref.example/cb?[REDACTED]', r['http']['request']['headers']['referer']
assert 'cookie' not in json.dumps(r['http']['request']['headers']).lower()
assert r['trace']['trace_id_source'] == 'header'
assert '.' in r['timestamp'] and r['timestamp'][19] == '.', r['timestamp']
assert any(x['http']['request']['uri'] == '[invalid-utf8]' for x in records), 'invalid utf-8 uri not sanitized'
assert any(x['http']['request']['headers']['user_agent'] == '[invalid-utf8]' for x in records), 'invalid utf-8 UA not sanitized'
assert any(x['http']['response']['status'] == 404 for x in records), '404 must be logged'
assert any(x['http']['response']['status'] == 403 for x in records), '403 must be logged'
lr = next(x for x in records if x['trace']['trace_request_id'] == long_rid)
assert lr['http']['request']['headers']['user_agent'].startswith('яяя'), 'long UA must be logged as is'
assert lr['http']['request']['uri'].startswith('/bbbb'), 'long URI must be logged as is'
assert lr['http']['request']['args'].startswith('q=ccc'), 'long query must be logged as is'
PY
then pass "JSON log: every line valid, typed, redacted, errors logged"; else fail "JSON log checks"; fi

# ---------------------------------------------------------------------------
# 5. Лимиты и отказ бэкенда
# ---------------------------------------------------------------------------
codes=$(seq 1 120 | xargs -P 60 -I{} curl -sS -o /dev/null -w '%{http_code}\n' "$BASE/api/burst" | sort | uniq -c)
check "rate limit returns 429"             grep -q ' 429$' <<<"$codes"
for _ in $(seq 1 20); do [ "$(code "$BASE/api/ready")" = 200 ] && break; sleep 1; done
docker compose stop backend >/dev/null 2>&1
b502=$(curl -sS -D "$WORKDIR/502.h" -H "X-Request-ID: $RID" "$BASE/api/down")
# 502 (соединение отклонено) или 504 (таймаут соединения) — зависит от сети Docker.
check "backend down → 502/504"             grep -Eq '^HTTP/[0-9.]+ 50[24]' <(tr -d '\r' < "$WORKDIR/502.h")
check "gateway error is problem+json"      grep -qi '^content-type: application/problem+json' <(tr -d '\r' < "$WORKDIR/502.h")
check "gateway error JSON has request_id"  python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['status'] in (502,504) and d['request_id']==sys.argv[2]" "$b502" "$RID"
docker compose start backend >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 6. Reload и мягкая остановка
# ---------------------------------------------------------------------------
docker compose kill -s HUP gateway >/dev/null 2>&1; sleep 2
check "reload (SIGHUP) keeps serving"      test "$(code "$BASE/")" = 200
check "no emerg/alert/crit in logs"        bash -c "! docker compose logs --no-color --no-log-prefix gateway 2>&1 | grep -Eq '\[(emerg|alert|crit)\]|pcre2_match'"
docker compose stop gateway >/dev/null 2>&1
check "graceful stop exits 0"              test "$(docker inspect -f '{{.State.ExitCode}}' "$(docker compose ps -aq gateway)")" = 0
docker compose down -v --remove-orphans >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 7. HTTPS (копия rootfs с сертификатом и default_https.conf)
# ---------------------------------------------------------------------------
if [ -z "${SKIP_HTTPS:-}" ]; then
    cp -R rootfs "$WORKDIR/rootfs"
    scripts/gen-dev-cert.sh "$WORKDIR/rootfs/etc/nginx/ssl" >/dev/null
    printf 'include /etc/nginx/sites-available/default/default_https.conf;\n' \
        > "$WORKDIR/rootfs/etc/nginx/sites-enabled/default.conf"
    printf 'acme-ok\n' > "$WORKDIR/rootfs/var/www/acme/.well-known/acme-challenge/token123"
    # Второй сайт из шаблона: имена upstream/map не должны конфликтовать.
    cp -R scripts "$WORKDIR/scripts"
    "$WORKDIR/scripts/new-site.sh" shop shop.test backend:8080 >/dev/null
    printf 'include /etc/nginx/sites-available/shop/default_https.conf;\n' \
        > "$WORKDIR/rootfs/etc/nginx/sites-enabled/shop.conf"
    # Все опциональные snippets в одном тестовом сервере: они должны проходить -t.
    cat > "$WORKDIR/rootfs/etc/nginx/sites-enabled/zz-snippets.conf" <<'CONF'
upstream zz_grpc_backend { server 127.0.0.1:50051; }
server {
    include /etc/nginx/snippets/listen_https.conf;
    include /etc/nginx/snippets/http3.conf;
    http2 on;
    server_name snippets.test;
    ssl_certificate     /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    include /etc/nginx/snippets/error_pages.conf;
    include /etc/nginx/snippets/grpc_error_locations.conf;
    include /etc/nginx/snippets/headers_html_strict.conf;
    include /etc/nginx/snippets/maintenance.conf;
    location /grpc/ { include /etc/nginx/snippets/grpc_errors.conf; grpc_pass grpc://zz_grpc_backend; }
    location /cache/ { include /etc/nginx/snippets/proxy_cache.conf; proxy_pass http://backend_upstream; }
    location /ws/ { include /etc/nginx/snippets/websocket.conf; proxy_pass http://backend_upstream; }
    location /sse/ { include /etc/nginx/snippets/sse.conf; proxy_pass http://backend_upstream; }
    location /img/ { include /etc/nginx/snippets/hotlink_protection.conf; }
    location ~ \.php$ { include /etc/nginx/snippets/fastcgi_php.conf; fastcgi_pass 127.0.0.1:9000; }
    location /py/ { include uwsgi_params; include /etc/nginx/snippets/uwsgi_trace_params.conf; uwsgi_pass 127.0.0.1:3031; }
    location /scgi/ { include scgi_params; include /etc/nginx/snippets/scgi_trace_params.conf; scgi_pass 127.0.0.1:4000; }
    location /v1/ { include /etc/nginx/snippets/api_error_pages.conf; proxy_pass http://backend_upstream; }
}
# Два hop'а nginx подряд (hop.test → 127.0.0.1:8081 → бэкенд): клиент должен
# получить по одной копии заголовков трассировки и безопасности.
server {
    listen 127.0.0.1:8081;
    server_name _;
    location / { proxy_pass http://backend_upstream; }
}
server {
    include /etc/nginx/snippets/listen_http.conf;
    server_name hop.test;
    include /etc/nginx/snippets/error_pages.conf;
    location / { proxy_pass http://127.0.0.1:8081; }
}
CONF
    export ROOTFS="$WORKDIR/rootfs"
    start_stack
    CA="$WORKDIR/rootfs/etc/nginx/ssl/fullchain.pem"

    check "HTTPS → 200"                    test "$(code --cacert "$CA" "$TLS_BASE/")" = 200
    check "HTTPS uses HTTP/2"              test "$(curl -sS --cacert "$CA" -o /dev/null -w '%{http_version}' "$TLS_BASE/")" = 2
    check "HSTS on HTTPS"                  grep -qi '^strict-transport-security: max-age=63072000; includeSubDomains$' <(headers --cacert "$CA" "$TLS_BASE/")
    check "HTTPS keeps security headers"   grep -qi '^x-content-type-options: nosniff' <(headers --cacert "$CA" "$TLS_BASE/")
    check "HTTPS keeps X-Request-ID"       grep -qi '^x-request-id:' <(headers --cacert "$CA" "$TLS_BASE/")
    check "HTTPS static keeps HSTS"        grep -qi '^strict-transport-security' <(headers --cacert "$CA" "$TLS_BASE/assets/site.css")
    check "HSTS on HTTPS /api/"            grep -qi '^strict-transport-security' <(headers --cacert "$CA" "$TLS_BASE/api/demo")
    check "HSTS on HTTPS 404 page"         grep -qi '^strict-transport-security' <(headers --cacert "$CA" "$TLS_BASE/missing-page")
    check "HSTS on HTTPS 403"              grep -qi '^strict-transport-security' <(headers --cacert "$CA" "$TLS_BASE/.env")
    check "HTTP/3 server: Alt-Svc"         grep -qi '^alt-svc: h3=' <(headers -k --resolve "snippets.test:${HTTPS_PORT}:127.0.0.1" "https://snippets.test:${HTTPS_PORT}/")
    check "strict profile: no-referrer"    grep -qi '^referrer-policy: no-referrer$' <(headers -k --resolve "snippets.test:${HTTPS_PORT}:127.0.0.1" "https://snippets.test:${HTTPS_PORT}/")
    h413=$(head -c 17000000 /dev/zero | curl -sS --http2 --cacert "$CA" -o /dev/null -D - -X POST --data-binary @- "$TLS_BASE/api/upload" | tr -d '\r')
    check "413 over HTTP/2"                grep -Eq '^HTTP/2 413' <<<"$h413"
    check "413 over HTTP/2 is problem+json" grep -qi '^content-type: application/problem+json' <<<"$h413"
    SHOP="https://shop.test:${HTTPS_PORT}"
    check "second site: HTTP → https://shop.test/" grep -q '^https://shop.test/' <<<"$(header_value Location -H 'Host: shop.test' "$BASE/")"
    check "second site over HTTPS → 200"   test "$(code -k --resolve "shop.test:${HTTPS_PORT}:127.0.0.1" "$SHOP/")" = 200
    check "second site proxies to its upstream" grep -qi '^host: shop.test' <(curl -sS -k --resolve "shop.test:${HTTPS_PORT}:127.0.0.1" "$SHOP/api/x" | tr -d '\r')
    check "no conflicting server names"    bash -c "! docker compose logs --no-color --no-log-prefix gateway 2>&1 | grep -q 'conflicting server name'"
    check "two hops: single X-Request-ID"  test "$(header_count X-Request-ID -H 'Host: hop.test' "$BASE/api/x")" = 1
    check "two hops: single nosniff"       test "$(header_count X-Content-Type-Options -H 'Host: hop.test' "$BASE/api/x")" = 1
    check "two hops: single Referrer-Policy" test "$(header_count Referrer-Policy -H 'Host: hop.test' "$BASE/api/x")" = 1
    check "two hops: X-HOP-Name hidden"    test -z "$(header_value X-HOP-Name -H 'Host: hop.test' "$BASE/api/x")"
    hop_chain=$(in_gateway 80 /api/x hop.test | awk -F': ' 'tolower($1)=="x-request-chain"{print $2; exit}')
    check "two hops: chain has both hops"  grep -Eq "^$HOP_NAME:$HEX32, $HOP_NAME:$HEX32\$" <<<"$hop_chain"
    check "HTTP → 301 https://"            grep -q '^https://localhost/' <<<"$(header_value Location "$BASE/page?x=1")"
    check "ACME served over HTTP"          test "$(curl -sS "$BASE/.well-known/acme-challenge/token123")" = acme-ok
    check "TLS 1.1 rejected"               bash -c "! curl -sS -o /dev/null --cacert '$CA' --tls-max 1.1 '$TLS_BASE/' 2>/dev/null"
    check "unknown SNI rejected"           bash -c "! curl -sS -o /dev/null -k --resolve evil.example:${HTTPS_PORT}:127.0.0.1 'https://evil.example:${HTTPS_PORT}/' 2>/dev/null"
    check "TLS log fields"                 bash -c "docker compose logs --no-color --no-log-prefix gateway 2>&1 | grep '^{' | grep -q '\"protocol\":\"TLSv1.3\"'"

    touch "$WORKDIR/rootfs/var/www/maintenance/on"; sleep 1
    check "maintenance → 503"              test "$(code --cacert "$CA" "$TLS_BASE/")" = 503
    check "maintenance: Retry-After"       grep -qi '^retry-after: 120$' <(headers --cacert "$CA" "$TLS_BASE/")
    check "maintenance: healthz still 200" grep -q '{"status":"ok"}' <<<"$(in_gateway 8080 /healthz)"
    check "maintenance: API gets problem+json" grep -qi '^content-type: application/problem+json' <(headers --cacert "$CA" "$TLS_BASE/api/demo")
    curl -sS -o /dev/null --cacert "$CA" -H 'X-Request-ID: 2222222222222222222222222222bbbb' "$TLS_BASE/maint-page?x=1"
    sleep 1
    check "maintenance: log keeps original uri and args" python3 -c "
import json, subprocess, sys
out = subprocess.run(['docker', 'compose', 'logs', '--no-color', '--no-log-prefix', 'gateway'], capture_output=True, text=True).stdout
rec = [json.loads(l) for l in out.splitlines() if l.startswith('{') and '2222222222222222222222222222bbbb' in l][-1]
assert rec['http']['request']['uri'] == '/maint-page', rec['http']['request']['uri']
assert rec['http']['request']['args'] == 'x=1', rec['http']['request']['args']
assert rec['http']['response']['status'] == 503
"
    # Существование файла кэширует open_file_cache (до 30 с); reload сбрасывает кэш.
    rm -f "$WORKDIR/rootfs/var/www/maintenance/on"
    docker compose kill -s HUP gateway >/dev/null 2>&1; sleep 2
    check "maintenance off (after reload) → 200" test "$(code --cacert "$CA" "$TLS_BASE/")" = 200
    docker compose down -v --remove-orphans >/dev/null 2>&1
fi

echo "# $((total - failures))/$total passed ($NGX_IMAGE)"
[ "$failures" -eq 0 ]
