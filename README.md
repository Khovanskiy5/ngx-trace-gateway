# ngx-trace-gateway

Эталонная конфигурация API-шлюза на **nginx**, **OpenResty** или **Angie** в Docker Compose: сквозная трассировка запросов, структурированный JSON-лог и безопасные настройки по умолчанию. Один и тот же каталог конфигурации без изменений запускается на всех трёх дистрибутивах, а поведение шлюза проверяют smoke-тесты в CI на пяти образах.

Что внутри:

- **Трассировка.** `X-Request-ID` с проверкой формата и запасным источником из W3C `traceparent`, цепочка узлов `X-Request-Chain` с ограничением длины, `X-Prev-Request-ID`, `X-HOP-Name` и мобильные `X-Mobile-*`. Те же значения получают бэкенды за `proxy_pass`, `grpc_pass`, `fastcgi_pass`, `uwsgi_pass` и `scgi_pass`. Внутреннюю топологию (имя узла и цепочку) клиенту по умолчанию не показывают. OpenTelemetry подключается по желанию на образах nginx `*-otel` и Angie.
- **JSON-лог в stdout.** Числа записаны числами, секреты из query-строки и Referer маскируются, некорректный UTF-8 не ломает строку лога, для ошибок в логе остаётся исходный запрос.
- **Безопасность.** Catch-all серверы для чужих Host и SNI, заголовки безопасности без дублей с заголовками бэкенда, HSTS на всех HTTPS-ответах, запрет служебных файлов, каноничные URL без CRLF-инъекций и open redirect, лимиты запросов с ответом 429.
- **Ошибки.** HTML-страница с ID запроса для сайта и `application/problem+json` для API и клиентов, которые просят JSON.
- **Эксплуатация.** Контейнер с read-only файловой системой и минимумом capabilities, профиль без root, healthcheck, `stub_status`, reload по SIGHUP, мягкая остановка, режим обслуживания, генератор новых сайтов.
- **Проверки.** `scripts/test.sh` (130 проверок), `scripts/lint.sh`, проверка ссылок в документации и GitHub Actions.

Как реализовать тот же протокол трассировки в бэкенде, фронтенде и мобильных клиентах, описано в [руководстве разработчика](docs/developer-guide.md).

## 📚 Разбор этой конфигурации

Все паттерны из этого репозитория (сквозная трассировка через `map`, JSON-логи, кэш-зоны, rate limit, TLS, безопасность) подробно разобраны в бесплатном курсе:

