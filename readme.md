# Эталонная конфигурация Nginx/OpenResty (Docker Compose)

Готовый к запуску шаблон конфигураций Nginx с модульной структурой, сквозной трассировкой запросов, структурированным JSON‑логированием, продуманными настройками proxy/кэша/gzip/TLS и базовой безопасностью. Подходит как стартовая точка для высоконагруженных проектов.


## Содержание

- Быстрый старт
- Структура проекта
- Как это устроено (nginx.conf → http → globals → vhosts)
- Глобальные модули (proxy, trace, logging, cache, gzip, TLS, security, rate limit)
- Виртуальные хосты и upstream’ы
- Трассировка и заголовки
- Логирование (JSON)
- Кэш и временные директории
- Безопасность и канонизация URL
- HTTPS и сертификаты
- Проверка конфигурации и управление
- Траблшутинг (FAQ)


## Быстрый старт

Требования: Docker и Docker Compose.

Запуск:

```bash
docker-compose up -d
```

По умолчанию:

- Открыты порты 80 и 443 на хосте.
- Логи (`/var/log/nginx`) и кэш (`/var/cache/nginx`) проброшены на хост.
- Включён healthcheck на `nginx -t`.

Проверка:

```bash
curl -i http://localhost/
docker exec -it openresty nginx -t
```

Остановить:

```bash
docker-compose down
```

## Структура проекта

```text
.
├── docker-compose.yml
├── readme.md
├── rootfs/
│   ├── usr/local/openresty/nginx/conf/nginx.conf      # главный конфиг (включает events и http)
│   ├── usr/local/openresty/nginx/html/index.html      # тестовая главная страница
│   ├── etc/nginx/conf.d/
│   │   ├── events.conf                                # events {}
│   │   ├── http.conf                                  # http {} + include globals + vhosts
│   │   └── globals/                                   # глобальная политика для всех vhost’ов
│   │       ├── global_tcp.conf
│   │       ├── global_proxy.conf
│   │       ├── global_fastcgi.conf
│   │       ├── global_uwsgi.conf
│   │       ├── global_scgi.conf
│   │       ├── global_rate_limit.conf
│   │       ├── global_hop_name.conf
│   │       ├── global_trace.conf
│   │       ├── global_logging.conf
│   │       ├── global_cache.conf
│   │       ├── global_gzip.conf
│   │       ├── global_ssl.conf
│   │       └── global_error_pages.conf
│   ├── etc/nginx/sites-available/default/
│   │   ├── default.conf                                # «тонкий» агрегатор (includes)
│   │   ├── http_server.conf                            # HTTP vhost (80)
│   │   ├── https_server.conf                           # HTTPS vhost (443, ssl http2)
│   │   ├── upstream.conf                               # upstream backend_upstream
│   │   └── app_redirects_security.conf                 # канонизация URL + базовая защита
│   ├── etc/nginx/sites-enabled/default.conf            # активный vhost (include’ы)
│   ├── var/log/nginx/                                  # access/error логи (монтируются)
│   │   ├── host.access.log
│   │   ├── host.error.log
│   │   └── error.log
│   ├── var/www/errors/public/                          # кастомные страницы ошибок
│   │   ├── 403.html
│   │   ├── 404.html
│   │   └── 50x.html
│   └── var/cache/nginx/                                # кэш и temp‑директории (монтируются)
```

Идея: все «политики по умолчанию» задаются в `globals/`, а конкретные сайты лишь «собирают» нужные блоки и переопределяют то, что требуется.


## Как это устроено

- nginx.conf: подключает `events.conf` и `http.conf`.
- http.conf: задаёт базовые опции HTTP, карту для Upgrade/Connection, временной каталог тел запросов и подключает глобальные модули в правильном порядке. В конце подключает все сайты из `sites-enabled/*.conf`.
- default.conf (sites-available/…): тонкий агрегатор, подключает `upstream.conf`, `http_server.conf` и `https_server.conf`.


## Глобальные модули (основные)

- global_tcp.conf — sendfile, tcp_nopush, tcp_nodelay, keepalive, types_hash.
- global_proxy.conf — таймауты proxy, буферы, поведение next_upstream, заголовки X‑*, ключ кэша, X‑Request‑ID/Chain и мобильные идентификаторы, статус кэша в X‑Proxy‑Cache.
- global_fastcgi.conf, global_uwsgi.conf, global_scgi.conf — аналогичные политики и проброс трассирующих идентификаторов для соответствующих протоколов.
- global_rate_limit.conf — подготовленные зоны limit_req_zone; подключайте `limit_req` точечно в server/location.
- global_hop_name.conf — определение `$hop_physical` (физическое имя узла) и `$hop_name` (логическое имя роли). Источники: карта hostname → hop_physical.
- global_trace.conf — формирование `$trace_request_id`, `$local_request_id`, `$prev_request_id`, `$request_hops_chain`, `$mobile_launch_id`, `$mobile_request_id`.
- global_logging.conf — формат JSON‑логов `structured_log` со множеством полезных полей для корреляции.
- global_cache.conf — общая зона proxy_cache + open_file_cache.
- global_gzip.conf — gzip для текстовых форматов.
- global_ssl.conf — TLS‑политика (протоколы, шифры, stapling, resolver и пр.).
- global_error_pages.conf — общие error_page → внутренние URI в /errors/…


