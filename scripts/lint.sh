#!/usr/bin/env bash
# Статические проверки конфигурации — ловят известные ловушки до запуска nginx.
#
#   scripts/lint.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

conf=rootfs/etc/nginx
status=0
problem() { printf 'lint: %s\n' "$1"; status=1; }

# Все .conf дерева. (Без mapfile: в macOS по умолчанию bash 3.2.)
conf_files=()
while IFS= read -r f; do conf_files+=("$f"); done < <(find "$conf" -type f -name '*.conf' | sort)

# 1) `error_log off` не выключает лог, а создаёт файл с именем «off».
if grep -rnE '^\s*error_log\s+off' "$conf"; then
    problem "error_log off создаёт файл 'off'; удалите строку или используйте error_log /dev/null crit"
fi

# 2) Параметр http2 у listen устарел с nginx 1.25.1 — используйте `http2 on;`.
if grep -rnE '^\s*listen\s+[^;#]*\bhttp2\b' "$conf"; then
    problem "listen ... http2 устарел; используйте директиву http2 on;"
fi

# 3) $uri и $document_uri декодированы: в return/rewrite/Location они дают
#    HTTP response splitting (%0d%0a → перевод строки).
# shellcheck disable=SC2016  # $uri здесь — часть регулярного выражения, а не переменная shell
if grep -rnE '(^|[{;])\s*(return\s+30[1278]|rewrite)\s[^;#]*\$\{?(uri|document_uri)\}?([^a-z_]|$)' "$conf"; then
    problem "\$uri в редиректе — риск CRLF-инъекции; стройте цель из \$request_uri"
fi

# 4) Публичные DNS-резолверы: утечка внутренних имён и поломка DNS Docker.
if grep -rnE '^\s*resolver\s+[^;#]*\b(1\.1\.1\.1|8\.8\.8\.8|8\.8\.4\.4|9\.9\.9\.9)\b' "$conf"; then
    problem "публичный resolver; используйте 127.0.0.11 (Docker) или внутренний DNS"
fi

# 5) Правило «всё или ничего» — проверка по блокам (server, location, if …).
#    Блок со своей директивой из левого столбца обязан в том же блоке
#    подключать snippet из правого (или snippet, который его подключает),
#    иначе в нём пропадут унаследованные заголовки безопасности, трассировки,
#    HSTS или параметры. Текст файла без блоков (snippet, подключаемый внутрь
#    location) проверяется как один блок.
RULES='add_header=response_headers|headers_html_strict|api_headers
proxy_set_header=proxy_headers
proxy_hide_header=proxy_headers
grpc_set_header=grpc_headers
grpc_hide_header=grpc_headers
fastcgi_hide_header=fastcgi_hide_headers
uwsgi_hide_header=uwsgi_hide_headers
scgi_hide_header=scgi_hide_headers
fastcgi_param=fastcgi_trace_params|fastcgi_php
uwsgi_param=uwsgi_trace_params
scgi_param=scgi_trace_params'