**[Nginx профессионально: от первого конфига до API-gateway на OpenResty и Angie →](https://cyberlake.ru/learn/nginx)**

## Содержание

- [Быстрый старт](#быстрый-старт)
  - [Команды make](#команды-make)
- [Требования](#требования)
- [Выбор дистрибутива](#выбор-дистрибутива)
- [Структура проекта](#структура-проекта)
- [Как собирается конфигурация](#как-собирается-конфигурация)
  - [Порядок подключения](#порядок-подключения)
  - [Правило «всё или ничего»](#правило-всё-или-ничего)
  - [Фрагменты в snippets](#фрагменты-в-snippets)
  - [Прочие значения по умолчанию](#прочие-значения-по-умолчанию)
- [Трассировка запросов](#трассировка-запросов)
  - [Заголовки](#заголовки)
  - [Проверка входящих значений](#проверка-входящих-значений)
  - [Цепочка узлов](#цепочка-узлов)
  - [Доверие к узлам клиента](#доверие-к-узлам-клиента)
  - [Что видит клиент](#что-видит-клиент)
  - [Имя узла](#имя-узла)
  - [W3C traceparent](#w3c-traceparent)
  - [OpenTelemetry](#opentelemetry)
- [JSON-лог](#json-лог)
  - [Пример строки](#пример-строки)
  - [Поля](#поля)
  - [Маскирование и проверка значений](#маскирование-и-проверка-значений)
  - [Куда пишется лог](#куда-пишется-лог)
  - [Поиск по логу](#поиск-по-логу)
- [Безопасность](#безопасность)
  - [Неизвестные Host и SNI](#неизвестные-host-и-sni)
  - [Заголовки безопасности](#заголовки-безопасности)
  - [Служебные файлы](#служебные-файлы)
  - [Каноничные URL](#каноничные-url)
  - [Подозрительные запросы](#подозрительные-запросы)
  - [Реальный IP клиента за балансировщиком](#реальный-ip-клиента-за-балансировщиком)
  - [Ограничение частоты запросов](#ограничение-частоты-запросов)
- [Проксирование](#проксирование)
  - [Заголовки к бэкенду](#заголовки-к-бэкенду)
  - [Таймауты и повторы](#таймауты-и-повторы)
  - [Upstream и keepalive](#upstream-и-keepalive)
  - [DNS-резолвер](#dns-резолвер)
  - [WebSocket и SSE](#websocket-и-sse)
  - [TLS к бэкендам](#tls-к-бэкендам)
  - [Кэширование](#кэширование)
  - [CORS](#cors)
  - [gRPC](#grpc)
  - [FastCGI, uWSGI и SCGI](#fastcgi-uwsgi-и-scgi)
- [HTTPS](#https)
  - [Сертификат для разработки](#сертификат-для-разработки)
  - [Сертификаты в продакшене](#сертификаты-в-продакшене)
  - [Права на ключ](#права-на-ключ)
  - [HSTS](#hsts)
  - [TLS-политика](#tls-политика)
  - [HTTP/3](#http3)
  - [OCSP stapling](#ocsp-stapling)
- [Страницы ошибок](#страницы-ошибок)
- [Здоровье и метрики](#здоровье-и-метрики)
- [Эксплуатация](#эксплуатация)
  - [Применение изменений](#применение-изменений)
  - [Мягкая остановка](#мягкая-остановка)
  - [Процессы и лимиты](#процессы-и-лимиты)
  - [Hardening](#hardening)
  - [Профиль без root](#профиль-без-root)
  - [Режим обслуживания](#режим-обслуживания)
  - [Новый сайт](#новый-сайт)
  - [Хосты без IPv6](#хосты-без-ipv6)
  - [Локальные изменения compose](#локальные-изменения-compose)
  - [Обновление образов](#обновление-образов)
- [Тесты и CI](#тесты-и-ci)
- [Частые проблемы](#частые-проблемы)
- [Что изменилось](#что-изменилось)
- [Лицензии сторонних файлов](#лицензии-сторонних-файлов)

## Быстрый старт

```bash
git clone https://github.com/Khovanskiy5/ngx-trace-gateway.git
cd ngx-trace-gateway
docker compose up -d --wait        # или: make up
```

Поднимутся два контейнера: `gateway` (шлюз, по умолчанию OpenResty) и `backend` — демо-бэкенд [traefik/whoami](https://github.com/traefik/whoami), который возвращает в теле ответа всё, что получил. Флаг `--wait` ждёт, пока healthcheck шлюза перейдёт в `healthy`.

Порты по умолчанию — `127.0.0.1:80` и `127.0.0.1:443`, то есть шлюз доступен только с этой машины. Если порты заняты или нужен доступ извне, скопируйте `.env.example` в `.env` и поменяйте `HTTP_PORT`, `HTTPS_PORT` или `BIND_ADDR`. Без `.env` используются значения по умолчанию.

Заголовки ответа сайта:

```bash
curl -I http://localhost/
```

```text
HTTP/1.1 200 OK
Server: openresty
Content-Type: text/html; charset=utf-8
...
X-Content-Type-Options: nosniff
X-Frame-Options: SAMEORIGIN
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()
X-Permitted-Cross-Domain-Policies: none
X-XSS-Protection: 0
X-Request-ID: 46f6c82b30ec0c2676384d04c37f8bce
...
```

`X-Request-ID` шлюз сгенерировал сам (32 hex-символа): по нему пользователь и поддержка находят запрос в логах. Имени узла (`X-HOP-Name`) и цепочки (`X-Request-Chain`) в ответе нет, и это намеренно. Они раскрывают внутреннюю топологию, поэтому шлюз показывает их только клиентам с loopback-адреса, а запрос с хоста на опубликованный порт приходит в контейнер через NAT Docker (см. [Что видит клиент](#что-видит-клиент)).

Что получил бэкенд:

```bash
curl http://localhost/api/demo -H 'X-Request-ID: 0123456789abcdef0123456789abcdef'
```

```text
...
GET /api/demo HTTP/1.1
Host: localhost
User-Agent: curl/8.21.0
Accept: */*
X-Forwarded-For: 172.22.0.1
X-Forwarded-Host: localhost
X-Forwarded-Port: 80
X-Forwarded-Proto: http
X-Hop-Name: edge-gateway
X-Prev-Request-Id: a1cebed449753be653fe421509f179e3
X-Real-Ip: 172.22.0.1
X-Request-Chain: edge-gateway:a1cebed449753be653fe421509f179e3
X-Request-Id: 0123456789abcdef0123456789abcdef
```

whoami печатает имена заголовков в каноническом виде Go (`X-Request-Id` вместо `X-Request-ID`). Бэкенд получает трассировку всегда, независимо от того, что показано клиенту:

- переданный `X-Request-ID` дошёл без изменений;
- `X-Hop-Name` — имя узла шлюза, hostname контейнера из переменной `HOP_NAME`;
- `X-Request-Chain` — цепочка узлов в виде `имя:локальный ID`;
- в `X-Prev-Request-ID` шлюз передаёт свой локальный ID, это последний элемент цепочки.

По сквозному и локальному ID запрос находится и в логе шлюза, и в логе бэкенда. `172.22.0.1` — адрес шлюза docker-сети (у вас будет свой): так Docker показывает клиентов, которые пришли на опубликованный порт с этой же машины.

Как ответ выглядит для доверенного клиента, можно посмотреть из сетевого пространства шлюза. Одноразовый контейнер с curl обращается к nginx с loopback-адреса:

```bash
docker run --rm --network "container:$(docker compose ps -q gateway)" curlimages/curl -sI http://localhost/
```

```text
...
X-Request-ID: 76c1663b260e0b63160a4badc4d5ce07
X-HOP-Name: edge-gateway
X-Request-Chain: edge-gateway:76c1663b260e0b63160a4badc4d5ce07
```

JSON-лог шлюза:

```bash
make logs          # то же: docker compose logs -f --no-log-prefix gateway
```

Остановить и удалить контейнеры вместе с томами кэша:

```bash
make down          # то же: docker compose down -v --remove-orphans
```

### Команды make

`make` без аргументов выводит список команд. Дистрибутив (`NGX_IMAGE`, `NGX_BIN`) Makefile берёт так же, как docker compose: сначала из переменных окружения и командной строки, затем из `.env`, затем значение по умолчанию. Например, `NGX_IMAGE=nginx:1.30.5 NGX_BIN=nginx make test` прогонит тесты на nginx, не трогая `.env`.

| Команда | Что делает |
|---|---|
| `make up` | `docker compose up -d --wait` |
| `make down` | остановить и удалить контейнеры и тома кэша |
| `make restart` | `down`, затем `up` |
| `make ps` | состояние контейнеров |
| `make logs` | JSON-лог шлюза в реальном времени |
| `make check` | проверка конфигурации (`<бинарник> -c /etc/nginx/nginx.conf -t`) в отдельном контейнере с той же конфигурацией |
| `make reload` | `make check`, затем SIGHUP мастер-процессу: новая конфигурация без остановки |
| `make status` | `stub_status`: соединения и запросы |
| `make health` | ответ `/healthz` служебного сервера |
| `make test` | smoke-тесты на текущем образе |
| `make test-all` | smoke-тесты на всех пяти образах матрицы |
| `make lint` | `scripts/lint.sh` и `shellcheck` (если установлен); замечания shellcheck завершают цель с ошибкой |
| `make certs` | самоподписанный сертификат для localhost в `rootfs/etc/nginx/ssl/` |
| `make https-on`, `make https-off` | переключить демо-сайт на HTTPS и обратно |
| `make new-site NAME=… DOMAIN=… UPSTREAM=…` | новый сайт из шаблона |

## Требования

- Docker Engine с Docker Compose v2. Для `compose.nonroot.yaml` нужны YAML-теги `!reset` и `!override`, то есть Compose 2.24.4 или новее. Проверено на Docker 29.7 и Compose 5.4.
- Все образы multi-arch и работают на amd64 и arm64 (включая Apple Silicon) без эмуляции.
- Свободные порты 80 и 443 на `127.0.0.1` или другие значения `HTTP_PORT` и `HTTPS_PORT`.
- Для `make` нужен GNU make. Для `scripts/test.sh` нужны bash, curl, python3 и openssl. Для `make certs` подойдёт и OpenSSL, и LibreSSL из macOS. `shellcheck` локально необязателен, в CI обязателен.
- Без Docker конфигурация работает на nginx 1.27.3+, OpenResty 1.27.3.1+ или Angie: раньше открытая версия nginx не поддерживала `server … resolve` в upstream. Каталоги `/etc/nginx` (включая пустой `modules-enabled/`), `/var/www` и `/var/cache/nginx` должны существовать, запуск такой: `nginx -c /etc/nginx/nginx.conf -g "worker_processes auto;"`. Резолвер `127.0.0.11` в `conf.d/globals/global_resolver.conf` замените на свой DNS (см. [DNS-резолвер](#dns-резолвер)).

## Выбор дистрибутива

Дистрибутив задаётся парой переменных в `.env`: образ `NGX_IMAGE` и имя бинарника `NGX_BIN`. Конфигурация для всех одна и та же.

| Дистрибутив | `NGX_IMAGE` | `NGX_BIN` | Особенности |
|---|---|---|---|
| OpenResty (по умолчанию) | `openresty/openresty:1.31.1.1-bookworm` | `openresty` | Lua; ядро nginx 1.31.1 без исправлений безопасности 1.31.2–1.31.6 |
| OpenResty на Alpine | `openresty/openresty:1.31.1.1-alpine` | `openresty` | то же на Alpine; входит в матрицу `make test-all` и CI |
| nginx stable | `nginx:1.30.5` | `nginx` | модуль ACME в образе (динамический) |
| nginx mainline | `nginx:1.31.6` | `nginx` | модуль ACME в образе (динамический) |
| Angie | `docker.angie.software/angie:1.12.2` | `angie` | встроенный ACME-клиент; модули brotli, zstd, OTel |
| nginx с OpenTelemetry | `nginx:1.30.5-otel` | `nginx` | модуль `ngx_otel_module` (см. [OpenTelemetry](#opentelemetry)); в smoke-матрицу не входит, в CI проверяется `-t` с включённым OTel |

Переключение:

```bash
cp .env.example .env
# в .env замените пару NGX_IMAGE/NGX_BIN одной из закомментированных, например:
#   NGX_IMAGE=nginx:1.30.5
#   NGX_BIN=nginx
docker compose up -d --wait        # контейнер шлюза пересоздастся
```

Что важно знать:

- **OpenResty отстаёт от nginx по исправлениям безопасности.** Релизы OpenResty выходят позже nginx: 1.31.1.1 основан на nginx 1.31.1 и не содержит исправлений nginx 1.31.2–1.31.6, в том числе для HTTP/3. Шаблон старается от них не зависеть (например, регулярные выражения в `map` написаны так, что CVE-2026-42533 их не затрагивает), но HTTP/3 на OpenResty 1.31.1.1 не включайте. Если Lua не нужен, в продакшене надёжнее nginx stable.
- **Различия образов шаблон учитывает сам.** `user` в `nginx.conf` не задан: у каждого образа свой вкомпилированный пользователь (nginx — `nginx`, OpenResty — `nobody`, Angie — `angie`). `pid` и `worker_processes` передаются через `-g` из `compose.yaml`. У образа Angie нет STOPSIGNAL, поэтому `compose.yaml` задаёт `stop_signal: SIGQUIT` явно.
- **Кэш у каждого дистрибутива свой.** Том для `/var/cache/nginx` называется `cache-${NGX_BIN}` (`cache-openresty`, `cache-nginx`, `cache-angie`): воркеры разных образов работают от разных пользователей, и файлы кэша одного образа другой прочитать не смог бы.
- **`add_header_inherit merge`** есть в nginx 1.30.5/1.31.6 и OpenResty 1.31.1.1, но не в Angie 1.12.2, поэтому шаблон на эту директиву не опирается (см. [Правило «всё или ничего»](#правило-всё-или-ничего)).
- Модули, которых нет во всех трёх дистрибутивах (ACME, OTel, brotli, zstd, Lua), в общей конфигурации не используются. Динамические модули подключаются файлами в `modules-enabled/`, и такая конфигурация работает только на своём образе.

## Структура проекта

```text
.
├── README.md
├── CHANGELOG.md                     # история изменений
├── docs/developer-guide.md          # протокол трассировки для бэкенда, фронтенда и мобильных клиентов
├── developer_guid.md                # заглушка со ссылкой на docs/developer-guide.md (старый адрес)
├── compose.yaml                     # шлюз + демо-бэкенд traefik/whoami
├── compose.nonroot.yaml             # строгий профиль: без root и без capabilities
├── .env.example                     # дистрибутив, имя узла, порты, число воркеров (копия → .env)
├── Makefile                         # частые команды, `make help`
├── renovate.json                    # Renovate: обновление тегов образов
├── scripts/
│   ├── test.sh                      # smoke-тесты одного образа (130 проверок)
│   ├── lint.sh                      # статические проверки конфигурации
│   ├── gen-dev-cert.sh              # самоподписанный сертификат для localhost
│   └── new-site.sh                  # новый сайт из шаблона sites-available/default
├── .github/
│   ├── workflows/ci.yml             # lint, docs-links, smoke (5 образов), nonroot, optional-modules
│   └── dependabot.yml               # еженедельное обновление GitHub Actions
├── .editorconfig, .gitattributes, .gitignore
└── rootfs/                          # монтируется в контейнер
    ├── etc/nginx/                   # → /etc/nginx (только чтение)
    │   ├── nginx.conf               # главный файл: лимиты, error_log, модули, include main.d/
    │   ├── mime.types               # копия из nginx + mjs, map, webmanifest
    │   ├── fastcgi_params, uwsgi_params, scgi_params   # копии из nginx
    │   ├── main.d/                  # блоки главного уровня
    │   │   ├── events.conf          # events {}
    │   │   └── http.conf            # http {}: базовые опции, подключение globals и сайтов
    │   ├── modules-available/
    │   │   └── otel.conf            # load_module для OpenTelemetry (образец)
    │   ├── modules-enabled/         # включённые модули (по умолчанию пусто)
    │   ├── conf.d/
    │   │   └── globals/             # только директивы уровня http: map, зоны, значения по умолчанию
    │   │       ├── global_real_ip.conf       # realip и доверенные прокси (выключено)
    │   │       ├── global_resolver.conf      # resolver 127.0.0.11 (встроенный DNS Docker)
    │   │       ├── global_hop_name.conf      # $hop_name, $hop_physical, $service_name
    │   │       ├── global_trace.conf         # проверка ID, цепочка, traceparent, что показывать клиенту
    │   │       ├── global_logging.conf       # формат structured_log, маскирование, access_log
    │   │       ├── global_tcp.conf           # sendfile, keepalive, таймауты и лимиты клиента
    │   │       ├── global_security.conf      # server_tokens, заголовки, HSTS, каноничные URL, флаг suspicious
    │   │       ├── global_ssl.conf           # TLS-политика (TLSRef intermediate)
    │   │       ├── global_gzip.conf          # gzip, gzip_static
    │   │       ├── global_cache.conf         # зона proxy_cache appcache, open_file_cache
    │   │       ├── global_rate_limit.conf    # зоны limit_req/limit_conn, статус 429
    │   │       ├── global_proxy.conf         # proxy_*: таймауты, повторы, буферы, TLS к upstream, кэш
    │   │       ├── global_grpc.conf          # grpc_*
    │   │       ├── global_fastcgi.conf       # fastcgi_* (без параметров)
    │   │       ├── global_uwsgi.conf         # uwsgi_*
    │   │       ├── global_scgi.conf          # scgi_*
    │   │       └── global_error_pages.conf   # выбор HTML/JSON и тексты страниц ошибок
    │   ├── snippets/                # фрагменты для server{} и location{} (таблица ниже)
    │   ├── sites-available/
    │   │   ├── catch_all.conf       # default_server: :80 → 444, :443 → ssl_reject_handshake
    │   │   ├── status.conf          # служебный сервер 127.0.0.1:8080: /healthz, /readyz, /nginx_status
    │   │   └── default/             # демо-сайт
    │   │       ├── default.conf                 # сборка «только HTTP» (включена)
    │   │       ├── default_https.conf           # сборка «HTTP → HTTPS»
    │   │       ├── upstream.conf                # upstream backend_upstream
    │   │       ├── http_server.conf             # server :80
    │   │       ├── http_redirect_server.conf    # server :80 при HTTPS: ACME и 301
    │   │       ├── https_server.conf            # server :443 (HTTP/2)
    │   │       ├── app_redirects_security.conf  # служебные файлы, каноничные URL, обслуживание
    │   │       └── app_locations.conf           # location сайта, статики и /api/
    │   ├── sites-enabled/           # включённые сайты: файлы с одной строкой include
    │   │   ├── 00-catch-all.conf
    │   │   ├── 01-status.conf
    │   │   └── default.conf
    │   └── ssl/                     # сертификаты (*.pem в .gitignore, `make certs`)
    └── var/www/                     # → /var/www (только чтение)
        ├── default/public/          # демо-сайт: index.html, robots.txt, assets/
        ├── errors/public/error.html # шаблон страницы ошибки (SSI)
        ├── acme/.well-known/acme-challenge/   # webroot для ACME HTTP-01
        └── maintenance/             # флаг режима обслуживания (файл on)
```

Во время работы в контейнере появляются ещё два места, которых нет в репозитории: именованный том `cache-<NGX_BIN>` в `/var/cache/nginx` (временные файлы и `proxy_cache`) и tmpfs `/run` для pid-файла.

## Как собирается конфигурация

### Порядок подключения

`compose.yaml` монтирует `rootfs/etc/nginx` в `/etc/nginx` целиком и запускает бинарник так:

```bash
<nginx|openresty|angie> -c /etc/nginx/nginx.conf \
    -g "daemon off; worker_processes ${NGX_WORKER_PROCESSES:-auto}; pid ${NGX_PID:-/run/nginx.pid};"
```

Каталог монтируется целиком, а не пофайлово: правки, которые редакторы сохраняют атомарно (IDE, vim, `sed -i`), сразу видны в контейнере. Относительные `include mime.types` и `include fastcgi_params` ищутся рядом с `nginx.conf`, поэтому копии этих файлов лежат в репозитории.

```text
nginx.conf                         worker_rlimit_nofile, worker_shutdown_timeout, error_log stderr, pcre_jit
├── modules-enabled/*.conf         load_module (по умолчанию пусто)
├── main.d/events.conf             events {}
└── main.d/http.conf               http {}: mime.types, absolute_redirect off, map Upgrade/Connection
    ├── conf.d/globals/*.conf      map, зоны, значения по умолчанию (порядок — в http.conf)
    │   ├── global_security.conf   → snippets/response_headers.conf   (add_header уровня http)
    │   ├── global_proxy.conf      → snippets/proxy_headers.conf      (proxy_set_header уровня http)
    │   └── global_grpc.conf       → snippets/grpc_headers.conf       (grpc_set_header уровня http)
    ├── snippets/otel.conf         OpenTelemetry (строка закомментирована)
    └── sites-enabled/*.conf       по алфавиту, в каждом — одна строка include
        ├── 00-catch-all.conf      → sites-available/catch_all.conf
        ├── 01-status.conf         → sites-available/status.conf
        └── default.conf           → sites-available/default/default.conf
                                      ├── upstream.conf
                                      └── http_server.conf
                                          ├── snippets/listen_http.conf
                                          ├── snippets/error_pages.conf        (первым)
                                          ├── app_redirects_security.conf
                                          ├── snippets/acme_challenge.conf
                                          └── app_locations.conf
```

Сборка с HTTPS (`default_https.conf`) подключает `upstream.conf`, `http_redirect_server.conf` (порт 80: ACME и 301 на `https://`) и `https_server.conf` (порт 443: `listen_https.conf`, `error_pages.conf`, `app_redirects_security.conf`, `app_locations.conf`).

Блоки `events{}` и `http{}` лежат в `main.d/`, а не в `conf.d/`. Стоковая конфигурация OpenResty подключает `/etc/nginx/conf.d/*.conf` внутрь своего `http{}`, и блоки главного уровня там вызвали бы ошибку. Поэтому прямо в `conf.d/` файлы `.conf` не кладите: там только подкаталог `globals/`.

В `globals/` лежат только директивы уровня `http{}`. Порядок их подключения важен лишь для читаемости: переменные `map` вычисляются лениво, при первом использовании. Всё, что работает внутри `server{}` и `location{}`, вынесено в `snippets/` и подключается там явно. Серверы, включая служебный, лежат в `sites-available/`. Сайт включается файлом в `sites-enabled/` с одной строкой `include` на сборку из `sites-available/`. Символьных ссылок нет: при checkout в Windows они превращаются в текстовые файлы.

### Правило «всё или ничего»

Директивы `add_header`, `proxy_set_header`, `proxy_hide_header`, `grpc_set_header`, `grpc_hide_header`, `fastcgi_param`, `uwsgi_param`, `scgi_param`, `fastcgi_hide_header`, `uwsgi_hide_header`, `scgi_hide_header` и `error_page` nginx наследует с верхнего уровня, только если на текущем уровне нет **ни одной** директивы того же типа. Один `add_header Cache-Control …` в `location` молча убирает из ответа все заголовки безопасности (включая HSTS) и трассировки. Один `proxy_set_header` убирает `Host`, `X-Forwarded-*` и заголовки трассировки из запроса к бэкенду.

Поэтому такие директивы собраны в фрагменты, и фрагмент подключается заново везде, где появляется своя директива того же типа:

| Своя директива в `server{}` или `location{}` | Что подключить туда же |
|---|---|
| `add_header` | `snippets/response_headers.conf` перед своими заголовками (в нём и HSTS, и `Alt-Svc`) |
| `proxy_set_header`, `proxy_hide_header` | `snippets/proxy_headers.conf` |
| `grpc_set_header`, `grpc_hide_header` | `snippets/grpc_headers.conf` |
| `fastcgi_hide_header`, `uwsgi_hide_header`, `scgi_hide_header` | `snippets/fastcgi_hide_headers.conf`, `snippets/uwsgi_hide_headers.conf`, `snippets/scgi_hide_headers.conf` (подключены на уровне `http{}` из соответствующих `global_*.conf`) |
| `fastcgi_param`, `uwsgi_param`, `scgi_param` | на уровне `http{}` их нет намеренно: в каждом `location` — `include fastcgi_params;` и `snippets/fastcgi_trace_params.conf` (аналогично для uWSGI и SCGI) |
| `error_page` | на уровне `http{}` его тоже нет: в каждом `server{}` первым подключается `snippets/error_pages.conf` |

`scripts/lint.sh` проверяет это правило для каждого блока (`server`, `location`, `if`), включая однострочные блоки.

```nginx
location /downloads/ {
    include /etc/nginx/snippets/response_headers.conf;   # иначе пропадут все заголовки уровня выше
    add_header Content-Disposition "attachment" always;
}

location /legacy/ {
    include /etc/nginx/snippets/proxy_headers.conf;      # иначе пропадут Host, X-Forwarded-*, трассировка
    proxy_set_header X-Legacy-Mode "1";
    proxy_pass http://backend_upstream;
}
```

Скалярные директивы (таймауты, буферы, `expires`) наследуются по одной, их можно переопределять свободно. `scripts/lint.sh` проверяет правило по блокам (`server`, `location`, `if` и т. д.): блок со своим `add_header` должен в том же блоке подключать `response_headers.conf` (или `headers_html_strict.conf` и `api_headers.conf`, которые подключают его сами), блок со своим `proxy_set_header` — `proxy_headers.conf`.

В nginx ≥ 1.29.3 есть `add_header_inherit merge`, который снимает проблему для `add_header`. Но Angie 1.12.2 эту директиву не знает, поэтому шаблон на неё не опирается.

### Фрагменты в snippets

Все файлы лежат в `rootfs/etc/nginx/snippets/` и подключаются по абсолютному пути `/etc/nginx/snippets/<файл>`.

| Файл | Где подключать | Что делает |
|---|---|---|
| `response_headers.conf` | `http{}` (уже подключён); `server`/`location` со своим `add_header` | заголовки безопасности, HSTS, `Alt-Svc` и трассировки: `security_headers.conf` + `trace_response_headers.conf` |
| `headers_html_strict.conf` | `server`/`location` HTML-приложения | CSP, COOP, CORP и `Referrer-Policy: no-referrer` (сам подключает `response_headers.conf`) |
| `api_headers.conf` | `location` API | `Cache-Control: no-store`, если бэкенд не прислал свой |
| `proxy_headers.conf` | `http{}` (уже подключён); `location` со своим `proxy_set_header` | заголовки к бэкенду, скрытие заголовков трассировки бэкенда |
| `grpc_headers.conf` | `http{}` (уже подключён); `location` со своим `grpc_set_header` | то же для gRPC |
| `error_pages.conf` | каждый `server{}`, первым | страницы ошибок HTML или JSON, внутренние `location /__errors/`, снимок исходного запроса для лога |
| `api_error_pages.conf` | `location` API с префиксом не `/api` | ошибки шлюза всегда в JSON (RFC 9457) |
| `grpc_errors.conf` | `location` с `grpc_pass` | ошибки шлюза как `grpc-status` |
| `grpc_error_locations.conf` | `server{}` с gRPC, один раз | внутренние `location` для `grpc_errors.conf` |
| `listen_http.conf`, `listen_https.conf` | `server{}` сайта | `listen` на 80 и 443 для IPv4 и IPv6 |
| `listen_http_default.conf`, `listen_https_default.conf` | catch-all `server{}` | то же с `default_server` |
| `deny_sensitive_files.conf` | `server{}`, до `location` со статикой | запрет `.git`, `.env`, резервных копий, ключей, конфигов PHP-приложений |
| `canonical_redirects.conf` | `server{}` сайта | 301 на каноничный URL |
| `maintenance.conf` | `server{}` сайта | режим обслуживания (503) |
| `acme_challenge.conf` | `server{}` на 80 порту | webroot для ACME HTTP-01 |
| `redirect_to_https.conf` | `server{}` на 80 порту | 301 на `https://` |
| `hotlink_protection.conf` | `location` со статикой | запрет встраивания картинок чужими сайтами |
| `proxy_cache.conf` | `location` с `proxy_pass` | включить кэш |
| `websocket.conf` | `location` WebSocket | таймауты 1 ч, без повторов |
| `sse.conf` | `location` SSE и стриминга | без буферизации, кэша и gzip, таймаут 1 ч |
| `fastcgi_php.conf` | `location ~ \.php$` | типовой location для php-fpm |
| `fastcgi_trace_params.conf`, `uwsgi_trace_params.conf`, `scgi_trace_params.conf` | `location` после `include *_params;` | трассировка и адрес клиента с именами `HTTP_*` |
| `http3.conf` | HTTPS `server{}` | HTTP/3 (QUIC) и значение `Alt-Svc` |
| `ocsp_stapling.conf` | HTTPS `server{}` | OCSP stapling |
| `otel.conf` | `http{}` (строка в `main.d/http.conf` закомментирована) | OpenTelemetry: экспорт спанов и `traceparent` к бэкенду |

`app_redirects_security.conf` демо-сайта объединяет `deny_sensitive_files.conf`, `canonical_redirects.conf` и `maintenance.conf`.

### Прочие значения по умолчанию

- `absolute_redirect off`: в `Location` редиректов nginx пишет относительный путь, и браузер сам подставляет схему, хост и порт, по которым пришёл. Порт не теряется при публикации на нестандартном порту, а за балансировщиком, который снимает TLS, https не понижается до http.
- `charset utf-8` глобально не задан, иначе nginx приписал бы `charset=utf-8` к проксируемым ответам без кодировки (например, windows-1251 от старого бэкенда). Кодировка объявлена только там, где nginx отдаёт свои файлы.
- В `mime.types` добавлены `mjs` (ES-модули), `map` (source maps) и `webmanifest`. Без этого `.mjs` уходил бы как `application/octet-stream`, и браузер с `nosniff` отказался бы выполнять модуль.
- Клиент: `client_max_body_size 16m` (в `location /api/` задан ещё и явно), `large_client_header_buffers 4 16k`, таймауты заголовков 15 с, тела и отправки ответа 30 с, `keepalive_timeout 65s`.
- gzip уровня 5 для ответов от 1 КБ, в том числе `application/problem+json`, `image/svg+xml` и `application/rss+xml`; `gzip_static on` отдаёт заранее сжатые `file.css.gz`.
- `open_file_cache` кэширует дескрипторы статики на 30 с; ошибки «файл не найден» не кэшируются.

## Трассировка запросов

Задача трассировки — по одному ID найти запрос во всех системах и восстановить, через какие узлы он прошёл. Каждый узел (шлюз, внутренний nginx, бэкенд) генерирует свой локальный ID, дописывает себя в цепочку и передаёт сквозной ID дальше. Все переменные вычисляются в `conf.d/globals/global_trace.conf`.

### Заголовки

| Заголовок | Переменная | От клиента | К бэкенду | В ответе клиенту |
|---|---|---|---|---|
| `X-Request-ID` | `$trace_request_id` | сквозной ID; если его нет или он некорректен — trace-id из `traceparent`, иначе новый `$request_id` | то же значение | всем |
| `X-Prev-Request-ID` | `$prev_request_id` / `$local_request_id` | ID предыдущего узла, необязательный (см. [Доверие к узлам клиента](#доверие-к-узлам-клиента)) | `$local_request_id` — ID этого узла | пришедшее значение, только loopback-клиентам |
| `X-Request-Chain` | `$request_hops_chain` | цепочка предыдущих узлов (см. [Доверие к узлам клиента](#доверие-к-узлам-клиента)) | цепочка с этим узлом в конце | только loopback-клиентам |
| `X-HOP-Name` | `$hop_name` | не читается | имя этого узла | только loopback-клиентам |
| `X-Mobile-Launch-ID` | `$mobile_launch_id` | ID запуска мобильного приложения | если есть | если есть |
| `X-Mobile-Request-ID` | `$mobile_request_id` | ID запроса мобильного клиента | если есть | если есть |
| `traceparent`, `tracestate` | `$traceparent_trace_id`, `$traceparent_parent_id` | W3C Trace Context | без изменений (с OTel — новый спан) | — |

`$local_request_id` — это `$request_id` этого узла: 32 hex-символа, новый для каждого запроса. Если клиент не прислал ни `X-Request-ID`, ни `traceparent`, сквозной ID совпадает с локальным.

**Пустой заголовок равен отсутствующему.** nginx не отправляет `add_header` и `proxy_set_header` с пустым значением, поэтому `X-Mobile-*` появляются в ответе и в запросе к бэкенду, а `X-Prev-Request-ID` — в ответе loopback-клиенту, только если клиент прислал корректное значение. К бэкенду `X-Prev-Request-ID` уходит всегда: это локальный ID шлюза. Бэкенды должны одинаково трактовать отсутствие заголовка и пустую строку. Учтите и особенность curl: `-H 'X-Mobile-Launch-ID: '` вообще не отправляет заголовок, а пустой отправляет `-H 'X-Mobile-Launch-ID;'` (шлюз всё равно воспримет его как отсутствующий).

Заголовки трассировки из ответа бэкенда шлюз скрывает (`proxy_hide_header` в `proxy_headers.conf`, аналоги для gRPC, FastCGI, uWSGI и SCGI), чтобы в схеме «edge → внутренний nginx → бэкенд» клиент не получал по копии от каждого узла. Цепочку бэкенда шлюз использует сам: если бэкенд вернул корректную `X-Request-Chain` (до 32 элементов в том же формате) и ответ пришёл не из кэша, loopback-клиент получает её, потому что она полнее. Для ответов из кэша (`HIT`, `STALE`, `UPDATING`, `REVALIDATED`) сохранённая цепочка принадлежит чужому запросу, поэтому отдаётся цепочка шлюза. Бэкенды за gRPC, FastCGI, uWSGI и SCGI получают те же значения (см. [Проксирование](#проксирование)).

### Проверка входящих значений

Все входящие значения приходят от клиента, поэтому шлюз их проверяет. В заголовки трассировки и поля `trace.*` JSON-лога не попадают кавычки, управляющие символы, некорректный UTF-8 и значения размером в килобайты.

- **ID** (`X-Request-ID`, `X-Prev-Request-ID`, `X-Mobile-*`) должен соответствовать `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`, то есть 1–128 символов. Подходят 32 hex, UUID, ULID и т. п. Рекомендуемый формат — 32 hex в нижнем регистре: его генерирует nginx (`$request_id`), и он совпадает с форматом trace-id в W3C Trace Context.
- Некорректное значение отбрасывается. Вместо некорректного `X-Request-ID` берётся trace-id из `traceparent` или генерируется новый ID, остальные заголовки просто не передаются. Два заголовка `X-Request-ID` в одном запросе nginx склеивает через `, `, и такое значение тоже некорректно.

```bash
curl -sI http://localhost/ -H 'X-Request-ID: 3f2504e0-4f89-11d3-9a0c-0305e82c3301' | grep -i '^x-request-id'
# X-Request-ID: 3f2504e0-4f89-11d3-9a0c-0305e82c3301      ← UUID принят
curl -sI http://localhost/ -H 'X-Request-ID: a"b<script>' | grep -i '^x-request-id'
# X-Request-ID: 8938e1eb160aadf50c978bf510be0d86           ← заменён новым
```

Источник сквозного ID пишется в лог: поле `trace.trace_id_source` принимает значения `header`, `traceparent` или `generated`.

### Цепочка узлов

`X-Request-Chain` — список элементов `hop:id` через `, `. Здесь `hop` — имя узла (`[A-Za-z0-9._-]{1,64}`), `id` — его локальный ID (`[A-Za-z0-9._:-]{1,128}`). Каждый узел дописывает себя в конец. Клиенту с хоста цепочка в ответе не показывается, поэтому смотрите, что получил демо-бэкенд:

```bash
curl -s http://localhost/api/demo \
  -H 'X-Request-ID: 0123456789abcdef0123456789abcdef' \
  -H 'X-Request-Chain: mobile-android:5f3c9a0e2b7d4c1e8a6f0b2d4e6c8a01' \
  -H 'X-Prev-Request-ID: 5f3c9a0e2b7d4c1e8a6f0b2d4e6c8a01' | grep -i '^x-'
```

```text
...
X-Hop-Name: edge-gateway
X-Prev-Request-Id: 99ae4ae5f7bc33899d20c3fed8d9807c
X-Real-Ip: 172.22.0.1
X-Request-Chain: mobile-android:5f3c9a0e2b7d4c1e8a6f0b2d4e6c8a01, edge-gateway:99ae4ae5f7bc33899d20c3fed8d9807c
X-Request-Id: 0123456789abcdef0123456789abcdef
```

Бэкенд получил в `X-Prev-Request-ID` локальный ID шлюза, а пришедший от клиента `X-Prev-Request-ID` записан в лог шлюза (`trace.prev_request_id`).

Длина цепочки ограничена, иначе клиент мог бы раздуть её так, что следующий узел отклонил бы запрос из-за размера заголовков.

- Цепочка из 1–16 корректных элементов принимается как есть.
- В более длинной остаются последние 15 элементов с маркером `~` в начале: вместе с текущим узлом их 16 (около 3,3 КБ).
- Если корректных элементов нет, остаётся только маркер: `~, edge-gateway:…`. Так видно, что цепочка была, но её отбросили.

```text
X-Request-Chain: ~, h6:6, h7:7, …, h20:20, edge-gateway:d7955ab46632331bf28b6bd9ea742127
```

### Доверие к узлам клиента

`X-Request-Chain` и `X-Prev-Request-ID` описывают узлы до шлюза и ничем не подписаны. По контракту из [руководства разработчика](docs/developer-guide.md) мобильные и веб-клиенты добавляют в цепочку свой узел, поэтому по умолчанию шлюз принимает проверенные значения от любого клиента. Это справочные данные для поиска, а не доказательство.

Решение задаёт `geo $trace_accept_client_hops` в `global_trace.conf`: по умолчанию `default 1`. Если перед шлюзом нет таких клиентов (например, это внутренний узел за вашим edge), разрешите эти заголовки только доверенным сетям:

```nginx
geo $trace_accept_client_hops {
    default      0;
    10.0.0.0/8   1;     # ваш edge и внутренние сервисы
}
```

Цепочка, присланная с остальных адресов, заменяется маркером `~` (к бэкенду уходит `~, edge-gateway:…`), а их `X-Prev-Request-ID` отбрасывается. `X-Request-ID` по-прежнему принимается от всех, если он корректен. Адрес берётся из `$remote_addr`, то есть за балансировщиком сначала настройте [реальный IP клиента](#реальный-ip-клиента-за-балансировщиком).

### Что видит клиент

`X-Request-ID` отдаётся всем: по нему пользователь и поддержка находят запрос в логах. Имя узла (`X-HOP-Name`), цепочка (`X-Request-Chain`) и `X-Prev-Request-ID` раскрывают внутреннюю топологию, поэтому по умолчанию их получают только клиенты с loopback-адресов `127.0.0.1` и `::1`. Список задаёт `geo $trace_expose_internal` в `global_trace.conf`.

Приватные сети (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) в список намеренно не входят, пример закомментирован. Решение принимается по `$remote_addr`, а с приватного адреса приходит любой внешний клиент в таких случаях:

- публикация порта Docker: NAT Docker Desktop и docker-proxy (userland-proxy); запросы с самого хоста на опубликованный порт тоже приходят с адреса шлюза docker-сети;
- Kubernetes с SNAT;
- балансировщик или CDN без настройки realip.

Добавляйте сети, только если адреса клиентов настоящие: realip настроен и SNAT нет. Чтобы показывать заголовки всем (только для отладки), поставьте `default 1`.

Бэкенд получает цепочку всегда. В демо её видно в ответе `curl http://localhost/api/demo`, а полный ответ глазами доверенного клиента показывает одноразовый контейнер в сетевом пространстве шлюза (см. [Быстрый старт](#быстрый-старт)). В логе шлюза цепочка есть всегда.

### Имя узла

Имя узла попадает в `X-HOP-Name`, в цепочку и в лог. Переносимый способ задать его — hostname контейнера: в `compose.yaml` стоит `hostname: ${HOP_NAME:-edge-gateway}`, в Kubernetes берётся имя пода. Меняется оно в `.env`:

```bash
HOP_NAME=api-nginx-01      # формат: [A-Za-z0-9._-]{1,64}
```

Если hostname поменять нельзя, сопоставьте его с ролью в `map $hostname $hop_name` в `conf.d/globals/global_hop_name.conf`. Ключи там — короткие имена, как их возвращает `gethostname()` (в контейнерах это обычно не FQDN). Реальный hostname всегда пишется в лог отдельно, в поле `trace.hop_physical`. Имя сервиса для поля `service.name` задаёт `map $hostname $service_name` в том же файле (по умолчанию `ngx-trace-gateway`).

### W3C traceparent

Клиенты и сервисы с OpenTelemetry присылают `traceparent`. Если `X-Request-ID` нет или он некорректен, шлюз берёт сквозной ID из trace-id `traceparent`. Благодаря этому строка лога nginx связывается с трассой в APM (Jaeger, Tempo и т. п.).

```bash
curl -sI http://localhost/ -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' | grep -i '^x-request-id'
# X-Request-ID: 4bf92f3577b34da6a3ce929d0e0e4736
```

- Разбирается только версия `00`. Trace-id и parent-id — hex в нижнем регистре, нулевые значения по спецификации недействительны и игнорируются.
- Корректный `X-Request-ID` важнее `traceparent`.
- В лог пишутся `trace.traceparent.trace_id` и `trace.traceparent.parent_id`.
- Без модуля OpenTelemetry `traceparent` и `tracestate` уходят к бэкенду без изменений.

**Без модуля nginx сам `traceparent` не генерирует.** Синтетический заголовок изменил бы решение о семплировании во всех сервисах ниже по цепочке: флаг `01` включил бы 100 % трассировку, `00` выключил бы её. Кроме того, появились бы спаны с родителем, которого никто не экспортировал. Настоящие спаны создаёт `ngx_otel_module` (см. [OpenTelemetry](#opentelemetry)).

### OpenTelemetry

Модуль `ngx_otel_module` есть только в образах nginx `*-otel` (например, `nginx:1.30.5-otel`) и в Angie. Для OpenResty официального модуля нет. По умолчанию модуль не подключён. Включение:

1. В `.env` выберите образ с модулем: `NGX_IMAGE=nginx:1.30.5-otel` и `NGX_BIN=nginx` (пресет есть в `.env.example`) или Angie: `NGX_IMAGE=docker.angie.software/angie:1.12.2` и `NGX_BIN=angie`.
2. Скопируйте образец в `modules-enabled/` и оставьте в копии строку `load_module` для своего образа (по умолчанию раскомментирована строка для nginx, для Angie поменяйте):

   ```bash
   cp rootfs/etc/nginx/modules-available/otel.conf rootfs/etc/nginx/modules-enabled/
   ```

3. В `rootfs/etc/nginx/main.d/http.conf` раскомментируйте `include /etc/nginx/snippets/otel.conf;`.
4. В `snippets/otel.conf` укажите адрес коллектора OTLP/gRPC (по умолчанию `otel-collector:4317`). Контейнер коллектора добавьте в `compose.override.yaml`, в ту же docker-сеть.
5. Пересоздайте шлюз: `make down && make up` (сменился образ).

`snippets/otel.conf` включает `otel_trace on` (спан на каждый запрос; для доли запросов используйте переменную, например через `split_clients`) и `otel_trace_context propagate`. С `propagate` входящий `traceparent` продолжается: бэкенд получает новый `traceparent` с тем же trace-id и спаном nginx в роли родителя.

Решение родителя о семплировании при `otel_trace on` не учитывается: nginx записывает спан каждого запроса и отправляет дальше флаг `01`, даже если клиент прислал `00` (проверено на `nginx:1.30.5-otel`). Чтобы следовать решению родителя, замените строку на `otel_trace $otel_parent_sampled;`. Тогда флаг `00` или `01` уходит дальше без изменений, а запросы без `traceparent` получают новую трассу с флагом `00`, то есть не записываются.

`X-Request-ID` и цепочка работают как раньше, и обычно `X-Request-ID` совпадает с trace-id трассы:

- клиент прислал `traceparent` без `X-Request-ID` — шлюз берёт trace-id из `traceparent`, модуль продолжает ту же трассу;
- клиент не прислал ни того, ни другого — модуль начинает новую трассу с trace-id, равным `$request_id`, а это и есть сгенерированный `X-Request-ID`.

Расходятся они, только когда клиент прислал собственный `X-Request-ID`. Тогда связать строку лога с трассой помогут `$otel_trace_id` и `$otel_span_id`: пример поля для JSON-лога есть в конце `snippets/otel.conf`.

Пути в `load_module` абсолютные: `/etc/nginx` смонтирован целиком, и ссылка `/etc/nginx/modules` из образа nginx недоступна. На образе без модуля файл в `modules-enabled/` не даст nginx запуститься, а `snippets/otel.conf` без модуля даёт ошибку `unknown directive "otel_exporter"`.

Проверено на `nginx:1.30.5-otel` и Angie 1.12.2: `-t` проходит (это же делает задание CI `optional-modules`), бэкенд получает новый `traceparent` с тем же trace-id, `X-Request-ID` совпадает с trace-id в обоих случаях выше.

## JSON-лог

Access-лог пишется в формате `structured_log` из `conf.d/globals/global_logging.conf`, по одной JSON-строке на запрос.

### Пример строки

Запрос `curl 'http://localhost/api/demo?page=2' -H 'X-Request-ID: 0123456789abcdef0123456789abcdef'` (часть полей опущена):

```json
{
  "timestamp": "2026-09-26T18:47:33.034+00:00",
  "timestamp_msec": 1790448453.034,
  "severity": "info",
  "service": { "name": "ngx-trace-gateway" },
  "trace": {
    "hop_name": "edge-gateway",
    "hop_physical": "edge-gateway",
    "prev_request_id": "",
    "local_request_id": "73043186550f290b2ed57c323412ead9",
    "trace_request_id": "0123456789abcdef0123456789abcdef",
    "trace_id_source": "header",
    "hops_chain": "edge-gateway:73043186550f290b2ed57c323412ead9",
    "mobile_launch_id": "",
    "mobile_request_id": "",
    "traceparent": { "trace_id": "", "parent_id": "" }
  },
  "client": { "ip": "172.22.0.1", "port": "59034", "user": "", "forwarded_for": "", "peer_ip": "172.22.0.1" },
  "network": { "server_ip": "172.22.0.3", "server_port": 80, "protocol": "HTTP/1.1", "connection": { "id": 23, "requests": 1, "time": 0.001 } },
  "http": {
    "request": { "method": "GET", "uri": "/api/demo", "uri_raw": "/api/demo", "args": "page=2", "host": "localhost", "size_bytes": 136, "suspicious": 0 },
    "response": { "status": 200, "time_sec": 0.001, "bytes_sent": 986, "body_bytes_sent": 496 },
    "server": { "name": "localhost" },
    "upstream": { "address": "172.22.0.2:8080", "status": "200", "timings": { "connect": "0.000", "header": "0.001", "response": "0.001" } }
  },
  "pipe": "."
}
```

### Поля

«Строка» означает JSON-строку; пустое значение записывается как `""`. Поля `$upstream_*` всегда строки: при повторных попытках в них оказывается список через `, `, а при внутренних редиректах — через ` : `.

| Поле | Тип | Значение |
|---|---|---|
| `timestamp` | строка | время ISO 8601 с миллисекундами |
| `timestamp_msec` | число | то же время в секундах от начала эпохи, с миллисекундами |
| `severity` | строка | `info` для 1xx–3xx, `warn` для 4xx, `error` для 5xx |
| `service.name` | строка | имя сервиса (`$service_name`) |
| `trace.hop_name` | строка | логическое имя узла |
| `trace.hop_physical` | строка | реальный hostname |
| `trace.trace_request_id` | строка | сквозной ID (`X-Request-ID`) |
| `trace.trace_id_source` | строка | `header`, `traceparent` или `generated` |
| `trace.local_request_id` | строка | ID запроса на этом узле |
| `trace.prev_request_id` | строка | входящий `X-Prev-Request-ID` (если принят) |
| `trace.hops_chain` | строка | цепочка с этим узлом в конце |
| `trace.mobile_launch_id`, `trace.mobile_request_id` | строка | мобильные ID |
| `trace.traceparent.trace_id`, `trace.traceparent.parent_id` | строка | поля корректного `traceparent` версии 00 |
| `client.ip` | строка | адрес клиента (при настроенном realip — восстановленный) |
| `client.port` | строка | порт клиента |
| `client.user` | строка | пользователь HTTP Basic-аутентификации |
| `client.forwarded_for` | строка | входящий `X-Forwarded-For` как есть; его контролирует клиент |
| `client.peer_ip` | строка | адрес TCP-собеседника, например балансировщика; без realip равен `client.ip` |
| `network.server_ip` | строка | адрес, на котором принято соединение |
| `network.server_port` | число | порт внутри контейнера (80 или 443), а не опубликованный |
| `network.protocol` | строка | `HTTP/1.1`, `HTTP/2.0` или `HTTP/3.0` |
| `network.connection.id`, `network.connection.requests` | число | номер соединения и число запросов в нём |
| `network.connection.time` | число | сколько секунд открыто соединение |
| `network.tcp.rtt`, `network.tcp.rttvar`, `network.tcp.snd_cwnd` | строка | метрики TCP из ядра (Linux), RTT в микросекундах |
| `tls.enabled` | строка | `on` для HTTPS, иначе пусто |
| `tls.protocol`, `tls.cipher` | строка | версия TLS и шифр |
| `tls.curve` | строка | группа обмена ключами, например постквантовый гибрид `X25519MLKEM768` |
| `tls.session_reused` | строка | `r` — сессия переиспользована, `.` — нет |
| `tls.sni` | строка | имя из SNI |
| `http.request.method` | строка | метод |
| `http.request.uri` | строка | нормализованный декодированный путь; для ошибок разбора запроса (400, 494) — путь из `$request_uri` без декодирования, а если строку запроса разобрать не удалось (некорректная строка, 414) — пусто |
| `http.request.uri_raw` | строка | путь в том виде, как его прислал клиент (percent-encoding), без query-строки |
| `http.request.args` | строка | query-строка исходного запроса (из `$request_uri`) или `[REDACTED]` |
| `http.request.scheme` | строка | `http` или `https` |
| `http.request.host` | строка | `$host`: имя хоста из строки запроса или `Host` без порта, в нижнем регистре (без них — имя сервера) |
| `http.request.host_header` | строка | заголовок `Host` как есть, с портом |
| `http.request.headers.referer` | строка | Referer, query-строка заменена на `?[REDACTED]` |
| `http.request.headers.user_agent` | строка | User-Agent |
| `http.request.size_bytes` | число | размер запроса: строка запроса, заголовки и тело |
| `http.request.content_length`, `http.request.content_type` | строка | заголовки тела запроса |
| `http.request.suspicious` | число | `1`, если query-строка похожа на SQLi/XSS |
| `http.response.status` | число | код ответа |
| `http.response.time_sec` | число | время обработки в секундах |
| `http.response.bytes_sent`, `http.response.body_bytes_sent` | число | отправлено всего и тела ответа |
| `http.response.gzip_ratio` | строка | степень сжатия |
| `http.response.headers.content_type`, `.content_length`, `.connection` | строка | заголовки ответа клиенту |
| `http.server.name` | строка | первое `server_name` сервера, обработавшего запрос |
| `http.upstream.address`, `http.upstream.status` | строка | адрес и код ответа бэкенда |
| `http.upstream.cache_status` | строка | `HIT`, `MISS`, `BYPASS`, `EXPIRED`, `STALE`, `UPDATING`, `REVALIDATED` |
| `http.upstream.bytes_sent`, `.bytes_received`, `.response_length` | строка | объёмы обмена с бэкендом |
| `http.upstream.timings.connect`, `.header`, `.response` | строка | установка соединения, получение заголовков, полный ответ, в секундах |
| `http.upstream.headers.server`, `.content_type` | строка | заголовки ответа бэкенда |
| `pipe` | строка | `p` для HTTP pipelining, иначе `.` |

### Маскирование и проверка значений

- `Cookie` и `Authorization` в лог не пишутся вовсе.
- Если в query-строке есть параметр, похожий на секрет (`access_token`, `id_token`, `refresh_token`, `token`, `code`, `state`, `password`, `passwd`, `pwd`, `secret`, `client_secret`, `api_key`, `apikey`, `key`, `signature`, `sig`, `auth`, `session`, `sessionid`, `jwt`), в `args` вместо всей строки пишется `[REDACTED]`.
- `uri_raw` пишется без query-строки: она попадает только в `args`, где маскируется.
- У Referer query-строка заменяется на `?[REDACTED]`: `https://ref.example/cb?[REDACTED]`.
- В полях, куда клиент может прислать произвольные байты (`uri`, `uri_raw`, `args`, `user_agent`, `referer`, `user`), значение с некорректным UTF-8 целиком заменяется на `[invalid-utf8]`. В `host`, `host_header`, `forwarded_for`, `content_type` и `sni` допустим только печатный ASCII, иначе значение целиком заменяется на `[invalid]`. Иначе строгие парсеры (Elasticsearch/Jackson, Python) отбросили бы всю строку. Кавычки и управляющие символы экранирует `escape=json`.
- Длина значений не ограничена: регулярные выражения проверки UTF-8 используют possessive-квантификатор, поэтому User-Agent, путь и query-строка в несколько килобайт пишутся как есть, без ошибок PCRE и без ложного `[invalid-utf8]`.
- Статус с ведущими нулями (`009`) записывается без них, чтобы число оставалось корректным JSON.
- Ошибки тоже логируются, и в `uri` и `args` остаётся исходный запрос. Для страницы ошибки nginx делает внутренний редирект на `/__errors/…`, но `args` берётся из `$request_uri`, который при редиректах не меняется, а `snippets/error_pages.conf` (он подключается в `server{}` первым) заранее фиксирует путь. Если ошибка случилась ещё при разборе запроса (400, 494), путь берётся из `$request_uri`.

Не логируются успешные запросы к статике (`location` с `expires 30d`), `/favicon.ico`, `/robots.txt`, `/.well-known/appspecific/` и служебный сервер `127.0.0.1:8080`. Ошибки при запросах к статике (например, 404) в лог попадают. Запросы к catch-all серверам тоже логируются, так что сканеры видны.

### Куда пишется лог

Access-лог идёт в stdout (`access_log /dev/stdout structured_log;` на уровне `http{}`), ошибки уровня `warn` и выше — в stderr (`error_log stderr warn;` в `nginx.conf`). Оба потока читает `docker compose logs`. Строки error-лога — не JSON, поэтому при разборе фильтруйте строки, начинающиеся с `{`.

**Error-лог не маскируется.** Строки `[warn]` и `[error]` (ошибки бэкенда, 413, срабатывания `limit_req`) содержат исходную строку запроса вместе с query, адрес upstream и Referer. Храните этот поток так же осторожно, как секреты, или поднимите уровень до `error`. Запросы сканеров к служебным файлам в error-лог не попадают: `deny_sensitive_files.conf` отвечает `return 403`, а не `deny all`.

Ротацию делает Docker: драйвер `json-file` с `max-size: 20m` и `max-file: 5` (якорь `x-logging` в `compose.yaml`), то есть до 100 МБ на контейнер. Сборщики логов (Promtail, Vector, Fluent Bit) читают эти файлы. Для другого драйвера поменяйте `x-logging`.

Чтобы писать лог в файлы, смонтируйте том в `/var/log/nginx` (корневая файловая система контейнера только для чтения) и замените `access_log` в конце `global_logging.conf`:

```nginx
access_log /var/log/nginx/access.log structured_log buffer=64k flush=5s;
```

Ротация тогда на вас: logrotate на хосте и `docker compose kill -s USR1 gateway`, чтобы nginx переоткрыл файлы. Отдельный лог только для ответов 5xx пишется так:

```nginx
map $status $log_is_5xx { ~^5 1; default 0; }
access_log /var/log/nginx/5xx.log structured_log if=$log_is_5xx;
```

### Поиск по логу

```bash
# Все строки одного запроса:
docker compose logs --no-log-prefix gateway | grep '^{' \
  | jq -c 'select(.trace.trace_request_id == "0123456789abcdef0123456789abcdef")'

# Ответы 5xx с кодом бэкенда:
docker compose logs --no-log-prefix gateway \
  | jq -cR 'fromjson? | select(.http.response.status >= 500) | {s: .http.response.status, u: .http.request.uri, up: .http.upstream.status}'
```

## Безопасность

### Неизвестные Host и SNI

`sites-available/catch_all.conf` содержит два сервера `default_server`. Они принимают запросы по IP, с чужим `Host` или без него:

- **порт 80**: на всё отвечает `444`, то есть nginx закрывает соединение без ответа (curl покажет `Empty reply from server`). HTTP/2 здесь не включён, иначе `default_server` разрешил бы h2c (HTTP/2 без TLS, «prior knowledge») для всех сайтов на этом порту. Ошибки в строке запроса (некорректная строка — 400, слишком длинный URI — 414) возникают до чтения `Host` и попадают сюда. Для них сервер подключает `error_pages.conf` и отдаёт страницу с ID запроса, а не встроенную страницу nginx. Слишком большие заголовки (494, клиент получает 400) обрабатывает сайт, если его `Host` уже прочитан, иначе этот сервер: страница та же;
- **порт 443**: `ssl_reject_handshake on` отклоняет TLS-рукопожатие ещё до выдачи сертификата (curl покажет `tlsv1 unrecognized name`). Своего сертификата этому серверу не нужно.

Без catch-all злоумышленник подставлял бы свой `Host` в редиректы и ссылки (host header poisoning), а сканеры по IP видели бы сайт и его сертификат. **Следствие:** шлюз отвечает только на имена из `server_name`. Демо-сайт по HTTP отвечает на `localhost` и `127.0.0.1`, по HTTPS — только на `localhost`: для IP-адресов клиенты не отправляют SNI, и такое соединение отклонит catch-all. В сборке с HTTPS `http://127.0.0.1/` тоже получает `444`. Свой домен добавьте в `server_name` в `http_server.conf`, `https_server.conf` и `http_redirect_server.conf` или создайте сайт через `make new-site`.

### Заголовки безопасности

Заголовки выставляются для всех ответов, включая ошибки и редиректы (`add_header … always`). Если бэкенд уже прислал такой заголовок, шлюз свой не добавляет: остаётся выбор приложения, и дублей нет. Значения вычисляются через `map $upstream_http_…` в `global_security.conf`, а сами `add_header` лежат в `snippets/security_headers.conf`.

| Заголовок | Значение по умолчанию | Примечание |
|---|---|---|
| `X-Content-Type-Options` | `nosniff` | |
| `X-Frame-Options` | `SAMEORIGIN` | полный запрет встраивания — `DENY` или CSP `frame-ancestors 'none'` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | `no-referrer` в строгом профиле, см. ниже |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=(), payment=(), usb=()` | |
| `X-Permitted-Cross-Domain-Policies` | `none` | |
| `X-XSS-Protection` | `0` | фильтр старых браузеров сам создавал уязвимости; OWASP советует выключать |
| `Strict-Transport-Security` | `max-age=63072000; includeSubDomains` | только на ответах по HTTPS, см. [HSTS](#hsts) |
| `Alt-Svc` | `h3=":443"; ma=86400` | только в серверах с `snippets/http3.conf`, см. [HTTP/3](#http3) |
| `Retry-After` | `1` для 429, `120` для 503 | если бэкенд не прислал свой |
| `Server` | `openresty` / `nginx` / `Angie` | `server_tokens off`: без версии |

Из ответов бэкенда шлюз убирает `X-Powered-By`.

**Referrer-Policy.** Источники OWASP расходятся. [HTTP Headers Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/HTTP_Headers_Cheat_Sheet.html) рекомендует `strict-origin-when-cross-origin`, это же значение браузеров по умолчанию. [OWASP Secure Headers Project](https://owasp.org/www-project-secure-headers/) рекомендует `no-referrer`. По умолчанию шаблон берёт первое: `no-referrer` ломает аналитику и проверки CSRF по Origin/Referer в Django и Rails (браузер шлёт `Origin: null` в POST-формах). Строгий профиль включает `no-referrer`.

**Строгий профиль для HTML.** CSP, COOP, COEP и CORP зависят от конкретного приложения и легко ломают встраивание, OAuth-попапы и ресурсы с CDN, поэтому глобально не включены. `snippets/headers_html_strict.conf` добавляет:

- `Content-Security-Policy` (`default-src 'self'`, `frame-ancestors 'none'`, `object-src 'none'` и др.);
- `Cross-Origin-Opener-Policy: same-origin` и `Cross-Origin-Resource-Policy: same-origin`;
- `Referrer-Policy: no-referrer` (через `set $referrer_policy_profile strict;`).

`Cross-Origin-Embedder-Policy` там закомментирован. Подключайте фрагмент в `server{}` или `location{}` своего приложения и настройте CSP под него:

```nginx
location / {
    include /etc/nginx/snippets/headers_html_strict.conf;   # сам подключает response_headers.conf
    try_files $uri $uri/ =404;
}
```

### Служебные файлы

`snippets/deny_sensitive_files.conf` отвечает `403` на:

- скрытые файлы и каталоги (`.git`, `.env`, `.htaccess`, `.svn` …), кроме `/.well-known/`;
- резервные копии, дампы, ключи и файлы редакторов: `.bak`, `.old`, `.orig`, `.swp`, `.sql`, `.sqlite`, `.db`, `.env`, `.ini`, `.log`, `.pem`, `.key`, `.p12`, `~` в конце и т. п.;
- конфигурацию PHP-приложений и менеджеров зависимостей: `composer.json`, `composer.lock`, `wp-config.php`, `configuration.php`, `settings.php`, `config.php`, `php.ini`, `web.config`;
- скрипты в каталогах загрузок: `/upload/` и `/uploads/` с расширениями `.php`, `.phtml`, `.phar`, `.pl`, `.py`, `.cgi`, `.sh`, `.jsp`, `.asp(x)`. Картинки и документы оттуда отдаются как обычно.

Ответ формирует `return 403`, а не `deny all`: код тот же, но nginx не пишет строку в error-лог на каждый запрос сканера, перебирающего `/.env` и `/.git`.

Фрагмент подключается **раньше** location со статикой (в демо-сайте — сразу после `error_pages.conf`, через `app_redirects_security.conf`). nginx проверяет location с регулярными выражениями в порядке появления, и если location для статики (`\.css|\.js|…`) окажется выше, запросы вроде `/.hidden.css` пройдут мимо запретов. Location с `^~` (например, `/api/`) регулярные выражения не проверяют: такие запросы обрабатывает бэкенд.

Кроме того, в демо-сайте файлы `.php`, `.phtml` и `.phar` отдают `404`. Без обработчика PHP nginx отдал бы исходный код. Для PHP-сайта замените этот location (см. [FastCGI, uWSGI и SCGI](#fastcgi-uwsgi-и-scgi)).

Защита от хотлинкинга картинок подключается по желанию: `snippets/hotlink_protection.conf` в location со статикой. Разрешены запросы без Referer, с Referer, вырезанным прокси или файрволом, и с имён текущего `server{}`.

### Каноничные URL

`snippets/canonical_redirects.conf` отвечает `301` на неканоничные адреса страниц:

| Запрос | `Location` |
|---|---|
| `/docs/index.html?a=1` (также `index.htm`, `index.php`) | `/docs/?a=1` |
| `/page?` | `/page` |
| `/a//b?x=1` | `/a/b?x=1` (одна группа слешей за редирект) |

Правила задаёт `map $canonical_redirect` в `global_security.conf`:

- редиректятся только `GET` и `HEAD`: редирект превратил бы POST в GET;
- не трогаются `/api/` и `/.well-known/` (ACME);
- не трогаются пути, начинающиеся с `//` или `/\`: из них получился бы протокол-относительный `Location` на чужой домен (open redirect);
- цель строится только из `$request_uri`, который остаётся в percent-encoding, поэтому `%0d%0a` не превращается в перевод строки. С `$uri` здесь была бы HTTP response splitting, и `scripts/lint.sh` ловит `$uri` и `${uri}` в `return 30x` и `rewrite`;
- query-строка сохраняется, `Location` относительный, поэтому порт и схема не теряются.

Из старой версии убраны правила, которые больше вредили, чем защищали:

- автоматическое добавление `/` к путям без расширения ломало API (POST превращался в GET), ACME-проверку и `/healthz`, а для настоящих каталогов nginx делает этот редирект сам;
- блокировка по регулярным выражениям SQLi/XSS в query-строке давала много ложных срабатываний (поиск «concat(», диапазоны «a..b») и легко обходилась. Теперь такие запросы только помечаются в логе;
- запрет `..` и путей `/etc`, `/var` в URI: nginx сам нормализует путь и не выпускает его за пределы `root`, а правило блокировало легальные адреса;
- запрет всего каталога `/uploads/` и архивов `.zip`/`.tar.gz` блокировал обычные картинки и скачивания;
- белый список методов на уровне сервера (405 на всё, кроме GET/HEAD/POST) ломал `PUT`, `PATCH`, `DELETE` и CORS-preflight `OPTIONS` в API. Теперь методы API решает бэкенд, а статика отвечает `405` с заголовком `Allow: GET, HEAD`.

### Подозрительные запросы

`map $request_suspicious` в `global_security.conf` проверяет query-строку (в том виде, как она пришла, в percent-encoding) по простым шаблонам: `<script`, `union … select`, `GLOBALS`/`_REQUEST`. Совпадение ничего не блокирует, а только ставит `"suspicious": 1` в JSON-логе: сначала измерьте, потом решайте. Заблокировать можно точечно:

```nginx
location /search {
    if ($request_suspicious) { return 403; }
    # ...
}
```

Такие шаблоны не заменяют WAF. Для реальной защиты используйте ModSecurity v3 с OWASP CRS или WAF на Lua.

### Реальный IP клиента за балансировщиком

По умолчанию шлюз считается первым узлом (edge): доверенных прокси нет, клиентские `X-Forwarded-For` и `X-Forwarded-Proto` игнорируются.

- `X-Forwarded-For` к бэкенду содержит только адрес TCP-соединения. Подделанный клиентом XFF не проходит: иначе можно было бы обойти лимиты, ACL и геоправила.
- `X-Forwarded-Proto` — собственная схема соединения.
- `Forwarded`, `X-Forwarded-Prefix` и `Proxy` очищаются, а `X-Forwarded-Host` и `X-Forwarded-Port` шлюз выставляет сам. Фреймворки доверяют этим заголовкам (TrustProxies, trusted_proxies, forward-headers-strategy).

Если перед шлюзом стоит свой балансировщик или CDN, раскомментируйте в `conf.d/globals/global_real_ip.conf` **одни и те же** адреса балансировщика в двух местах:

```nginx
set_real_ip_from  10.0.0.0/8;          # адреса вашего LB/CDN, никогда не 0.0.0.0/0
real_ip_header    X-Forwarded-For;     # или proxy_protocol
real_ip_recursive on;

geo $realip_remote_addr $trusted_proxy {
    default 0;
    10.0.0.0/8  1;
}
```

После этого `$remote_addr` (и `client.ip` в логе) — адрес клиента из `X-Forwarded-For`, а `$realip_remote_addr` (`client.peer_ip`) — адрес балансировщика. Для запросов от доверенного прокси бэкенд получает пришедшую цепочку XFF с дописанным адресом прокси и `X-Forwarded-Proto` прокси, если это `http` или `https`. От остальных адресов шлюз по-прежнему ведёт себя как edge. `$proxy_add_x_forwarded_for` здесь не подходит: при включённом realip он дописал бы восстановленный адрес клиента второй раз.

От этой настройки зависят и другие решения: HSTS за балансировщиком, который снимает TLS, отправляется по `X-Forwarded-Proto: https` от доверенного прокси, а `$trace_expose_internal` и `$trace_accept_client_hops` смотрят на восстановленный `$remote_addr`.

### Ограничение частоты запросов

Зоны объявлены в `conf.d/globals/global_rate_limit.conf`, а включаются в `server`/`location` директивами `limit_req` и `limit_conn`. При превышении ответ — `429 Too Many Requests` (у nginx по умолчанию 503, и мониторинг путал бы ограничение с аварией).

Активны только зоны, которые использует демо-сайт. Остальные шесть закомментированы, а примеры их использования лежат в конце того же файла: раскомментируйте зону, когда включаете пример. Неиспользуемая зона только занимала бы память.

| Зона | Ключ | Скорость | Назначение | Состояние |
|---|---|---|---|---|
| `public_api_ip` | IP | 10 r/s | публичный API | активна |
| `perip_conn` (`limit_conn_zone`) | IP | — | одновременные соединения | активна |
| `app_login` | IP | 5 r/s | логин, смена пароля, 2FA | закомментирована |
| `security_sensitive` | IP | 1 r/s | отправка SMS-кодов | закомментирована |
| `public_api_user` | `X-Consumer-Id` | 120 r/m | API по потребителю, только вместе с зоной по IP | закомментирована |
| `public_api_key` | `X-Api-Key` | 10 r/s | API по ключу, только вместе с зоной по IP | закомментирована |
| `admin_area` | IP | 10 r/s | админка | закомментирована |
| `internal_clients` | IP | 200 r/s | внутренние сервисы | закомментирована |

В демо-сайте `location ^~ /api/` ограничен так: `limit_conn perip_conn 50` и `limit_req zone=public_api_ip burst=40 delay=20`. Ответ 429 для API приходит в JSON с `Retry-After: 1`:

```text
HTTP/1.1 429 Too Many Requests
Content-Type: application/problem+json
...
Retry-After: 1
X-Request-ID: aa5fbe21bfe299e803ee995050796f26
...
Cache-Control: no-store

{"type":"about:blank","title":"Too Many Requests","status":429,"request_id":"aa5fbe21bfe299e803ee995050796f26"}
```

Ключи из заголовков клиент может менять на каждом запросе. Поэтому такие зоны всегда сочетайте с зоной по IP, а настоящий лимит по пользователю стройте на проверенной личности (JWT в njs/Lua, `auth_request`). Пустой ключ не учитывается, так что анонимные клиенты не делят одну общую «корзину». Примеры для логина, API, SMS, админки с `limit_req_dry_run` и внутренних сервисов — в конце `global_rate_limit.conf`.

## Проксирование

Значения по умолчанию для `proxy_pass` заданы в `conf.d/globals/global_proxy.conf`, группа бэкендов демо-сайта — в `sites-available/default/upstream.conf`.

### Заголовки к бэкенду

`snippets/proxy_headers.conf` подключён на уровне `http{}`:

| Заголовок | Значение |
|---|---|
| `Host`, `X-Forwarded-Host` | `$host` — одно из `server_name` (чужие `Host` отсекает catch-all) |
| `X-Real-IP` | `$remote_addr` |
| `X-Forwarded-For` | на edge — только адрес клиента, за доверенным прокси — цепочка с адресом прокси |
| `X-Forwarded-Proto` | схема соединения или значение доверенного прокси |
| `X-Forwarded-Port` | `$server_port`: порт внутри контейнера (80 или 443), а не опубликованный |
| `Forwarded`, `X-Forwarded-Prefix`, `Proxy` | очищаются (не передаются) |
| `Upgrade`, `Connection` | только для WebSocket; для обычных запросов не передаются |
| `X-Request-ID`, `X-Request-Chain`, `X-Prev-Request-ID`, `X-HOP-Name`, `X-Mobile-*` | см. [Трассировку](#заголовки) |
| `traceparent`, `tracestate` | как пришли (с OpenTelemetry — новый спан) |

Из ответа бэкенда скрываются `X-Request-ID`, `X-Request-Chain`, `X-Prev-Request-ID`, `X-HOP-Name`, `X-Mobile-*`, `X-Proxy-Cache` и `X-Powered-By`.

`Upgrade` передаётся только со значением `websocket`. Любой другой (например, `h2c`) отбрасывается: иначе бэкенд, принявший h2c, превратил бы nginx в «слепой» TCP-туннель в обход всех правил (h2c smuggling). Заголовок `Proxy` очищается из-за httpoxy (CVE-2016-5385).

### Таймауты и повторы

| Директива | Значение |
|---|---|
| `proxy_connect_timeout` | 5 с |
| `proxy_send_timeout`, `proxy_read_timeout` | 60 с (между двумя операциями записи или чтения) |
| `proxy_next_upstream` | `error timeout`: повтор только при ошибке соединения и таймауте |
| `proxy_next_upstream_tries` | 2 попытки на запрос |
| `proxy_next_upstream_timeout` | 30 с на все попытки |
| `proxy_buffering` | `on`, буферы `16 16k`, заголовки ответа до 16 КБ |
| `proxy_http_version` | `1.1` (нужен для keepalive и WebSocket) |

Те же правила повторов (`error timeout`, 2 попытки, не дольше 30 с) заданы для gRPC, FastCGI, uWSGI и SCGI. Неидемпотентные запросы (POST, PATCH и т. п.) nginx по умолчанию на другой сервер не повторяет. Таймауты переопределяются в `location` по одной директиве, остальное наследуется. Буферизацию глобально не выключайте: nginx быстро забирает ответ и сам отдаёт его медленному клиенту, разгружая бэкенд.

### Upstream и keepalive

```nginx
# sites-available/default/upstream.conf (без комментариев)
upstream backend_upstream {
    zone backend_upstream 256k;                 # общее состояние группы для всех воркеров
    server backend:8080 resolve max_fails=3 fail_timeout=10s;
    keepalive 32;
    keepalive_timeout  4s;
    keepalive_requests 1000;
}
```

- `zone` делает счётчики `max_fails` и позицию балансировки общими для всех воркеров. Без неё каждый воркер считал бы отказы сам. Кроме того, `zone` обязательна для `resolve`.
- `resolve` перечитывает DNS-имя во время работы через глобальный резолвер (см. [DNS-резолвер](#dns-резолвер)). Если имя пока не резолвится, nginx всё равно стартует и начнёт отправлять запросы, когда адрес появится; до этого клиент получает 502.
- `max_fails=3 fail_timeout=10s`: после трёх неудач за 10 с сервер исключается на 10 с. Таймауты медленных запросов тоже считаются неудачами, поэтому держите значения умеренными.
- Keepalive работает без настроек в `location`. `proxy_http_version 1.1` задан глобально, а `Connection` для обычных запросов пустой и потому не отправляется. Раньше глобальный `Connection: close` открывал новое TCP-соединение на каждый запрос. В Angie без директивы `keepalive` соединения не переиспользуются.
- `keepalive_timeout` должен быть **меньше** idle-таймаута бэкенда. Иначе возможны редкие 502 на POST: бэкенд закрыл простаивающее соединение как раз тогда, когда nginx отправил в него запрос. 4 с — ниже значения Node.js по умолчанию (5 с). Если у бэкенда таймаут больше (Go, Java, Node с `keepAliveTimeout` 65 с), поднимите значение чуть ниже него. gunicorn с sync-воркерами keepalive не поддерживает: для него уберите строку `keepalive`.
- Сервер с параметром `backup` получает **весь** трафик, когда основные недоступны. Методы `ip_hash`, `hash` и `random` с `backup` несовместимы.

### DNS-резолвер

`conf.d/globals/global_resolver.conf` задаёт резолвер на уровне `http{}`:

```nginx
resolver         127.0.0.11 valid=10s ipv6=off;
resolver_timeout 5s;
```

`127.0.0.11` — встроенный DNS Docker, он знает имена сервисов compose. Резолвер нужен для имён, которые nginx резолвит во время работы: `server имя resolve` в upstream, `proxy_pass` с переменной (`proxy_pass http://$backend;`) и OCSP stapling. Имена в обычных `server имя:порт` и `proxy_pass http://имя` резолвятся один раз при старте через `/etc/resolv.conf`.

- В Kubernetes укажите адрес kube-dns (ClusterIP сервиса `kube-system/kube-dns`), без Docker — внутренний DNS сервера.
- Публичные резолверы (`1.1.1.1`, `8.8.8.8`) не используйте: они не знают внутренних имён, а запросы к ним раскрывают эти имена внешнему сервису. `scripts/lint.sh` такие строки находит.
- Свой `resolver` внутри `upstream{}` или в отдельных фрагментах не нужен.

### WebSocket и SSE

```nginx
location /ws/ {
    include /etc/nginx/snippets/websocket.conf;   # proxy_read/send_timeout 1h, proxy_next_upstream off
    proxy_pass http://backend_upstream;
}

location /events/ {
    include /etc/nginx/snippets/sse.conf;         # без буферизации и кэша, read_timeout 1h, gzip off
    proxy_pass http://backend_upstream;
}
```

`Upgrade` и `Connection` для WebSocket уже выставлены глобально. Фрагменты содержат только скалярные директивы и не сбрасывают унаследованные заголовки. Бэкенд может сам отключить буферизацию для конкретного ответа заголовком `X-Accel-Buffering: no`. После reload и при остановке долгие соединения закрываются не позже `worker_shutdown_timeout` (25 с), поэтому клиенты должны уметь переподключаться.

### TLS к бэкендам

При `proxy_pass https://…` шлюз проверяет сертификат бэкенда и отправляет SNI (по умолчанию nginx не делает ни того, ни другого, что открывает MITM между шлюзом и бэкендом):

```nginx
proxy_ssl_server_name         on;
proxy_ssl_verify              on;
proxy_ssl_verify_depth        3;
proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
proxy_ssl_protocols           TLSv1.2 TLSv1.3;
```

При `proxy_pass https://<группа upstream>` имя для SNI и проверки по умолчанию равно имени группы. Укажите настоящее имя в `location`:

```nginx
location /billing/ {
    proxy_ssl_name api.billing.example.com;
    proxy_pass https://billing_upstream;
}
```

Для бэкенда с сертификатом внутреннего CA положите цепочку CA в `rootfs/etc/nginx/ssl/` и укажите её в `proxy_ssl_trusted_certificate`. Для gRPC (`grpcs://`) то же самое задают директивы `grpc_ssl_*` в `global_grpc.conf`.

### Кэширование

Кэш по умолчанию выключен. Зона `appcache` (`/var/cache/nginx/gate`, индекс 32 МБ, до 1 ГБ на диске, объекты без обращений дольше 60 мин удаляются) объявлена в `global_cache.conf`, а включается точечно:

```nginx
location ^~ /api/catalog/ {
    include /etc/nginx/snippets/proxy_cache.conf;       # proxy_cache appcache; 200/301/302 — 10m, 404 — 1m
    include /etc/nginx/snippets/api_headers.conf;
    proxy_pass http://backend_upstream;
}
```

Значения по умолчанию безопасны для персональных данных:

- запросы с `Authorization` или любыми `Cookie` идут мимо кэша (`$cache_bypass`), поэтому ответ одного пользователя не достанется другому. Если кэшировать нужно и при аналитических cookie, сузьте условие до cookie сессии;
- ключ кэша — `$scheme|$request_method|$host|$request_uri`. `Authorization` в него не входит, поэтому токены не попадают в файлы кэша;
- `Cache-Control`, `Expires`, `Set-Cookie` и `Vary` бэкенда учитываются: ответы с `private`, `no-store` и `Set-Cookie` не кэшируются. `proxy_cache_valid` применяется, только если бэкенд не прислал `Cache-Control`/`Expires`;
- `proxy_cache_lock`: пока один запрос обновляет объект, остальные ждут его до 5 с, а не идут в бэкенд толпой;
- при ошибках бэкенда (`error`, `timeout`, 500/502/503/504) и во время обновления отдаётся устаревший объект, обновление идёт в фоне. 403 и 404 из устаревшего кэша не отдаются, поэтому удалённый ресурс или отозванный доступ не «воскресают»;
- статус кэша клиент видит в заголовке `X-Proxy-Cache` (`HIT`, `MISS`, `BYPASS` …), а лог — в поле `http.upstream.cache_status`. Для ответов из кэша шлюз не отдаёт сохранённую `X-Request-Chain` бэкенда: она относится к чужому запросу.

Кэш хранится на именованном томе `cache-<NGX_BIN>` и переживает перезапуск контейнера. `make down` удаляет его вместе с томом. Для FastCGI, uWSGI и SCGI нужна своя зона: пример `fastcgi_cache_path` закомментирован в `global_fastcgi.conf`.

### CORS

Заголовков CORS шлюз не добавляет: политика принадлежит приложению. Методы в `location /api/` не ограничены, поэтому preflight-запрос `OPTIONS` доходит до бэкенда. Если браузерный фронтенд обращается к API с другого origin, бэкенд должен:

- перечислить в `Access-Control-Allow-Headers` заголовки трассировки, которые отправляет браузер: `X-Request-ID` и, если используются, `X-Request-Chain`, `X-Prev-Request-ID`, `X-Mobile-*`, `traceparent`, `tracestate`;
- отдать `Access-Control-Expose-Headers: X-Request-ID`, иначе JavaScript не прочитает ID запроса из ответа.

Ответы, которые формирует сам шлюз (429, 502, 504 и т. п.), идут без CORS-заголовков бэкенда, и браузер покажет их как CORS-ошибку. Если JavaScript должен читать и их, отвечайте на CORS в nginx, соблюдая [правило «всё или ничего»](#правило-всё-или-ничего). Пример ответа на preflight и настройки для популярных фреймворков — в разделе «CORS» [руководства разработчика](docs/developer-guide.md).

### gRPC

`global_grpc.conf` задаёт таймауты (`grpc_read_timeout 60s`, для стримов увеличивайте в location), повторы (`grpc_next_upstream_timeout 30s`) и проверку TLS к бэкенду, а также скрывает `X-Powered-By`. `snippets/grpc_headers.conf` передаёт те же заголовки трассировки и адреса клиента, что и для HTTP, включая `X-Forwarded-Host` и `X-Forwarded-Port`, очищает `X-Forwarded-Prefix`, `Forwarded` и `Proxy` и скрывает заголовки трассировки из ответа бэкенда.

Ошибки шлюза gRPC-клиент должен получать как статус `grpc-status`, а не как HTML-страницу. Иначе недоступный бэкенд выглядит для клиента как `UNKNOWN`/`INTERNAL`, и стандартные политики повторов не срабатывают. Внутренние location из `grpc_error_locations.conf` отвечают `200` с `Content-Type: application/grpc` и `grpc-status` (ответ Trailers-Only по спецификации gRPC). Код 204 не подходит: для него nginx убирает `Content-Type`, а grpc-go и grpcurl считают любой статус, кроме 200, ошибкой HTTP. Проверено с grpcurl: недоступный бэкенд даёт `code = Unavailable`.

```nginx
server {
    include /etc/nginx/snippets/listen_https.conf;
    http2 on;                                               # gRPC работает поверх HTTP/2
    server_name grpc.example.com;
    # ssl_certificate … — как в https_server.conf; заголовки безопасности и HSTS наследуются

    include /etc/nginx/snippets/grpc_error_locations.conf;  # один раз на server

    location /my.package.Service/ {
        include /etc/nginx/snippets/grpc_errors.conf;       # 502/503/504 → UNAVAILABLE (14), 429 → RESOURCE_EXHAUSTED (8)
        grpc_pass grpc://grpc_backend;
    }
}
```

### FastCGI, uWSGI и SCGI

Параметры (`fastcgi_param` и аналоги) на уровне `http{}` не задаются намеренно: первый же `fastcgi_param` в location отменил бы их все, а без него не обойтись. В `global_fastcgi.conf`, `global_uwsgi.conf` и `global_scgi.conf` только таймауты, буферы, повторы (`*_next_upstream_timeout 30s`) и скрытие заголовков ответа. Параметры подключаются в каждом location:

```nginx
# PHP-FPM: убрать из app_locations.conf заглушку `location ~* \.(?:php[0-9]?|phtml|phar)$ { return 404; }`
location ~ \.php$ {
    include /etc/nginx/snippets/fastcgi_php.conf;   # try_files, fastcgi_params, SCRIPT_FILENAME, трассировка
    fastcgi_pass php-fpm:9000;
}

# Django, Flask:
location / {
    include uwsgi_params;
    include /etc/nginx/snippets/uwsgi_trace_params.conf;
    uwsgi_pass django:3031;
}
```

Фрагменты `*_trace_params.conf` передают трассировку и адрес клиента под именами с префиксом `HTTP_`:

- трассировка: `HTTP_X_REQUEST_ID`, `HTTP_X_PREV_REQUEST_ID`, `HTTP_X_REQUEST_CHAIN`, `HTTP_X_HOP_NAME`, `HTTP_X_MOBILE_*`;
- адрес и происхождение запроса: `HTTP_X_REAL_IP`, `HTTP_X_FORWARDED_FOR`, `HTTP_X_FORWARDED_PROTO`, `HTTP_X_FORWARDED_HOST` (`$host`), `HTTP_X_FORWARDED_PORT` (`$server_port`);
- очищаются: `HTTP_X_FORWARDED_PREFIX`, `HTTP_FORWARDED` и `HTTP_PROXY`. Последний защищает от httpoxy: клиентский заголовок `Proxy` не станет переменной окружения `HTTP_PROXY`.

Именно так приложения читают заголовки: `$_SERVER['HTTP_X_REQUEST_ID']`, PSR-7 `getHeaderLine()`, HeaderBag в Laravel и Symfony, `request.META` в Django. Параметр `HTTP_*` заменяет одноимённый заголовок клиента, поэтому приложение видит проверенное значение шлюза, а не сырое клиентское.

Заголовки трассировки в ответе приложения (`X-Request-ID`, `X-Request-Chain`, `X-Prev-Request-ID`, `X-HOP-Name`, `X-Mobile-*`, `X-Proxy-Cache`) шлюз скрывает директивами `*_hide_header` (`snippets/fastcgi_hide_headers.conf`, `uwsgi_hide_headers.conf`, `scgi_hide_headers.conf`), чтобы клиент не получил их дважды. Если в `location` нужен свой `*_hide_header`, подключите туда соответствующий snippet повторно. Корректную цепочку приложения шлюз использует сам, как и для `proxy_pass`. Скрывается и `X-Powered-By`.

`fastcgi_php.conf` передаёт в php-fpm только существующие скрипты (`try_files $fastcgi_script_name =404`), иначе `/upload/x.jpg/y.php` мог бы выполнить загруженный файл. `Set-Cookie` приложений шлюз не скрывает, поэтому сессии и логин работают. `uwsgi_modifier1` глобально не задан: это настройка конкретного плагина uWSGI.

## HTTPS

Демо-сайт по умолчанию работает только по HTTP. Порт 443 всё равно слушает catch-all сервер, который отклоняет рукопожатие, поэтому `curl https://localhost/` до включения HTTPS завершится ошибкой TLS.

### Сертификат для разработки

```bash
make https-on      # при необходимости выполнит make certs и переключит сайт на default_https.conf
make reload
curl --cacert rootfs/etc/nginx/ssl/fullchain.pem https://localhost/
```

- `make certs` (`scripts/gen-dev-cert.sh`) создаёт `rootfs/etc/nginx/ssl/fullchain.pem` и `privkey.pem`: ключ EC P-256, срок 30 дней, `CN=localhost`, SAN только `DNS:localhost`. IP-адресов в сертификате нет: по IP клиенты не отправляют SNI, и такое соединение отклоняет catch-all, поэтому открывайте `https://localhost:<порт>/`. Сертификат помечен как CA, поэтому его же можно передать curl в `--cacert`. Браузер покажет предупреждение. Файлы `*.pem` в `.gitignore`.
- `make https-on` меняет `rootfs/etc/nginx/sites-enabled/default.conf` на `include …/default_https.conf;`. После этого порт 80 отвечает только на ACME HTTP-01, а всё остальное отправляет 301 на `https://`. Порт 443 отдаёт сайт по HTTP/2 с HSTS. `make https-off` возвращает HTTP-сборку. Обе команды меняют файл в репозитории, и `git status` это покажет.
- Редирект на `https://` строит абсолютный URL без порта, то есть ведёт на внешний порт 443 (об этом есть заметка в `.env.example`). При другом `HTTPS_PORT` открывайте `https://localhost:<HTTPS_PORT>/` напрямую.

### Сертификаты в продакшене

Пути к сертификату задаются в `sites-available/default/https_server.conf`: `/etc/nginx/ssl/fullchain.pem` (сертификат с цепочкой) и `/etc/nginx/ssl/privkey.pem`. Там же и в `http_redirect_server.conf` замените `server_name localhost` на свои домены. Сертификаты живут всё меньше: по решению CA/B Forum SC-081 срок сократится до 47 дней к 2029 году. Поэтому выпуск обязательно автоматизируйте. Варианты:

1. **certbot или lego в режиме webroot** (любой дистрибутив). `snippets/acme_challenge.conf` отдаёт `/.well-known/acme-challenge/` из `/var/www/acme` на порту 80 в обеих сборках, без редиректов. ACME-клиент на хосте пишет токены прямо в `rootfs/var/www/acme`, и контейнер сразу их видит:

   ```bash
   certbot certonly --webroot -w ./rootfs/var/www/acme -d example.com -d www.example.com \
     --deploy-hook 'docker compose -f /path/to/ngx-trace-gateway/compose.yaml kill -s HUP gateway'
   ```

   Каталог certbot подключите в `compose.override.yaml` и укажите пути в `https_server.conf`:

   ```yaml
   services:
     gateway:
       volumes:
         - /etc/letsencrypt:/etc/letsencrypt:ro
   ```

   ```nginx
   ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
   ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
   ```

   Монтируйте `/etc/letsencrypt` целиком: файлы в `live/` — символьные ссылки на `archive/`. Если ACME-клиент работает в контейнере, дайте ему общий том с `/var/www/acme` и доступ на запись.

2. **ACME-модуль nginx** (только образы `nginx:*`; модуль динамический). Нужны файл в `modules-enabled/` со строкой `load_module /usr/lib/nginx/modules/ngx_http_acme_module.so;` (по образцу `modules-available/otel.conf`), блок `acme_issuer` на уровне `http{}` и `acme_certificate` в `server{}` с `ssl_certificate $acme_certificate; ssl_certificate_key $acme_certificate_key;`. Резолвер уже задан глобально (`global_resolver.conf`): встроенный DNS Docker резолвит и внешние имена. Путь к модулю указывайте абсолютным: `/etc/nginx` заменён монтированием, и относительного `modules/` в нём нет. `state_path` вынесите на том, доступный для записи, например `/var/cache/nginx/acme-letsencrypt`. Строка `load_module` ломает запуск на OpenResty и Angie, так что это конфигурация для одного дистрибутива. Документация: [ngx_http_acme_module](https://nginx.org/en/docs/http/ngx_http_acme_module.html).

3. **ACME-клиент Angie** (встроенный). Нужны `acme_client letsencrypt https://acme-v02.api.letsencrypt.org/directory;` на уровне `http{}`, `acme letsencrypt;` в `server{}` и `ssl_certificate $acme_cert_letsencrypt; ssl_certificate_key $acme_cert_key_letsencrypt;`. Состояние хранится в `/var/lib/angie/acme`: при read-only файловой системе смонтируйте туда том. Документация: [модуль ACME в Angie](https://en.angie.software/angie/docs/configuration/modules/http/http_acme/).

В OpenResty ACME-модуля нет, для него подходит только первый вариант.

### Права на ключ

У контейнера сброшены все capabilities, кроме `CHOWN`, `SETUID`, `SETGID` и `NET_BIND_SERVICE`. Без `CAP_DAC_OVERRIDE` root внутри контейнера **не может прочитать чужой файл с правами 600**, и nginx не стартует с ошибкой:

```text
nginx: [emerg] cannot load certificate key "/etc/nginx/ssl/privkey.pem": BIO_new_file() failed (SSL: error:8000000D:system library::Permission denied ...)
```

На Linux ключ, созданный обычным пользователем с правами 600, прочитать не получится. Варианты:

- владелец ключа root, права `600` или `640` (так certbot хранит ключи в `/etc/letsencrypt`);
- для dev-сертификата — `644`, так делает `scripts/gen-dev-cert.sh`;
- в [профиле без root](#профиль-без-root) ключ должен быть доступен uid 65534: например, владелец root, группа 65534, права `640`.

На Docker Desktop (macOS, Windows) файлы из bind mount видны в контейнере как принадлежащие root, поэтому проблема там не проявляется.

### HSTS

`Strict-Transport-Security: max-age=63072000; includeSubDomains` (два года, рекомендация TLSRef 6.0) входит в общий набор заголовков `snippets/security_headers.conf`. Значение задаёт `map $security_strict_transport_security` в `global_security.conf` по `$proxy_x_forwarded_proto`, то есть заголовок отправляется, если клиент получил ответ по HTTPS:

- соединение со шлюзом по TLS;
- или `X-Forwarded-Proto: https` от доверенного балансировщика, который снимает TLS (см. [Реальный IP клиента за балансировщиком](#реальный-ip-клиента-за-балансировщиком)).

Поэтому HSTS есть на всех HTTPS-ответах: страницах, статике, `/api/`, страницах ошибок и редиректах. По HTTP он не отправляется. Подключать что-то в HTTPS-серверах не нужно, а location со своим `add_header` получает HSTS вместе с `response_headers.conf`. Если бэкенд прислал свой `Strict-Transport-Security`, шлюз его не дублирует.

`preload` добавляйте осознанно: исключить домен из preload-списка браузеров очень долго. hstspreload.org требует HSTS и на серверах, которые только редиректят: шаблон редиректа `www → apex` в конце `https_server.conf` получает его автоматически. Для этого шаблона добавьте www-имя и в `server_name` в `http_redirect_server.conf`, чтобы цепочка была `http://www → https://www → https://apex`.

### TLS-политика

`conf.d/globals/global_ssl.conf` соответствует профилю intermediate из [TLSRef 6.0](https://configurator.tlsref.org/) (бывший Mozilla SSL Configuration Generator):

- TLS 1.2 и 1.3; для TLS 1.2 только ECDHE + AEAD, выбор шифра остаётся клиенту (`ssl_prefer_server_ciphers off`), DHE-шифров нет и `ssl_dhparam` не нужен;
- кэш сессий 10 МБ на 1 сутки, session tickets включены;
- группы обмена ключами не заданы: OpenSSL 3.5, который есть во всех образах, сам предлагает первым постквантовый гибрид `X25519MLKEM768` (виден в поле лога `tls.curve`). Явный список групп из TLSRef сломал бы запуск на OpenSSL < 3.5.

### HTTP/3

HTTP/3 (QUIC) включается по желанию и пока экспериментальный. Требования:

- nginx ≥ 1.30.5 / 1.31.6 или Angie ≥ 1.12.2: в них исправлены уязвимости HTTP/3 2026 года. OpenResty 1.31.1.1 этих исправлений не содержит;
- OpenSSL ≥ 3.5.1;
- опубликованный UDP-порт.

Порядок включения:

1. В `https_server.conf` раскомментируйте `include /etc/nginx/snippets/http3.conf;`.
2. В `sites-available/catch_all.conf` в сервере на порту 443 раскомментируйте `listen 443 quic reuseport default_server;` и `listen [::]:443 quic reuseport default_server;`: `reuseport` указывается один раз на адрес и порт.
3. В `compose.yaml` раскомментируйте публикацию `443/udp`.
4. Порт в `Alt-Svc` (`h3=":443"` в `http3.conf`) должен совпадать с внешним портом.

`http3.conf` только задаёт значение: `set $alt_svc 'h3=":443"; ma=86400';`. Сам заголовок `Alt-Svc` отправляет общий набор `security_headers.conf`, поэтому он есть на всех ответах этого сервера, включая API и страницы ошибок.

### OCSP stapling

Stapling выключен. Let's Encrypt с 2025 года не выпускает сертификаты с OCSP-адресом и отключил OCSP-респондеры, а CA/B Forum сделал OCSP необязательным. Для таких сертификатов stapling лишь пишет предупреждение в лог. Для CA, которые OCSP поддерживают, подключите в HTTPS-сервере `snippets/ocsp_stapling.conf`. Ему нужна цепочка CA в `/etc/nginx/ssl/chain.pem`, а DNS для запросов к OCSP-респондеру берётся из `global_resolver.conf`. Stapling несовместим с `ssl_certificate_compression`: nginx ≥ 1.29.3 и Angie откажутся стартовать.

## Страницы ошибок

Ошибки, которые формирует сам шлюз (400, 403, 404, 405, 413, 414, 429, 494, 500, 502, 503, 504), приходят с исходным кодом ответа, заголовками безопасности (по HTTPS — и с HSTS), `X-Request-ID` и `Cache-Control: no-store`. Исключение — внутренний код nginx 494 (слишком большие заголовки): клиент и лог получают его как 400. На ответ 405 добавляется `Allow: GET, HEAD`, как требует RFC 9110.

`snippets/error_pages.conf` подключается в каждом `server{}` **первым**: он фиксирует исходный запрос для лога до любых `return` в фазе rewrite (режим обслуживания, редиректы). Целью `error_page` служит переменная `$error_page_uri` из `map` в `conf.d/globals/global_error_pages.conf`. Формат выбирается по исходному запросу:

- **JSON (RFC 9457)**, `application/problem+json` — если путь равен `/api` или начинается с `/api/`, либо клиент в `Accept` просит JSON (`application/json`, `application/*+json`) и не просит `text/html`;
- **HTML** — во всех остальных случаях.

HTML-страница одна для всех кодов: шаблон `rootfs/var/www/errors/public/error.html`. Код, заголовок, пояснение и ID запроса подставляет SSI, тексты заданы в `global_error_pages.conf`. Пользователь видит ID запроса и может передать его в поддержку:

```bash
curl -s http://localhost/missing -H 'X-Request-ID: 0123456789abcdef0123456789abcdef' | grep -E '<h1>|ID запроса'
#     <h1>Страница не найдена</h1>
#     <p class="muted">Если обращаетесь в поддержку, укажите ID запроса: <code>0123456789abcdef0123456789abcdef</code></p>
```

Тот же адрес для клиента, который просит JSON:

```bash
curl -s http://localhost/missing -H 'Accept: application/json' -H 'X-Request-ID: 0123456789abcdef0123456789abcdef'
```

```json
{"type":"about:blank","title":"Not Found","status":404,"request_id":"0123456789abcdef0123456789abcdef"}
```

- Префиксы своих API добавьте в `map $error_page_uri`. Для одного location без правки map подойдёт `snippets/api_error_pages.conf`: он всегда отдаёт JSON.
- В location страниц ошибок стоит `client_max_body_size 0`. Лимит тела уже проверен в исходном location, а по HTTP/2 nginx проверил бы его повторно и вместо JSON отдал бы встроенную страницу 413. В `location /api/` лимит задан явно (`client_max_body_size 16m`): превышение даёт 413 в JSON, в том числе по HTTP/2.
- Запросы с некорректной строкой запроса (400) или слишком длинным URI (414) обрабатывает catch-all сервер на порту 80 с той же страницей (см. [Неизвестные Host и SNI](#неизвестные-host-и-sni)).

Это касается только ошибок шлюза: бэкенд недоступен (502/504), превышен лимит (429), слишком большое тело (413) и т. п. Ответы бэкенда, включая его собственные 4xx/5xx, проходят без изменений, потому что `proxy_intercept_errors` выключен. Для gRPC есть `grpc_errors.conf` (см. [gRPC](#grpc)).

На уровне `http{}` директивы `error_page` нет. Раньше она указывала на URI, которого нет в новых серверах, и вместе с `recursive_error_pages` зацикливалась: одна ошибка бэкенда превращалась в 11 запросов к нему и ответ 500. Поэтому в каждом новом `server{}` подключайте `error_pages.conf` явно.

## Здоровье и метрики

Служебный сервер описан в `sites-available/status.conf` и включается файлом `sites-enabled/01-status.conf`. Он слушает `127.0.0.1:8080` внутри контейнера, наружу не публикуется, запросы к нему не логируются. Не выключайте его: по `/healthz` работает healthcheck в `compose.yaml`.

| URI | Ответ |
|---|---|
| `GET /healthz` | `{"status":"ok"}` — liveness; по нему работает healthcheck в `compose.yaml` |
| `GET /readyz` | `{"status":"ready"}` — readiness; при необходимости добавьте свои проверки |
| `GET /nginx_status` | `stub_status`, доступ только с `127.0.0.1` |

```bash
make status
# Active connections: 1
# server accepts handled requests
#  11 11 11
# Reading: 0 Writing: 1 Waiting: 0
make health
# {"status":"ok"}
```

В образах разные утилиты: в nginx и Angie есть curl, в OpenResty на Alpine — wget, в OpenResty на Debian нет ни того, ни другого. `make status`, `make health` и healthcheck в `compose.yaml` перебирают curl, wget и `bash /dev/tcp`. Снаружи контейнера можно обратиться через одноразовый контейнер в его сетевом пространстве:

```bash
docker run --rm --network "container:$(docker compose ps -q gateway)" curlimages/curl -s http://127.0.0.1:8080/nginx_status
```

Экспортер Prometheus запускайте в сетевом пространстве шлюза, тогда ему доступен `127.0.0.1:8080`. Например, в `compose.override.yaml`:

```yaml
services:
  exporter:
    image: nginx/nginx-prometheus-exporter:1.5.0
    network_mode: "service:gateway"
    command: ["--nginx.scrape-uri=http://127.0.0.1:8080/nginx_status"]
    restart: unless-stopped
```

Метрики появятся на порту 9113 в сетевом пространстве шлюза: Prometheus в той же docker-сети забирает их с `gateway:9113`. Публиковать порт 8080 наружу или открывать его на всю docker-сеть не нужно. Через NAT Docker Desktop и docker-proxy внешний трафик приходит с приватных адресов, и ACL по RFC 1918 никого бы не отсёк. В Angie вместо `stub_status` можно использовать его API `/status`.

## Эксплуатация

### Применение изменений

Конфигурация смонтирована с хоста, поэтому правки сразу видны в контейнере, но nginx применяет их только при reload:

```bash
make reload        # make check, затем SIGHUP мастер-процессу
# то же вручную:
docker compose kill -s HUP gateway
```

При reload мастер-процесс перечитывает конфигурацию, запускает новые воркеры и мягко завершает старые. Если конфигурация с ошибкой, мастер остаётся на старой и пишет `[emerg]` в лог. `make check` показывает ошибку сразу. Проверить конфигурацию внутри работающего контейнера можно только с явным путём к ней:

```bash
docker compose exec gateway "$NGX_BIN" -c /etc/nginx/nginx.conf -t -g "pid /run/nginx.pid;"
```

Вместо `$NGX_BIN` подставьте бинарник из `.env` (`openresty`, `nginx` или `angie`), если переменная не задана в оболочке.

Внутри контейнера эта конфигурация используется только с `-c /etc/nginx/nginx.conf`. Команды без этого флага читают вкомпилированные пути к конфигурации и pid-файлу, то есть работают с конфигурацией самого образа. В OpenResty проверка читает стоковый `/usr/local/openresty/nginx/conf/nginx.conf` и падает на pid-файле в read-only файловой системе, а сигнал не находит pid-файл `/usr/local/openresty/nginx/logs/nginx.pid`. В Angie сигнал ищет `/run/angie/angie.pid`. В образе nginx пути совпадают случайно. Поэтому для проверки используйте `make check` или команду выше, для reload — `make reload` или `docker compose kill -s HUP gateway`: SIGHUP одинаково работает во всех образах.

### Мягкая остановка

`compose.yaml` останавливает шлюз сигналом `SIGQUIT` (graceful shutdown) с `stop_grace_period: 30s`. В `nginx.conf` задан `worker_shutdown_timeout 25s`: через 25 с после reload или остановки старые воркеры закрывают оставшиеся соединения. Без этого ограничения каждый reload оставлял бы старое поколение воркеров жить, пока идут WebSocket- и SSE-соединения, и воркеры копились бы. Клиенты долгих соединений должны уметь переподключаться после деплоя.

### Процессы и лимиты

- `worker_processes` задаётся переменной `NGX_WORKER_PROCESSES` в `.env` (по умолчанию `auto`). `auto` считает CPU хоста, а не квоту контейнера. Если ограничиваете CPU (`cpus:` в compose), укажите число явно, иначе воркеров будет столько же, сколько ядер у хоста.
- `worker_connections 10240` (`main.d/events.conf`), `worker_rlimit_nofile 65535` (`nginx.conf`) и `ulimits.nofile` 65535 в `compose.yaml` согласованы. Каждое проксируемое соединение занимает два дескриптора, поэтому `worker_connections` должен быть не больше половины `worker_rlimit_nofile`. Поднимая одно, поднимайте и остальные.
- `multi_accept` закомментирован. Директива `use` не задана: nginx сам выбирает epoll или kqueue.

### Hardening

Контейнер шлюза в `compose.yaml` работает с такими ограничениями:

- `read_only: true`: запись возможна только в том кэша `cache-<NGX_BIN>` (`/var/cache/nginx`) и tmpfs `/run`;
- `cap_drop: [ALL]` и `cap_add: [CHOWN, SETUID, SETGID, NET_BIND_SERVICE]`. Мастер-процесс работает от root, чтобы создать каталоги временных файлов, сменить их владельца и понизить привилегии воркеров;
- `no-new-privileges:true`;
- конфигурация и `/var/www` смонтированы только для чтения;
- порты по умолчанию привязаны к `127.0.0.1` (`BIND_ADDR`), порт 8080 не публикуется;
- образы закреплены точными тегами (см. [Обновление образов](#обновление-образов)).

Демо-бэкенд тоже запущен с `read_only`, `cap_drop: [ALL]` и `no-new-privileges`.

### Профиль без root

`compose.nonroot.yaml` запускает весь nginx, включая мастер-процесс, от uid 65534 без каких-либо capabilities:

```bash
docker compose -f compose.yaml -f compose.nonroot.yaml up -d --wait
```

Чтобы остальные команды (`make up`, `docker compose logs` …) тоже использовали этот профиль, добавьте в `.env` строку `COMPOSE_FILE=compose.yaml:compose.nonroot.yaml`. Отличия профиля:

- временные файлы и кэш лежат в tmpfs `/var/cache/nginx` (до 1100 МБ, расходует память и не переживает перезапуск): пользователь без root не может писать на именованный том;
- порты 80 и 443 внутри контейнера доступны без `NET_BIND_SERVICE`, потому что Docker выставляет `net.ipv4.ip_unprivileged_port_start=0`. В Podman и Kubernetes слушайте порты выше 1024;
- ключ TLS должен быть доступен uid 65534 (см. [Права на ключ](#права-на-ключ)).

CI проверяет профиль на образе по умолчанию: шлюз отвечает `200` на `/` и `/api/demo`, мастер-процесс работает с uid 65534. На OpenResty, nginx и Angie он проверен и вручную (uid 65534, `CapEff` 0).

### Режим обслуживания

```bash
touch rootfs/var/www/maintenance/on    # включить: сразу
rm rootfs/var/www/maintenance/on       # выключить: до 30 с или сразу после make reload
```

Пока файл существует, запросы к сайту получают `503` с `Retry-After: 120`: браузеры — HTML-страницу ошибки, клиенты API (`/api/…` или `Accept: application/json`) — `application/problem+json`. Исключения — ACME-проверки и внутренние страницы ошибок. В логе остаются исходные `uri` и `args` запроса. `/healthz` на `127.0.0.1:8080` продолжает отвечать 200, поэтому контейнер не считается нездоровым. После удаления файла nginx ещё до 30 с может считать, что он существует: столько `open_file_cache` помнит результат проверки. `make reload` сбрасывает этот кэш сразу. Файл `on` указан в `.gitignore`.

### Новый сайт

```bash
make new-site NAME=shop DOMAIN=shop.example.com UPSTREAM=shop-app:8080
make reload
```

`scripts/new-site.sh` копирует `sites-available/default` в `sites-available/shop` и заменяет в копии:

- пути `include`;
- имя группы upstream на `shop_backend`: имена upstream и map глобальны для всего `http{}`, и копия с тем же именем не запустилась бы;
- `server_name` в `http_server.conf` на `shop.example.com`;
- `root` на `/var/www/shop/public`;
- адрес бэкенда на `shop-app:8080`.

Кроме того, скрипт создаёт `rootfs/var/www/shop/public/index.html` и включает сайт файлом `sites-enabled/shop.conf`. Имя сайта должно соответствовать `[a-z][a-z0-9_]{0,31}`. Бэкенд адресуется по имени с `resolve`, поэтому nginx стартует, даже если `shop-app` ещё не запущен (до его появления API отвечает 502). Контейнер бэкенда должен быть в той же docker-сети, например добавлен в `compose.override.yaml`.

Для HTTPS замените в `sites-enabled/shop.conf` `default.conf` на `default_https.conf`, в `sites-available/shop/https_server.conf` и `http_redirect_server.conf` замените `server_name localhost` на домен сайта (скрипт меняет имя только в `http_server.conf`), а в `https_server.conf` укажите сертификат сайта.

### Хосты без IPv6

Серверы слушают и IPv4, и IPv6. Все `listen` собраны в четырёх фрагментах: `snippets/listen_http.conf`, `listen_https.conf`, `listen_http_default.conf` и `listen_https_default.conf`. Если IPv6 отключён в ядре (`ipv6.disable=1` на некоторых защищённых ВМ и CI-раннерах), nginx не стартует с ошибкой `Address family not supported by protocol`. Удалите строки с `[::]` в этих четырёх файлах, а если используете HTTP/3, то ещё в `snippets/http3.conf` и в строках `quic` в `sites-available/catch_all.conf`. Сайты, созданные через `make new-site`, используют те же фрагменты. Отключение IPv6 только внутри контейнера (sysctl) к ошибке не приводит: она возникает, когда IPv6 выключен в ядре хоста.

### Локальные изменения compose

Правки для своей машины или сервера (дополнительные тома, экспортер, коллектор OpenTelemetry, свой бэкенд, лимиты CPU) держите в `compose.override.yaml`: Compose подхватывает его автоматически, а в git он не попадает (`.gitignore`). Переменные — в `.env`, образец — `.env.example`.

### Обновление образов

Образы закреплены точными тегами в `compose.yaml`, `.env.example`, `Makefile`, `scripts/test.sh` и `.github/workflows/ci.yml`. Обновления тегов nginx, OpenResty, Angie и whoami предлагает Renovate: в `renovate.json` настроен regex-менеджер по этим файлам. Dependabot раз в неделю предлагает обновления GitHub Actions.

Тег может быть пересобран, поэтому в продакшене закрепляйте и дайджест: `образ:тег@sha256:…`. После смены образа пересоздайте контейнеры: `make down && make up`.

## Тесты и CI

**`scripts/test.sh`** (`make test`) проверяет один образ целиком, 130 проверок:

1. Статические проверки: `scripts/lint.sh`, `docker compose config`, `<бинарник> -c /etc/nginx/nginx.conf -t` без предупреждений.
2. Запуск стека на портах 28080/28443 и проверки curl'ом с хоста и изнутри контейнера:
   - `/healthz` и `stub_status` изнутри контейнера;
   - заголовки безопасности и трассировки, отсутствие HSTS по HTTP;
   - имя узла, цепочка и `X-Prev-Request-ID` скрыты от клиентов через NAT Docker, а имя узла и цепочка видны с loopback;
   - проверка ID, `traceparent`, дописывание, очистка и ограничение цепочки (по эху бэкенда);
   - h2c на порту 80 не принимается;
   - статика и служебные файлы, каноничные URL, включая CRLF-инъекцию и open redirect через `//host` и `/\host`;
   - `405` с `Allow`, `444` для чужого Host, страницы ошибок с ID запроса, JSON-ошибка по `Accept: application/json`, страница 400 для некорректного запроса;
   - заголовки к бэкенду (XFF, httpoxy, h2c), методы API, передача заголовков WebSocket;
   - корректность, типы и маскирование JSON-лога, запись длинных User-Agent, URI и query-строки;
   - `429` и JSON-ошибка при остановленном бэкенде;
   - reload и мягкая остановка.
3. HTTPS-фаза на временной копии `rootfs` с dev-сертификатом:
   - HTTP/2, HSTS на страницах, статике, `/api/`, 404 и 403;
   - `Alt-Svc` и строгий профиль заголовков;
   - `413` по HTTP/2 как `problem+json`;
   - второй сайт, созданный `new-site.sh` и переведённый на HTTPS: редирект, ответ по HTTPS, свой upstream, нет конфликта `server_name`;
   - два hop'а nginx подряд: клиент получает по одной копии заголовков трассировки и безопасности, loopback-клиент видит цепочку из двух hop'ов;
   - редирект на https, ACME, отказ TLS 1.1 и чужого SNI, поля TLS в логе;
   - режим обслуживания: 503, JSON для API, исходные `uri` и `args` в логе, выключение после reload.

   В эту фазу входит тестовый сервер с необязательными фрагментами (HTTP/3, строгий профиль, gRPC, кэш, WebSocket, SSE, hotlink, FastCGI, uWSGI, SCGI, `api_error_pages.conf`): они должны проходить `-t`. `ocsp_stapling.conf` и `otel.conf` сюда не входят: OTel проверяет задание CI `optional-modules`.

В конце выводится итог вида `# 130/130 passed (<образ>)`. Все 130 проверок проходят на OpenResty 1.31.1.1 (bookworm и alpine), nginx 1.30.5, nginx 1.31.6 и Angie 1.12.2. Файлы репозитория тест не меняет. Переменные окружения:

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `NGX_IMAGE`, `NGX_BIN` | из окружения или OpenResty | образ и бинарник |
| `TEST_HTTP_PORT`, `TEST_HTTPS_PORT` | `28080`, `28443` | порты на хосте |
| `COMPOSE_PROJECT_NAME` | `ngxtg-test-<образ>` | имя проекта (не пересекается с рабочим стеком) |
| `HOP_NAME` | `edge-test` | имя узла в проверках |
| `NGX_WORKER_PROCESSES` | `2` | число воркеров |
| `SKIP_HTTPS` | — | `1` — пропустить HTTPS-фазу |
| `LOG_FILE` | — | куда сохранить лог шлюза после прогона |

`make test` передаёт скрипту образ из окружения или `.env`. `make test-all` прогоняет тесты по очереди на пяти образах: `openresty/openresty:1.31.1.1-bookworm`, `openresty/openresty:1.31.1.1-alpine`, `nginx:1.30.5`, `nginx:1.31.6` и `docker.angie.software/angie:1.12.2`.

**`scripts/lint.sh`** (`make lint`) ловит известные ловушки до запуска nginx:

- `error_log off` (создаёт файл с именем `off`);
- устаревший `listen … http2`;
- `$uri`, `${uri}` и `$document_uri` в `return 30x` и `rewrite` (CRLF-инъекция);
- публичные DNS-резолверы;
- правило «всё или ничего» по блокам: `add_header` без `response_headers.conf` и `proxy_set_header` без `proxy_headers.conf` в том же блоке;
- `include` с абсолютным путём на несуществующий файл или каталог и отсутствие `mime.types` и `*_params` рядом с `nginx.conf`;
- символьные ссылки в `rootfs`;
- CRLF и отсутствие перевода строки в конце файла в `.conf`, `.sh`, `.yaml`, `.md`, `.html`, `.json` и других текстовых файлах: список берётся из git, а вне git-репозитория (например, в распакованном архиве) — через `find`.

**CI** (`.github/workflows/ci.yml`) запускается при push в `main`, на pull request, еженедельно по понедельникам и вручную. Задания:

- `lint`: `scripts/lint.sh` и ShellCheck;
- `docs-links`: [lychee](https://github.com/lycheeverse/lychee) с `--offline --include-fragments` проверяет локальные ссылки и якоря во всех `*.md`. Внешние сайты не проверяются, чтобы CI не зависел от их доступности;
- `smoke`: `scripts/test.sh` на матрице из тех же пяти образов. При наличии переменной `DOCKERHUB_USERNAME` и секрета `DOCKERHUB_TOKEN` задание логинится в Docker Hub, чтобы не упереться в лимит анонимных pull. При падении лог шлюза сохраняется как артефакт;
- `nonroot`: профиль `compose.nonroot.yaml` стартует, отдаёт `200` на `/` и `/api/demo`, мастер-процесс работает с uid 65534;
- `optional-modules`: на копии `rootfs` включается OpenTelemetry и выполняется `-t` на `nginx:1.30.5-otel` и `docker.angie.software/angie:1.12.2`.

Обновления образов и GitHub Actions предлагают Renovate и Dependabot (см. [Обновление образов](#обновление-образов)).

## Частые проблемы

**`port is already allocated` или `address already in use` при запуске.** Порт 80 или 443 на хосте занят. Задайте в `.env` другие порты, например `HTTP_PORT=8080` и `HTTPS_PORT=8443`. Каноничные редиректы относительные и порт сохраняют. Редирект HTTP → HTTPS (`redirect_to_https.conf`) строит абсолютный URL без порта и ведёт на 443: при нестандартном `HTTPS_PORT` открывайте `https://localhost:8443/` напрямую. В rootless Docker и Podman порты ниже 1024 на хосте недоступны без настройки, используйте порты выше 1024.

**`curl: (52) Empty reply from server` или `tlsv1 unrecognized name`.** Запрос попал в catch-all сервер: имени из `Host` или SNI нет ни в одном `server_name`. Добавьте домен в `server_name` своего сайта (см. [Неизвестные Host и SNI](#неизвестные-host-и-sni)). Демо-сайт по HTTP отвечает на `localhost` и `127.0.0.1`, по HTTPS — только на `localhost`: `https://127.0.0.1/` всегда получает `tlsv1 unrecognized name`, потому что для IP-адресов клиенты не отправляют SNI. Обращение по IP машины в локальной сети (при `BIND_ADDR=0.0.0.0`) тоже попадёт в catch-all.

**`https://localhost/` не открывается сразу после запуска.** HTTPS по умолчанию выключен: выполните `make https-on` и `make reload`.

**`cannot load certificate "/etc/nginx/ssl/fullchain.pem" … No such file or directory`.** Сайт переключили на HTTPS, но сертификата нет. Выполните `make certs` или положите свой сертификат.

**`cannot load certificate key … Permission denied`.** Контейнер работает без `CAP_DAC_OVERRIDE` и не читает чужой ключ с правами 600 (см. [Права на ключ](#права-на-ключ)).

**Контейнер `unhealthy` или перезапускается.** Посмотрите `docker compose logs gateway` и выполните `make check`: проверка покажет файл и строку с ошибкой.

**Правки конфигурации не применились.** nginx читает конфигурацию только при старте и reload: `make reload`. `docker compose restart` тоже помогает, но перезапускает контейнер, а reload меняет конфигурацию без остановки.

**Проверка или reload изнутри контейнера падает с `open() "…/nginx.pid" failed` или проверяет не `/etc/nginx/nginx.conf`.** Команда запущена без `-c /etc/nginx/nginx.conf` и работает с конфигурацией образа, а не с этой. Используйте `make check` и `make reload` (см. [Применение изменений](#применение-изменений)).

**`Address family not supported by protocol`.** В ядре хоста отключён IPv6 (см. [Хосты без IPv6](#хосты-без-ipv6)).

**Нет `X-HOP-Name`, `X-Request-Chain` или `X-Prev-Request-ID` в ответе.** По умолчанию их видят только клиенты с loopback-адреса, а запросы с хоста на опубликованный порт приходят через NAT Docker (см. [Что видит клиент](#что-видит-клиент)). Бэкенд их получает всегда: в демо цепочку видно в ответе `curl http://localhost/api/demo`. В логе шлюза она есть всегда.

**Бэкенд получает `X-Request-Chain: ~, …` вместо цепочки клиента.** Цепочка была некорректной, или `$trace_accept_client_hops` не разрешает её для адреса клиента (см. [Доверие к узлам клиента](#доверие-к-узлам-клиента)).

**Бэкенд видит адрес балансировщика вместо адреса клиента.** Настройте `global_real_ip.conf` (см. [Реальный IP клиента за балансировщиком](#реальный-ip-клиента-за-балансировщиком)).

**Нагрузочный тест API получает 429.** В демо-сайте `/api/` ограничен 10 r/s с одного IP (`burst=40`) и 50 одновременными соединениями. Локально все клиенты приходят с одного адреса шлюза docker-сети и делят один лимит. Поменяйте `limit_req`/`limit_conn` в `app_locations.conf`.

**Загрузка файла в `/api/` получает 413.** В `location /api/` задан `client_max_body_size 16m`. Для загрузок увеличьте его в нужном location.

**Редкие 502 на POST к бэкенду с keepalive.** `keepalive_timeout` в upstream должен быть меньше idle-таймаута бэкенда (см. [Upstream и keepalive](#upstream-и-keepalive)).

**WebSocket обрывается через минуту простоя, а SSE приходит пачками.** Подключите в location `snippets/websocket.conf` или `snippets/sse.conf` (см. [WebSocket и SSE](#websocket-и-sse)).

**Бэкенд за `proxy_pass https://…` отвечает 502, в логе `upstream SSL certificate verify error`.** Шлюз проверяет сертификат бэкенда. Укажите `proxy_ssl_name` с настоящим именем и, для внутреннего CA, свой `proxy_ssl_trusted_certificate` (см. [TLS к бэкендам](#tls-к-бэкендам)).

**Пропали заголовки безопасности, HSTS или `X-Request-ID` в ответе одного location.** В нём появился свой `add_header` без `include /etc/nginx/snippets/response_headers.conf` (см. [Правило «всё или ничего»](#правило-всё-или-ничего)). То же с `proxy_set_header` и потерей `Host`, `X-Forwarded-*` и трассировки у бэкенда. `make lint` находит такие блоки.

**`unknown directive "otel_exporter"` или ошибка `load_module` при старте.** `snippets/otel.conf` подключён без модуля, или файл в `modules-enabled/` оказался на образе без модуля. OpenTelemetry есть только в образах nginx `*-otel` и Angie (см. [OpenTelemetry](#opentelemetry)).

**Режим обслуживания не выключается.** Подождите до 30 с или выполните `make reload`.

**`mkdir() … Permission denied` при старте профиля без root.** В профиле без root `/var/cache/nginx` должен оставаться tmpfs из `compose.nonroot.yaml`. Если заменили его своим томом или каталогом, он должен принадлежать uid 65534.

## Что изменилось

Версия 2.0.0 несовместима с прежней. Полный список изменений — в [CHANGELOG.md](CHANGELOG.md), пошаговый переход — в разделе [«Как обновиться»](CHANGELOG.md#как-обновиться). Главное, что ломает совместимость:

- **Раскладка и запуск.** Главный файл переехал из `rootfs/usr/local/openresty/nginx/conf/nginx.conf` в `rootfs/etc/nginx/nginx.conf`, блоки `events{}` и `http{}` — из `conf.d/` в `main.d/` (стоковая конфигурация OpenResty подключает `conf.d/*.conf` внутрь своего `http{}`). Динамические модули подключаются из `modules-enabled/`. Каталог `rootfs/etc/nginx` монтируется целиком в `/etc/nginx` (только чтение), бинарник запускается с `-c /etc/nginx/nginx.conf`, и та же конфигурация работает в nginx, OpenResty и Angie. Копии `mime.types` и `*_params` лежат в репозитории.
- **Compose.** `docker-compose.yml` → `compose.yaml`, сервис `openresty` → `gateway`, `container_name` убран (команды — через `docker compose …`). Образ `openresty:latest` заменён точным тегом, порты по умолчанию привязаны к `127.0.0.1`, добавлен демо-бэкенд. Том кэша свой для каждого дистрибутива: `cache-${NGX_BIN}`.
- **Логи** пишутся в stdout/stderr вместо `/var/log/nginx/*.log`, каталога `rootfs/var/log` больше нет.
- **Формат JSON-лога.** Числовые поля стали числами (`timestamp_msec`, `time_sec`, `size_bytes`, `server_port`, `connection.*`). `timestamp` получил миллисекунды, `client.real_ip` переименован в `client.peer_ip`, `service.name` теперь `ngx-trace-gateway`. Удалены `service.instance`, `geo`, `http.request.path`, `http.request.http_version`, `http.request.headers.cookie` и `http.response.headers.date`. Добавлены `trace.trace_id_source`, `trace.traceparent.*`, `tls.curve` и `http.request.suspicious`. `uri_raw` больше не содержит query-строки, `args` берётся из исходного запроса, `args` и `referer` маскируются.
- **Трассировка.** Входящие ID и цепочка проверяются, цепочка ограничена 16 элементами, `traceparent` используется как запасной источник ID. `X-HOP-Name`, `X-Request-Chain` и `X-Prev-Request-ID` в ответе получают только loopback-клиенты (раньше — все). Доверие к цепочке клиента настраивается через `$trace_accept_client_hops`. Имя узла берётся из `HOP_NAME`, а не из ID контейнера. Заголовки трассировки бэкенда больше не дублируются в ответе.
- **FastCGI, uWSGI, SCGI.** Параметры трассировки называются `HTTP_X_…` и подключаются в location фрагментами `snippets/*_trace_params.conf`, а не на уровне `http{}`. `Set-Cookie` приложений больше не скрывается, а заголовки трассировки приложения скрываются.
- **Неизвестные Host** получают `444` (раньше демо-сайт отвечал на любой Host). Свои домены нужно перечислить в `server_name`. h2c на порту 80 не принимается.
- **Редиректы и фильтры.** Убраны добавление завершающего `/`, блокировка SQLi/XSS (теперь только флаг в логе), белый список методов, запреты `..` и системных путей. Редиректы относительные и защищены от CRLF и open redirect. Защита от хотлинкинга стала опциональной.
- **Заголовки.** `X-XSS-Protection: 0` вместо `1; mode=block`, `Referrer-Policy: strict-origin-when-cross-origin` вместо `no-referrer` (`no-referrer` остался в строгом профиле), `X-Download-Options` удалён. Заголовки не дублируют те, что прислал бэкенд. HSTS (раньше закомментирован) отправляется на всех HTTPS-ответах.
- **Страницы ошибок.** Вместо `403.html`, `404.html` и `50x.html` — один шаблон `error.html` с SSI, для API и клиентов с `Accept: application/json` — `problem+json`. Ошибки теперь попадают в access-лог.
- **Проксирование.** Keepalive к бэкенду работает (раньше `Connection: close`), `keepalive_timeout` к бэкенду 4 с. `h2c` не пробрасывается. `proxy_read_timeout` 60 с вместо 10 с, не больше двух попыток. Сертификат HTTPS-бэкенда проверяется, для самоподписанного нужен свой CA. Публичный `resolver 1.1.1.1 8.8.8.8` заменён встроенным DNS Docker в `global_resolver.conf`. Кэш включается только явно и пропускает персональные запросы. Нестандартные заголовки `Scheme`, `SERVER_PORT` и `REMOTE_ADDR` к бэкенду больше не отправляются.
- **TLS.** OCSP stapling выключен, `ssl_prefer_server_ciphers off`, session tickets включены.
- **Лимиты** отвечают `429` вместо `503` и применяются к `/api/`. `public_api_ip` — 10 r/s вместо 60 r/m. Активны только `public_api_ip` и `perip_conn`, остальные зоны закомментированы.
- **Служебный сервер** переехал из `conf.d/globals/global_metrics.conf` в `sites-available/status.conf` (включается `sites-enabled/01-status.conf`), слушает только `127.0.0.1:8080` и отвечает на `/healthz` и `/readyz`. Healthcheck обращается к `/healthz`, а не проверяет синтаксис конфигурации.
- **Сайты** включаются файлами с `include` вместо символьных ссылок.
- **Hardening.** Контейнер работает с read-only файловой системой и без `CAP_DAC_OVERRIDE`: проверьте права на ключ TLS.
- **Документация.** `developer_guid.md` переехал в `docs/developer-guide.md`.

Новое, что совместимости не ломает: HTTPS-сборка демо-сайта, HTTP/3, gRPC, OpenTelemetry по желанию, профиль без root, генератор сайтов, тесты, CI и Renovate.

## Лицензии сторонних файлов

`rootfs/etc/nginx/mime.types`, `fastcgi_params`, `uwsgi_params` и `scgi_params` — копии стандартных файлов из официального образа `nginx:1.30.5` и распространяются по лицензии nginx (BSD-2-Clause). В `mime.types` добавлены типы `mjs`, `map` и `webmanifest`. Копии лежат в репозитории, потому что относительный `include` разрешается от каталога `nginx.conf`, и только так он одинаково работает в nginx, OpenResty и Angie.