## Виртуальные хосты и upstream’ы

- upstream.conf — группа `backend_upstream` с примерами балансировки (weight/ip_hash/least_conn/random) и keepalive.
- http_server.conf — vhost на 80 порту, базовая статика и подключение модуля канонизации/безопасности.
- https_server.conf — vhost на 443 с http2 и примерами проксирования в `/api/`. Для включения:
  1) укажите пути к сертификатам в https_server.conf;
  2) раскомментируйте include https_server.conf в `sites-available/default/default.conf`.


## Трассировка и заголовки

Для каждого запроса формируются идентификаторы:

- trace_request_id — сквозной ID (из X‑Request‑ID, иначе `$request_id`).
- local_request_id — локальный ID текущего Nginx.
- prev_request_id — ID предыдущего hop (из X‑Prev‑Request‑ID, если был).
- request_hops_chain — цепочка hop’ов, на каждом узле дополняется текущим `hop_name:local_request_id`.
- mobile_launch_id / mobile_request_id — мобильные идентификаторы, если пришли в заголовках.

Заголовки добавляются и проксируются глобально (proxy):

- X‑Request‑ID, X‑Request‑Chain, X‑Prev‑Request‑ID
- X‑Mobile‑Launch‑ID, X‑Mobile‑Request‑ID
- X‑HOP‑Name

Про hop_name:

- `$hop_physical` всегда берётся из `$hostname` (реальный узел).
- `$hop_name` определяется так: карта hostname (если доступно) → `$hop_physical`.


## Логирование (JSON)

- Формат `structured_log escape=json` из `global_logging.conf` выдаёт богатый JSON: timestamp(ISO8601 и msec), severity, service, блоки trace/client/network/tls/http/server/upstream и др.
- Логи пишутся в:
  - access: `/var/log/nginx/host.access.log`
  - error:  `/var/log/nginx/host.error.log`
- Файлы проброшены на хост (см. docker-compose), удобно для анализа и доставки в ELK/Loki/ClickHouse/Splunk.


## Кэш и временные директории

- proxy_cache_path задаёт общую зону кэша: каталог `/var/cache/nginx/gate`


## Безопасность и канонизация URL

- global_security.conf добавляет безопасные заголовки (server_tokens off, X‑Content‑Type‑Options, X‑Frame‑Options, Referrer‑Policy, Permissions‑Policy, HSTS и др.).
- app_redirects_security.conf выполняет:
  - редиректы /index.{php,html} → без индекса;
  - удаление пустого «?» и множественных слэшей;
  - добавление завершающего «/» к «чистым» путям при необходимости;
  - простые фильтры SQLi/XSS по QUERY_STRING;
  - запрет .php в /upload, блокировку dot‑файлов, служебных директорий, хотлинкинга.


## HTTPS и сертификаты

Включите `https_server.conf` и укажите пути к сертификатам:

```nginx
ssl_certificate        /path/to/your/fullchain.pem;  # сертификат + цепочка
ssl_certificate_key    /path/to/your/private.key;    # приватный ключ
ssl_trusted_certificate /path/to/ca_chain.pem;       # цепочка доверия (для stapling)
```

Глобальная TLS‑политика — в `globals/global_ssl.conf`.


## Проверка конфигурации и управление

```bash
# Проверка синтаксиса конфигурации
docker exec -it openresty nginx -t

# Применение изменений без остановки
docker exec -it openresty nginx -s reload

# Просмотр access/error логов на хосте
tail -f rootfs/var/log/nginx/host.error.log
tail -f rootfs/var/log/nginx/host.access.log
```


## Траблшутинг (FAQ)

- 80/443 заняты на хосте.
  - Измените маппинг портов в docker-compose.yml (например, `8080:80`, `8443:443`).

- Ошибки прав доступа к кэшу/логам.
  - Убедитесь, что каталоги на хосте существуют и доступны пользователю контейнера; при необходимости поправьте владельца/права.

- Хочу включить rate limiting.
  - В нужном `server {}`/`location {}` добавьте `limit_req zone=<имя> burst=N [delay|nodelay];` — зоны объявлены в `global_rate_limit.conf`.

- Где править backend‑серверы?
  - В `sites-available/default/upstream.conf`.


## Итог

Проект — это не «единственно верный» конфиг, а упакованный набор проверенных практик: модульность, сквозная трассировка, структурированные JSON‑логи, разумные дефолты для TCP/proxy/кэша/gzip/TLS и базовая безопасность. Используйте как основу и адаптируйте под свои требования. Всегда проверяйте изменения `nginx -t` и тестовыми запросами.