block_check() {
    awk -v file="$1" -v rules="$RULES" '
        BEGIN {
            nr = split(rules, lines, "\n")
            for (r = 1; r <= nr; r++) {
                eq = index(lines[r], "=")
                dir[r] = substr(lines[r], 1, eq - 1)
                snip[r] = substr(lines[r], eq + 1)
            }
            depth = 0; reset(0)
        }
        function reset(d,   r) { start[d] = NR; for (r = 1; r <= nr; r++) { has[d, r] = 0; inc[d, r] = 0 } }
        function verdict(d,   r) {
            for (r = 1; r <= nr; r++)
                if (has[d, r] && !inc[d, r])
                    printf "lint: %s:%d: блок с %s без include snippets/(%s).conf\n", file, start[d], dir[r], snip[r]
        }
        # Разбор одного оператора (текст между ; { }) на текущей глубине.
        function statement(text,   r) {
            sub(/^[ \t]+/, "", text)
            if (text == "") return
            for (r = 1; r <= nr; r++) {
                if (text ~ ("^" dir[r] "[ \t]")) has[depth, r] = 1
                if (text ~ ("^include[ \t]+[^ \t]*snippets/(" snip[r] ")\\.conf")) inc[depth, r] = 1
            }
        }
        {
            line = $0
            sub(/#.*/, "", line)                       # комментарии
            gsub(/"[^"]*"/, "\"\"", line)              # строки в кавычках (регулярки, JSON)
            gsub(/\047[^\047]*\047/, "\047\047", line)
            buf = ""
            n = split(line, ch, "")
            for (i = 1; i <= n; i++) {
                c = ch[i]
                if (c == ";") { statement(buf); buf = "" }
                else if (c == "{") { buf = ""; depth++; reset(depth) }   # заголовок блока (location …) не оператор
                else if (c == "}") { statement(buf); buf = ""; verdict(depth); depth-- }
                else buf = buf c
            }
            statement(buf)
        }
        END { verdict(0) }
    ' "$1"
}
for file in "${conf_files[@]}"; do
    case "$file" in
        # Сами наборы директив и их источники.
        */snippets/response_headers.conf|*/snippets/security_headers.conf|*/snippets/trace_response_headers.conf|\
        */snippets/proxy_headers.conf|*/snippets/grpc_headers.conf|*/snippets/*_hide_headers.conf|*/snippets/*_trace_params.conf) continue ;;
        # http{}: наборы подключаются через globals; stock-файлы параметров.
        */conf.d/globals/*|*/main.d/*|*/fastcgi_params|*/uwsgi_params|*/scgi_params) continue ;;
    esac
    out=$(block_check "$file")
    if [ -n "$out" ]; then printf '%s\n' "$out"; status=1; fi
done

# 6) Каждый include указывает на существующий файл (или каталог для шаблона *).
while IFS= read -r ref; do
    path="rootfs${ref}"
    case "$ref" in
        /etc/nginx/*) ;;
        *) continue ;;   # относительные include (mime.types, fastcgi_params) — от каталога nginx.conf
    esac
    if [[ "$ref" == *'*'* ]]; then
        [ -d "$(dirname "$path")" ] || problem "include $ref: нет каталога $(dirname "$path")"
    else
        [ -f "$path" ] || problem "include $ref: файл не найден ($path)"
    fi
done < <(sed -n 's/^[[:space:]]*include[[:space:]]\{1,\}\([^;[:space:]]*\);.*/\1/p' "${conf_files[@]}" | sort -u)

for rel in mime.types fastcgi_params uwsgi_params scgi_params; do
    [ -f "$conf/$rel" ] || problem "нет $conf/$rel (относительный include из nginx.conf)"
done

# 7) Символьные ссылки ломаются при checkout в Windows.
if find rootfs -type l | grep -q .; then
    problem "в rootfs есть символьные ссылки: используйте файлы с include"
fi

# 8) Файлы должны заканчиваться переводом строки и не содержать CRLF.
#    Вне git-репозитория (архив) список берётся через find.
if ! text_files=$(git ls-files --cached --others --exclude-standard -- \
        '*.conf' '*.sh' '*.yaml' '*.yml' '*.md' '*.html' '*.css' '*.mjs' '*.json' 'Makefile' 2>/dev/null) \
        || [ -z "$text_files" ]; then
    text_files=$(find . -path ./.git -prune -o -type f \( -name '*.conf' -o -name '*.sh' -o -name '*.yaml' \
        -o -name '*.yml' -o -name '*.md' -o -name '*.html' -o -name '*.css' -o -name '*.mjs' -o -name '*.json' \
        -o -name Makefile \) -print)
fi
while IFS= read -r file; do
    [ -n "$file" ] && [ -f "$file" ] || continue
    if [ -s "$file" ] && [ "$(tail -c1 "$file" | od -An -c | tr -d ' ')" != '\n' ]; then
        problem "$file: нет перевода строки в конце файла"
    fi
    if grep -q $'\r' "$file"; then
        problem "$file: окончания строк CRLF"
    fi
done <<<"$text_files"

exit "$status"
