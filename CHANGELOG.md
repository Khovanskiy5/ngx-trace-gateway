# Журнал изменений

Все заметные изменения проекта записываются в этот файл.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
версии — по [семантическому версионированию](https://semver.org/lang/ru/).
У прежнего состояния репозитория (коммит `0d716f1`) номера версии не было,
ниже оно называется «прежней версией».

## [2.0.0] — 2026-09-26

Полная переработка по итогам аудита (139 находок: документация, трассировка
и логи, семантика nginx, безопасность и TLS, проксирование и кэш,
эксплуатация). Конфигурация больше не привязана к OpenResty: одно и то же
дерево `rootfs/etc/nginx` запускается на OpenResty, nginx и Angie. Поведение
закреплено smoke-тестами (`scripts/test.sh`, 130 проверок). Они проходят на
пяти образах: `openresty/openresty:1.31.1.1-bookworm` и `-alpine`,
`nginx:1.30.5`, `nginx:1.31.6`, `docker.angie.software/angie:1.12.2`.

Версия несовместима с прежней: поменялись пути, способ запуска, формат
JSON-лога, заголовки к бэкенду и правила маршрутизации. Перед обновлением
прочитайте раздел «Изменено (ломающие изменения)».

### Критичное и безопасность

- **HTTP response splitting (CRLF-инъекция) в канонических редиректах.**
  Цели 301-редиректов (`/path?` → `/path`, `/a//b` → `/a/b`, `/catalog` →
  `/catalog/`) строились из декодированного `$uri`, поэтому запрос вида
  `/x%0d%0aSet-Cookie:%20pwned=1` к серверу на порту 80 «из коробки»
  добавлял в ответ произвольные заголовки. Теперь цель вычисляет
  `map $canonical_redirect`
  (`conf.d/globals/global_security.conf`) только из «сырого» `$request_uri`,
  который остаётся в percent-encoding. `scripts/lint.sh` запрещает `$uri`,
  `${uri}` и `$document_uri` в `return 30x` и `rewrite`.
- **Канонизация без открытого редиректа.** Location в редиректах стал
  относительным (`absolute_redirect off` в `main.d/http.conf`), а пути,
  начинающиеся с `//` или `/\`, не канонизируются: иначе
  `//evil.example/index.html` превратился бы в `Location: //evil.example/`.
  Канонизация применяется только к GET/HEAD и не трогает `/api/` и
  `/.well-known/`.
- **Серверы по умолчанию для неизвестных Host и SNI.** Раньше демо-сайт был
  `default_server`, и любой Host (запрос по IP, чужой домен) попадал в него,
  отражался в редиректах и уходил бэкенду. Теперь
  `sites-available/catch_all.conf` (включён файлом
  `sites-enabled/00-catch-all.conf`) содержит два сервера:
  - порт 80: `location /` отвечает 444 (соединение закрывается без ответа).
    HTTP/2 здесь не включён, поэтому h2c не принимается ни для одного сайта.
    Сервер подключает `snippets/error_pages.conf`: ошибки разбора запроса
    (400, 414, 494), которые возникают до выбора сайта, получают страницу
    ошибки с ID запроса, а не встроенную страницу nginx;
  - порт 443: `http2 on` и `ssl_reject_handshake on` — TLS-рукопожатие
    отклоняется ещё до выдачи сертификата.
- **Секреты больше не пишутся в access-лог.** Заголовок Cookie из лога убран.
  Query-строка, в которой есть параметр-секрет (`access_token`, `id_token`,
  `refresh_token`, `token`, `code`, `state`, `password`, `secret`, `api_key`,
  `signature`, `session`, `jwt` и др.), заменяется на `[REDACTED]`. Из
  `uri_raw` query-строка убрана, у Referer она заменяется на `?[REDACTED]`.
  Маскирование работает только в access-логе. `error_log` (stderr, тот же
  поток `docker compose logs`) пишет строку запроса с query, адрес upstream
  и Referer как есть. Об этом предупреждают комментарии в `nginx.conf` и
  `global_logging.conf`: храните этот поток так же осторожно, как секреты,
  или поднимите уровень до `error`.
- **Кэш больше не выдаёт чужие ответы.** С уровня http удалены
  `proxy_ignore_headers Expires Cache-Control Set-Cookie Vary` и
  `$http_authorization` в `proxy_cache_key`: при включении `proxy_cache`
  страница и Set-Cookie одного пользователя отдавались другим, а bearer-токены
  попадали в файлы кэша открытым текстом. Теперь заголовки кэширования бэкенда
  учитываются, запросы с Authorization или Cookie идут мимо кэша
  (`$cache_bypass`), а сам кэш включается только точечно
  (`snippets/proxy_cache.conf`).
- **h2c smuggling.** Раньше бэкенду пробрасывалось любое значение `Upgrade`,
  включая `h2c`, что позволяло открыть туннель в обход правил nginx. Теперь
  проходит только `Upgrade: websocket` (`map $proxy_upgrade` в
  `main.d/http.conf`). HTTP/2 без TLS (h2c с prior knowledge) на порту 80 не
  включён ни в одном сервере.
- **Подделка X-Forwarded-For и других заголовков происхождения.** На edge
  клиентский `X-Forwarded-For` отбрасывается, и бэкенд получает только адрес
  TCP-соединения. `X-Forwarded-Proto` клиента не принимается. `Forwarded` и
  `X-Forwarded-Prefix` очищаются, `X-Forwarded-Host` и `X-Forwarded-Port`
  выставляет сам шлюз (раньше клиентские значения доходили до бэкенда). Это
  действует для proxy_pass, gRPC, FastCGI, uWSGI и SCGI. Доверенные
  балансировщики перечисляются в новом `conf.d/globals/global_real_ip.conf`
  (realip и `geo $trusted_proxy`).
- **Проверка TLS-сертификата бэкенда.** Для `proxy_pass https://…` и
  `grpc_pass grpcs://…` включены `*_ssl_verify on`, `*_ssl_server_name on`,
  доверенные CA из `/etc/ssl/certs/ca-certificates.crt`, протоколы TLSv1.2 и
  TLSv1.3. Раньше шлюз принимал любой сертификат бэкенда и не отправлял SNI.
- **httpoxy (CVE-2016-5385).** Клиентский заголовок `Proxy` больше не доходит
  до приложений как переменная `HTTP_PROXY`: `proxy_set_header Proxy ""` для
  proxy_pass, `grpc_set_header Proxy ""` для gRPC и `HTTP_PROXY ""` в
  snippets для FastCGI, uWSGI и SCGI.
- **Set-Cookie больше не вырезается.** Удалены действовавшие на уровне http
  `fastcgi_hide_header`, `uwsgi_hide_header` и `scgi_hide_header Set-Cookie`.
  Они ломали сессии, логин и CSRF-защиту во всех PHP- и Python-приложениях,
  даже при выключенном кэше.
- **Входящие ID трассировки проверяются.** `X-Request-ID`,
  `X-Prev-Request-ID`, `X-Mobile-Launch-ID` и `X-Mobile-Request-ID`
  принимаются только в формате `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`.
  Цепочка `X-Request-Chain` проверяется поэлементно и ограничена 16
  элементами.
  Раньше любые значения отражались клиенту и уходили бэкенду как есть,
  цепочка росла без предела, а невалидный UTF-8 ломал строки JSON-лога.
- **Внутренняя топология не раскрывается.** Раньше `X-HOP-Name`,
  `X-Request-Chain` и `X-Prev-Request-ID` получал в ответе любой клиент.
  Теперь их видят только клиенты с loopback-адресов 127.0.0.1 и ::1
  (`geo $trace_expose_internal` в `global_trace.conf`). Приватные сети в этом
  списке закомментированы намеренно: при публикации порта Docker (NAT,
  userland-proxy), в Kubernetes со SNAT и за балансировщиком без realip любой
  внешний клиент приходит с приватного адреса. Добавляйте сети, только если
  адреса клиентов настоящие (настроен realip). `X-Request-ID` отдаётся всем.
  Бэкенд получает цепочку всегда; в демо её показывает
  `curl http://localhost/api/demo` (эхо whoami). `X-Powered-By` бэкенда
  скрывается.
- **Граница доверия для hop'ов клиента.** Новый
  `geo $trace_accept_client_hops` (`global_trace.conf`) решает, принимать ли
  от клиента `X-Request-Chain` и `X-Prev-Request-ID`. По умолчанию (1)
  проверенные значения принимаются от любого клиента: по контракту
  мобильные и веб-клиенты добавляют в цепочку свой hop. Для внутреннего hop'а
  за своим edge задайте `default 0` и список доверенных сетей: от остальных
  клиентов цепочка заменяется маркером `~`, а `X-Prev-Request-ID`
  отбрасывается.
- **Запреты доступа к служебным файлам работают.** Location для статики стоял
  раньше запрещающих правил, поэтому любой «запрещённый» путь со статическим
  расширением отдавался: `/.env.js`, `/.hidden.css`, `/.git/config.js`,
  `/uploads/x.js`. Теперь `snippets/deny_sensitive_files.conf` (через
  `app_redirects_security.conf`) подключается раньше location со статикой.
  Правила отвечают `return 403`, а не `deny all`: статус тот же, но сканеры,
  перебирающие `/.env` и `/.git`, не засыпают error_log неотмаскированными
  строками.
- **PHP-исходники не отдаются как файлы.** Из `index` убран `index.php`, а
  `.php`, `.phtml` и `.phar` в статическом сайте отвечают 404: раньше без
  PHP-обработчика nginx отдавал исходный код.
- **Служебный сервер закрыт.** stub_status слушал `0.0.0.0:8080` и пускал все
  сети RFC 1918. Его читал любой контейнер в той же сети Docker, а при
  публикации порта — и внешние клиенты: на Docker Desktop, за NAT и
  балансировщиком внешний трафик приходит с приватных адресов. Кроме того,
  сервер отдавал корень сайта по умолчанию. Теперь он слушает только
  `127.0.0.1:8080`, `/nginx_status` доступен лишь с 127.0.0.1, а всё, кроме
  служебных адресов, отвечает 404. Сервер переехал из `conf.d/globals/` в
  `sites-available/status.conf` и включается файлом
  `sites-enabled/01-status.conf`.
- **HSTS включён.** Раньше Strict-Transport-Security не отправлялся вовсе,
  хотя README утверждал обратное. Теперь `max-age=63072000; includeSubDomains`
  входит в общий набор заголовков (`snippets/security_headers.conf`,
  `map $security_strict_transport_security` в `global_security.conf`) и
  отправляется на каждый ответ, который клиент получил по HTTPS: страницы,
  статику, `/api/`, страницы ошибок и редиректы. HTTPS определяется по схеме
  соединения или по `X-Forwarded-Proto` от доверенного балансировщика
  (`$proxy_x_forwarded_proto`). По HTTP заголовок не отправляется. Отдельного
  snippet для HSTS нет, серверам ничего подключать не нужно. В режиме HTTPS
  порт 80 отвечает только на ACME и перенаправляет на `https://`.
- **Публичные DNS-резолверы убраны.** `resolver 1.1.1.1 8.8.8.8` на уровне http
  (в `global_ssl.conf`) отправлял внутренние имена в публичный DNS и ломал
  разрешение имён сервисов Docker. Теперь DNS задан один раз на уровне http,
  в новом `conf.d/globals/global_resolver.conf`:
  `resolver 127.0.0.11 valid=10s ipv6=off` (встроенный DNS Docker). Им
  пользуются `server … resolve` в upstream, `proxy_pass` с переменной и OCSP
  stapling; своих `resolver` в `upstream.conf` и
  `snippets/ocsp_stapling.conf` нет. В Kubernetes укажите адрес kube-dns, без
  Docker — внутренний DNS. `scripts/lint.sh` запрещает публичные резолверы.
- **Контейнер ужесточён.** Read-only корневая ФС, `cap_drop: [ALL]` и только
  `CHOWN`, `SETUID`, `SETGID`, `NET_BIND_SERVICE`, `no-new-privileges`.
  Конфигурация и веб-корень монтируются только на чтение (раньше
  `sites-enabled` и `sites-available` были смонтированы на запись). Порты по
  умолчанию публикуются только на 127.0.0.1. Без `CAP_DAC_OVERRIDE` root в
  контейнере не прочитает чужой файл с правами 600 — проверьте права на ключ
  TLS.
- **Устаревший OpenResty.** `.env.example` предупреждает, что OpenResty
  1.31.1.1 основан на nginx 1.31.1 и не содержит исправлений безопасности
  nginx 1.31.2–1.31.6. Для продакшена без Lua рекомендован nginx stable.

### Исправления

- **Страницы ошибок.** Глобальный `error_page` указывал на `/errors/*.html`,
  которые не обслуживал ни один location. Вместе с `recursive_error_pages on`
  это давало цикл: в любом server{} без своего `error_page` (включая
  служебный на 8080) 404 превращался в 500, а одна ошибка бэкенда — в
  11 обращений к нему и ответ 500 вместо 502/504. Теперь глобального
  `error_page` нет: серверы сайтов и catch-all на порту 80 подключают
  `snippets/error_pages.conf` первым в server{}, и исходный статус
  сохраняется. Служебный сервер на 8080 отвечает встроенными страницами nginx.
- **413 по HTTP/2.** При HTTP/2 nginx проверяет лимит тела повторно, уже в
  location страницы ошибки, и отдал бы встроенную страницу вместо своей. В
  location ошибок задан `client_max_body_size 0`, поэтому 413 приходит
  обычной страницей ошибки (для `/api/` — в `application/problem+json`).
- **Ошибки попадают в access-лог.** Именованные location ошибок содержали
  `access_log off`, поэтому 403, 404 и 5xx (включая 502/504 от бэкенда) в
  логе не появлялись. Теперь они логируются с исходными `uri` и `args`, а не
  с адресом страницы ошибки. `args` берётся из `$request_uri`, который не
  меняется при внутренних редиректах. `uri` фиксируется в
  `snippets/error_pages.conf` до любых `return` фазы rewrite, а для ошибок
  разбора запроса (400, 494), которые возникают ещё раньше, берётся путь из
  `$request_uri`.
- **`error_log off` удалён.** Эта директива не выключает лог, а создаёт файл
  с именем `off` и не даёт nginx стартовать на read-only ФС. `scripts/lint.sh`
  ловит её.
- **Наследование `add_header` и `proxy_set_header` («всё или ничего»).**
  Location статики с `add_header Cache-Control "public"` терял все заголовки
  безопасности и трассировки и отдавал два Cache-Control. Комментарии в
  `https_server.conf` и `upstream.conf` советовали добавить в location
  `proxy_set_header Connection ""`, и тогда бэкенд терял Host,
  X-Forwarded-For и все заголовки трассировки. Теперь статика выставляет
  кэширование только через `expires`, заголовки вынесены в
  `snippets/response_headers.conf` и `snippets/proxy_headers.conf`, а location
  со своими `add_header` подключают общий набор повторно. `scripts/lint.sh`
  проверяет это правило по блокам (server, location, if) во всех файлах
  сайтов и snippets.
- **Keepalive к бэкенду.** `map $http_upgrade $connection_upgrade` отправлял
  `Connection: close`, поэтому каждый запрос открывал новое TCP-соединение, а
  `keepalive 64` ничего не давал. Теперь для обычных запросов `Connection` не
  отправляется, и keepalive работает без правок в location. В upstream
  демо-сайта `keepalive_timeout 4s` — меньше idle-таймаута Node.js (5 с).
  Если бэкенд закрывает простаивающее соединение раньше nginx, возможны
  редкие 502 на POST.
- **Пустые заголовки.** Комментарии в `global_proxy.conf` обещали, что
  заголовки трассировки отправляются «даже если значение пустое». Это
  невозможно: `add_header` и `proxy_set_header` с пустым значением nginx не
  отправляет. Комментарии исправлены: отсутствующий и пустой заголовок
  равнозначны.
- **Дубли заголовков в многоуровневой схеме.** Каждый hop nginx и бэкенды,
  следующие руководству, добавляли свои копии `X-Request-ID`,
  `X-Request-Chain`, `X-HOP-Name` и заголовков безопасности. Теперь эти
  заголовки ответа бэкенда скрываются (`proxy_hide_header`,
  `grpc_hide_header`, `fastcgi_hide_header`, `uwsgi_hide_header`,
  `scgi_hide_header`), а заголовки безопасности добавляются, только если
  бэкенд не прислал свои. Если бэкенд вернул свою цепочку, корректную по
  формату, и ответ не взят из кэша (не HIT, STALE, UPDATING или REVALIDATED),
  клиент с loopback-адреса получает её: она полнее.
- **Трассировка в FastCGI, uWSGI и SCGI.** Параметры назывались как заголовки
  (`fastcgi_param X-Request-ID …`), поэтому PHP- и Python-фреймворки их не
  видели и генерировали собственный trace ID. Типичный
  `location ~ \.php$ { include fastcgi_params; … }` к тому же отменял все
  параметры уровня http, а `X-HOP-Name` не передавался вовсе. Теперь
  параметры называются `HTTP_X_*` и подключаются в location из snippets.
- **`uwsgi_modifier1 30` больше не задаётся глобально.** Это настройка
  конкретного плагина uWSGI (Python), она мешала другим плагинам.
- **Таймауты и повторы.** Сочетание `proxy_read_timeout 10s`,
  `proxy_next_upstream error timeout` и `proxy_next_upstream_tries 3` прогоняло
  медленный запрос по трём бэкендам и завершало его ошибкой через 30 с, а
  WebSocket и стриминг обрывались после 10 с простоя. Теперь таймауты
  чтения и записи 60 с, не больше двух попыток и не дольше 30 с на все
  попытки (`*_next_upstream_timeout 30s`) — для proxy_pass, gRPC, FastCGI,
  uWSGI и SCGI. Для долгих соединений есть `snippets/websocket.conf` и
  `snippets/sse.conf`.
- **`proxy_cache_use_stale`.** Строка была закомментирована и содержала
  опечатку (имя директивы дважды), поэтому `proxy_cache_background_update` не
  работал. Теперь: `error timeout updating http_500 http_502 http_503 http_504`.
- **Кэш FastCGI, uWSGI и SCGI.** Настройки кэша для них не могли работать:
  ни одного `*_cache_path` не было, а зону proxy_cache они использовать не
  могут. Настройки удалены, пример с отдельной зоной оставлен в комментарии
  `global_fastcgi.conf`.
- **Upstream без `zone`.** Счётчики `max_fails`/`fail_timeout` и позиция
  балансировки велись отдельно в каждом воркере. Добавлена
  `zone backend_upstream 256k`. Комментарий предупреждает, что `ip_hash`,
  `hash` и `random` несовместимы с `backup` (раньше их раскомментирование
  ломало запуск).
- **Лимит дескрипторов.** `worker_connections 10240` не подкреплялся
  `worker_rlimit_nofile`. Теперь `worker_rlimit_nofile 65535` в `nginx.conf`
  и `ulimits.nofile` 65535 в `compose.yaml`.
- **`worker_processes auto` в контейнере** считает CPU хоста, а не квоту
  контейнера. Значение задаётся переменной `NGX_WORKER_PROCESSES`.
- **`events`.** Удалён непереносимый `use epoll` (nginx сам выбирает метод),
  `multi_accept on` закомментирован как компромисс, а не «лучшая практика».
- **Мягкая остановка и reload.** `stop_signal: SIGQUIT`,
  `stop_grace_period: 30s` и `worker_shutdown_timeout 25s`. У образа Angie
  STOPSIGNAL не задан, и без `stop_signal` Docker прислал бы SIGTERM — быструю
  остановку с обрывом запросов. После reload старые воркеры с WebSocket и SSE
  раньше жили без ограничения.
- **Healthcheck.** Прежний healthcheck проверял только синтаксис
  конфигурации. Теперь он запрашивает `http://127.0.0.1:8080/healthz` через
  curl, wget или bash (в образах разный набор утилит).
- **Имя hop'а.** Compose не задавал hostname, и в `X-HOP-Name` и цепочку
  попадал случайный ID контейнера. Теперь `hostname: ${HOP_NAME:-edge-gateway}`.
  Примеры в `map $hostname $hop_name` переписаны на короткие имена: ключи-FQDN
  с `$hostname` обычно не совпадали.
- **Монтирование одиночного файла `nginx.conf`** «залипало» после
  атомарного сохранения в редакторе, и reload читал старую версию. Теперь
  монтируются каталоги.
- **Статика отдавала 404.** Location статики указывал на незамонтированный
  `/var/www/default/public/static` (в HTTPS — на `/var/www/example.com/public`).
  Теперь у всего сайта один корень `/var/www/default/public`, а location общие
  для HTTP и HTTPS (`app_locations.conf`).
- **Редирект на завершающий слеш** терял query-строку, превращал POST к API в
  GET, ломал ACME HTTP-01 и не давал разместить `/healthz` в сайте. Он удалён:
  для настоящих каталогов nginx делает этот редирект сам.
- **Редирект повторных слешей** терял query-строку. Теперь она сохраняется,
  как и в редиректе `/index.html` → `/`.
- **ACME HTTP-01.** Добавлен `location ^~ /.well-known/acme-challenge/`
  (`snippets/acme_challenge.conf`, корень `/var/www/acme`).
- **Редирект www → apex** слушал только IPv4. Шаблон в `https_server.conf`
  теперь слушает и `[::]:443` (`snippets/listen_https.conf`) и отправляет
  HSTS из общего набора заголовков (требование hstspreload.org).
- **`charset utf-8` на уровне http** приписывал `charset=utf-8` проксируемым
  ответам без charset (например, windows-1251 от старого бэкенда). Теперь
  кодировка объявляется только для собственных файлов nginx.
- **MIME-типы.** В стандартных `mime.types` нет `.mjs`, `.map` и
  `.webmanifest`, и с `nosniff` браузер отказывался выполнять ES-модули. Копия
  `mime.types` в репозитории дополнена ими, в regex статики добавлены `mjs`,
  `map`, `avif`, `otf`, `eot`, `webmanifest`.
- **gzip.** `application/xml+rss` — несуществующий тип. Список дополнен SVG,
  `application/problem+json`, `application/rss+xml`, `application/atom+xml`,
  `application/ld+json`, `application/vnd.api+json`, `application/manifest+json`,
  `application/wasm`, `text/xml`, `text/markdown` и шрифтами ttf/otf. Включён
  `gzip_static`.
- **Rate limiting.** Зоны были объявлены, но нигде не применялись; превышение
  давало 503; `limit_conn` не было; все клиенты без `X-Consumer-Id` или
  `X-Api-Key` делили одну «корзину» `anon`, и один клиент мог заблокировать
  всех анонимных. Теперь `limit_req_status`/`limit_conn_status 429`, добавлена
  зона `perip_conn`, лимиты применены к `/api/`, ключи из заголовков
  проверяются по формату, а пустой ключ не учитывается. Неиспользуемые зоны
  закомментированы, и память под них не выделяется.
- **Ответы 405 и прочие ошибки шлюза.** 405 отправлялся без обязательного
  заголовка `Allow` (RFC 9110), а 400, 405, 413 и 429 показывали встроенную
  страницу с подписью openresty. Теперь все коды из списка `error_page`
  отдаются одним шаблоном, 405 — с `Allow: GET, HEAD`.
- **`listen … http2`** устарел с nginx 1.25.1 и выдавал предупреждение.
  Заменён на `http2 on;`, `scripts/lint.sh` ловит старую форму.
- **Каталог сайта не годился как шаблон.** Копия `sites-available/default`
  повторно объявляла `upstream backend_upstream` (nginx не стартовал) и
  `map $needs_slash` (вторая копия молча переопределяла первую). Карта
  удалена, а `scripts/new-site.sh` переименовывает upstream в `<имя>_backend`.
- **Символьная ссылка в `sites-enabled`** ломалась при checkout в Windows.
  Заменена обычным файлом с `include`, `.gitattributes` фиксирует LF.
- **Пути временных файлов `/var/run/openresty/…`** существовали только в
  образе OpenResty. Теперь все они в `/var/cache/nginx`.
- **Недостающие значения по умолчанию.** Добавлены таймауты клиента против
  slowloris, `reset_timedout_connection`, `client_max_body_size 16m` и
  буферы для длинных заголовков (JWT, `X-Request-Chain`).
- **Поля JSON-лога** с неверной семантикой: `client.real_ip` описывал адрес
  наоборот, `http.response.headers.date` всегда был пустым,
  `http.response.headers.connection` брал заголовок запроса, а не ответа,
  `path` и `http_version` дублировали `uri` и `network.protocol`. Карты
  `$log_4xx`/`$log_5xx` нигде не использовались.
- **Невалидный JSON в логе.** Невалидный UTF-8 в URI, User-Agent, Referer и
  других полях от клиента ломал строку для строгих парсеров. Теперь такие
  значения заменяются маркером. Проверка UTF-8 использует
  possessive-квантификатор: длинные корректные значения (User-Agent, путь и
  query по несколько килобайт) пишутся как есть, а PCRE JIT не упирается в
  предел стека.
- **Комментарии в конфигурации.** Убраны ссылки на несуществующие заголовки
  и файлы (`X-Local-Request-Id`, `X-Trace-Request-ID`,
  `app_trace_headers.conf`, `app_upstream.conf`, `conf.d/apps/…`,
  `technical-spec-tracing.md`), неработающий адрес экспортера Prometheus
  `openresty:8080`, пояснения, скопированные из другого файла, и опечатки.
  Примеры ID переписаны в допустимом формате.
- **Гигиена репозитория.** Добавлены `.editorconfig` и `.gitattributes`, у всех
  файлов есть завершающий перевод строки. `.gitignore` больше не прячет
  `.env.example` и `*.gz` (заранее сжатые ассеты для `gzip_static`).

### Изменено (ломающие изменения)

#### Как обновиться

1. Остановите старый стек (`docker-compose down`). Каталоги `rootfs/var/log`
   и `rootfs/var/cache` больше не используются, их можно удалить.
2. Скопируйте `.env.example` в `.env` и выберите дистрибутив (`NGX_IMAGE`
   и `NGX_BIN`), имя узла (`HOP_NAME`) и адрес публикации (`BIND_ADDR`).
   Переменные окружения и командной строки имеют приоритет над `.env` — и в
   `docker compose`, и в `make`.
3. Перенесите свои правки в новые пути (таблица ниже). Блоки главного уровня
   (`events{}`, `http{}`) лежат в `main.d/`; в `conf.d/*.conf` их класть
   нельзя, потому что стоковая конфигурация OpenResty подключает эти файлы
   внутрь своего `http{}`.
4. Свои сайты соберите по образцу `sites-available/default/` (или
   `make new-site`): `listen` через `snippets/listen_*.conf`, в server{}
   первым `snippets/error_pages.conf`, затем `app_redirects_security.conf` и
   свои location. Включайте сайт файлом с `include` в `sites-enabled/`.
5. Замените имена демо-сайта на свои домены: `server_name localhost
   127.0.0.1` в `http_server.conf`, `server_name localhost` в
   `https_server.conf` и `http_redirect_server.conf`. Запросы к остальным
   именам закроет catch-all сервер (444). В HTTPS-серверах указывайте только
   доменные имена: для IP-адресов клиенты не отправляют SNI, и такое
   соединение catch-all отклоняет.
6. Положите сертификат в `rootfs/etc/nginx/ssl/fullchain.pem` и
   `rootfs/etc/nginx/ssl/privkey.pem` и включите `default_https.conf`
   (`make https-on`). Ключ должен быть доступен root в контейнере без
   `CAP_DAC_OVERRIDE`: владелец root или права, разрешающие чтение.
7. Перенастройте сбор логов на stdout контейнера и новый набор полей.
8. Проверьте бэкенды: имена параметров FastCGI/uWSGI/SCGI, семантику
   `X-Forwarded-For`, удалённые заголовки `Scheme`, `SERVER_PORT` и
   `REMOTE_ADDR`, idle-таймаут keepalive (в upstream шлюза он 4 с и должен
   быть меньше, чем у бэкенда).
9. Если ваши location ссылались на зоны `app_login`, `security_sensitive`,
   `public_api_user`, `public_api_key`, `admin_area` или `internal_clients`,
   раскомментируйте их в `global_rate_limit.conf`.
10. Если клиентам нужны `X-HOP-Name`, `X-Request-Chain` и
    `X-Prev-Request-ID` в ответе, настройте realip и добавьте их сети в
    `geo $trace_expose_internal`.
11. Запустите `make check`, `make up` и `make test`.

Старые команды и их замены:

| Было | Стало |
|---|---|
| `docker-compose up -d` | `make up` (`docker compose up -d --wait`) |
| `docker-compose down` | `make down` (удаляет и тома кэша) |
| проверка конфигурации в контейнере `openresty` | `make check` |
| reload в контейнере `openresty` | `make reload` (проверка + SIGHUP) |
| запрос к `/nginx_status` из контейнера `openresty` (curl в образе не было) | `make status` (и `make health` для `/healthz`) |
| `tail -f rootfs/var/log/nginx/host.access.log` (и `host.error.log`) | `make logs` (`docker compose logs -f --no-log-prefix gateway`) |

Прежние команды проверки и reload в новом контейнере не работают. Внутри
контейнера конфигурация шлюза используется только с
`-c /etc/nginx/nginx.conf`, а бинарник, запущенный без `-c`, работает с
конфигом и pid-файлом самого образа. Без make:
`docker compose exec gateway "$NGX_BIN" -c /etc/nginx/nginx.conf -t -g "pid /run/nginx.pid;"`
для проверки и `docker compose kill -s HUP gateway` для reload.

#### Файлы, каталоги и запуск

| Было | Стало |
|---|---|
| `rootfs/usr/local/openresty/nginx/conf/nginx.conf` | `rootfs/etc/nginx/nginx.conf` |
| `rootfs/etc/nginx/conf.d/events.conf`, `conf.d/http.conf` | `rootfs/etc/nginx/main.d/events.conf`, `main.d/http.conf` |
| `conf.d/globals/global_metrics.conf` | `sites-available/status.conf`, включается `sites-enabled/01-status.conf` |
| `resolver` в `conf.d/globals/global_ssl.conf` | `conf.d/globals/global_resolver.conf` |
| `docker-compose.yml` | `compose.yaml` (Compose v2: `docker compose`) |
| `readme.md` | `README.md` |
| `developer_guid.md` | `docs/developer-guide.md` (по старому пути — заглушка со ссылкой) |
| `rootfs/usr/local/openresty/nginx/html/index.html` | удалён; сайт — `rootfs/var/www/default/public/` |
| `rootfs/var/www/errors/public/{403,404,50x}.html` | один шаблон `rootfs/var/www/errors/public/error.html` |
| `sites-enabled/default.conf` — символьная ссылка | обычный файл с `include` |
| `/path/to/your/fullchain.pem`, `/path/to/your/private.key` | `/etc/nginx/ssl/fullchain.pem`, `/etc/nginx/ssl/privkey.pem` |
| bind mount `rootfs/var/cache/nginx` | именованный том `cache-${NGX_BIN}` |

- **Монтирование.** В контейнер монтируется весь `rootfs/etc/nginx` в
  `/etc/nginx:ro` и `rootfs/var/www` в `/var/www:ro`; раньше — отдельные
  файлы и каталоги, часть на запись. Копии `mime.types`, `fastcgi_params`,
  `scgi_params` и `uwsgi_params` лежат в `rootfs/etc/nginx`: относительный
  `include` разрешается от каталога главного конфига.
- **Запуск.** Бинарник запускается явно:
  `<nginx|openresty|angie> -c /etc/nginx/nginx.conf -g 'daemon off; worker_processes …; pid …;'`.
  `worker_processes` и `pid` из `nginx.conf` убраны и передаются через `-g` из
  `NGX_WORKER_PROCESSES` (по умолчанию `auto`) и `NGX_PID` (по умолчанию
  `/run/nginx.pid`, раньше `/var/run/nginx.pid`). При запуске без compose их
  нужно передать самостоятельно. `nginx.conf` подключает
  `modules-enabled/*.conf`, затем `main.d/events.conf` и `main.d/http.conf`.
- **Сервис и образ.** Сервис `openresty` переименован в `gateway`,
  `container_name: openresty` удалён: используйте
  `docker compose exec gateway …`. Имя проекта compose — `ngx-trace-gateway`.
  Образ `openresty/openresty:latest` заменён точным тегом
  `openresty/openresty:1.31.1.1-bookworm` (меняется через `NGX_IMAGE`),
  `platform: linux/amd64` удалён: образы multi-arch. В продакшене
  закрепляйте и дайджест (`образ:тег@sha256:…`), обновления тегов предлагает
  Renovate.
- **Порты.** 80 и 443 по умолчанию публикуются только на `127.0.0.1`. Чтобы
  принимать внешний трафик, задайте `BIND_ADDR=0.0.0.0`; внешние порты —
  `HTTP_PORT` и `HTTPS_PORT`. Порт 8080 наружу не публикуется.
- **Порт 443 слушается всегда.** Catch-all сервер слушает 443 и отклоняет
  рукопожатие, даже пока HTTPS для сайта не включён.
- **Логи — в stdout/stderr.** Файлы `/var/log/nginx/host.access.log`,
  `host.error.log`, `error.log` и `metrics.error.log` больше не создаются,
  `rootfs/var/log` не монтируется. Access-лог — `access_log /dev/stdout
  structured_log` на уровне http, ошибки — `error_log stderr warn`. Ротацию
  делает Docker (json-file, 5 файлов по 20 МБ). Как вернуть запись в файлы,
  описано в комментарии `conf.d/globals/global_logging.conf`.
- **Кэш и временные файлы.** Вместо bind mount `rootfs/var/cache/nginx` —
  именованный том для каждого дистрибутива: `cache-openresty`, `cache-nginx`
  или `cache-angie` (`cache-${NGX_BIN}`). Воркеры образов работают от разных
  пользователей (`nobody`, `nginx`, `angie`), и файлы кэша, созданные одним
  образом, другой прочитать бы не смог. Временные каталоги
  `/var/run/openresty/nginx-*` заменены на `/var/cache/nginx/*_temp`.
- **Включение HTTPS.** Раньше нужно было раскомментировать `include` в
  `sites-available/default/default.conf`. Теперь в
  `sites-enabled/default.conf` подключается `default/default_https.conf`
  вместо `default/default.conf` (`make https-on` / `make https-off`). В режиме
  HTTPS порт 80 обслуживает только ACME и перенаправляет на `https://`.
  Редирект ведёт на стандартный порт 443; если `HTTPS_PORT` другой, открывайте
  `https://localhost:<порт>/` напрямую (пояснение в `.env.example`).
- **Имена сайта.** HTTP-сервер демо-сайта отвечает на `localhost` и
  `127.0.0.1`, HTTPS-сервер и редирект с порта 80 — только на `localhost`.
  Dev-сертификат (`make certs`) выпускается только для `DNS:localhost`.
  Остальные Host получают 444, TLS без подходящего SNI отклоняется.
- **HTTP/2** включается директивой `http2 on;` вместо параметра
  `listen 443 ssl http2`. `ssl_trusted_certificate` из server{} убран
  (нужен только для OCSP, см. `snippets/ocsp_stapling.conf`).
- **`listen` вынесены в snippets.** Сайты и catch-all подключают
  `snippets/listen_http.conf`, `listen_https.conf`,
  `listen_http_default.conf` и `listen_https_default.conf` (IPv4 и IPv6). На
  хостах с отключённым IPv6 строки `[::]` удаляются в этих четырёх файлах.
- **Редирект www → apex** больше не включается вместе с HTTPS: теперь это
  закомментированный шаблон в `https_server.conf`.

#### Уровень http и главный конфиг

- `events{}` и `http{}` перенесены из `conf.d/` в `main.d/`: стоковая
  конфигурация OpenResty подключает `/etc/nginx/conf.d/*.conf` внутрь своего
  `http{}`, и блоки главного уровня там недопустимы. В `conf.d/` остался
  только каталог `globals/`.
- `nginx.conf` подключает `/etc/nginx/modules-enabled/*.conf` до `events{}` и
  `http{}` — место для `load_module`. По умолчанию каталог пуст.
- В `conf.d/globals/` остались только директивы уровня http (map, зоны,
  значения по умолчанию). Всё, что работает в server{} и location{},
  вынесено в `/etc/nginx/snippets/` и подключается явно; серверы, включая
  служебный, — в `sites-available/`.
- Удалены `charset utf-8`, `recursive_error_pages on`, глобальный
  `error_page`, `ssl_stapling on` и `ssl_stapling_verify on`.
  `resolver 1.1.1.1 8.8.8.8` заменён на
  `resolver 127.0.0.11 valid=10s ipv6=off` в `global_resolver.conf`. Server{}
  без `include snippets/error_pages.conf` отдаёт встроенные страницы nginx.
- Добавлен `absolute_redirect off`: редиректы на относительный адрес, включая
  редирект nginx на слеш для каталогов, отдают Location без схемы, хоста и
  порта.
- В `nginx.conf` добавлены `worker_rlimit_nofile 65535` и
  `worker_shutdown_timeout 25s`: долгие соединения закрываются через 25 с
  после reload или остановки, клиенты WebSocket и SSE должны уметь
  переподключаться.
- Новые значения по умолчанию: `client_max_body_size 16m` (было 1m по
  умолчанию nginx), `client_header_timeout 15s`, `client_body_timeout 30s`,
  `send_timeout 30s`, `keepalive_timeout 65s` (было 75s по умолчанию),
  `large_client_header_buffers 4 16k`. `open_file_cache`: `max=10000
  inactive=30s`, проверка раз в 30 с, `min_uses 2`, ошибки не кэшируются.

#### Заголовки ответа

- `Referrer-Policy`: `no-referrer` → `strict-origin-when-cross-origin`
  (OWASP HTTP Headers Cheat Sheet, значение браузеров по умолчанию):
  `no-referrer` ломает CSRF-проверки по Origin/Referer (Django, Rails) и
  аналитику. Строгий профиль `snippets/headers_html_strict.conf` включает
  `no-referrer` (OWASP Secure Headers Project) через
  `set $referrer_policy_profile strict;`. Оба источника указаны в
  `global_security.conf`.
- `X-XSS-Protection`: `1; mode=block` → `0` (встроенный фильтр старых
  браузеров устарел и сам создавал уязвимости).
- `X-Download-Options` удалён.
- `Permissions-Policy`: добавлены `payment=()` и `usb=()`.
- Все заголовки безопасности (`X-Content-Type-Options`, `X-Frame-Options`,
  `Referrer-Policy`, `Permissions-Policy`, `X-Permitted-Cross-Domain-Policies`,
  `X-XSS-Protection`, HSTS) добавляются, только если бэкенд не прислал
  одноимённый заголовок.
- `X-HOP-Name`, `X-Request-Chain` и `X-Prev-Request-ID` отдаются только
  клиентам с 127.0.0.1 и ::1 (раньше — всем). За балансировщиком и Docker NAT
  клиент приходит с приватного адреса, поэтому приватные сети добавляйте в
  `geo $trace_expose_internal` только вместе с настроенным realip.
- `X-Request-Chain` в ответе — цепочка бэкенда, если она корректна и ответ не
  из кэша, иначе цепочка шлюза.
- `X-Request-ID`, `X-Request-Chain`, `X-Prev-Request-ID`, `X-HOP-Name` и
  `X-Mobile-*` из ответа бэкенда скрываются (proxy_pass, gRPC, FastCGI,
  uWSGI, SCGI): клиент видит значения шлюза. `X-Proxy-Cache` бэкенда
  скрывается для proxy_pass, FastCGI, uWSGI и SCGI. `X-Powered-By` бэкенда
  скрывается без замены.
- `X-Mobile-Launch-ID` и `X-Mobile-Request-ID` в ответе возвращаются, только
  если входящее значение прошло проверку формата. `X-Prev-Request-ID` —
  кроме того, только loopback-клиентам и только если hop'ы клиента
  принимаются (`$trace_accept_client_hops`).
- Новые заголовки: `Strict-Transport-Security` (все ответы по HTTPS),
  `Alt-Svc` (в server{} с `snippets/http3.conf`; входит в общий набор, поэтому
  есть и на API, и на страницах ошибок), `Retry-After: 1` для 429 и
  `Retry-After: 120` для 503 (если бэкенд не прислал свой),
  `Cache-Control: no-store` для ответов API без собственного Cache-Control и
  для страниц ошибок, `Allow: GET, HEAD` для 405.
- Статика: один `Cache-Control: max-age=2592000` (от `expires 30d`) вместо
  двух заголовков Cache-Control.

#### Трассировка

- Формат ID — `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`: подходят 32 hex,
  UUID, ULID и другие ID из этого алфавита.
- Невалидный `X-Request-ID` (не проходит формат, длиннее 128 символов,
  повторяется в запросе) отбрасывается: trace ID берётся из `traceparent`
  или генерируется (`$request_id`). Невалидные
  `X-Prev-Request-ID` и `X-Mobile-*` отбрасываются: не логируются, не уходят
  бэкенду и не возвращаются клиенту.
- `X-Request-Chain`: элемент — `hop:id` (hop `[A-Za-z0-9._-]{1,64}`, id
  `[A-Za-z0-9._:-]{1,128}`), не больше 16 элементов. От длинной или
  частично некорректной цепочки остаётся корректный хвост (не больше 15
  элементов) за маркером `~`; цепочка без корректного хвоста заменяется
  на `~`.
- Доверие к `X-Request-Chain` и `X-Prev-Request-ID` клиента задаёт
  `geo $trace_accept_client_hops`: по умолчанию 1 (принимаются от всех), для
  внутреннего hop'а — `default 0` и доверенные сети.
- Если корректного `X-Request-ID` нет, trace ID берётся из W3C `traceparent`
  (версия 00), и только потом генерируется. Без модуля OpenTelemetry nginx
  `traceparent` и `tracestate` не создаёт и не меняет (модуль — по желанию,
  см. «Добавлено»).
- Имя hop'а по умолчанию — hostname контейнера (`HOP_NAME`, по умолчанию
  `edge-gateway`). Оно должно соответствовать формату элемента цепочки
  `[A-Za-z0-9._-]{1,64}`, иначе следующий hop не примет цепочку.

#### JSON access-лог (`structured_log`)

Имя формата прежнее, набор и типы полей изменились (описание формата —
`conf.d/globals/global_logging.conf`).

- **Удалены:** `service.instance` (имя узла — в `trace.hop_physical`), `geo`
  (пустой объект; пример для GeoIP2 оставлен в комментарии),
  `http.request.path` (дублировал `uri`), `http.request.http_version`
  (дублировал `network.protocol`), `http.request.headers.cookie`,
  `http.response.headers.date` (всегда был пустым).
- **Переименовано:** `client.real_ip` → `client.peer_ip`. Значение прежнее
  (`$realip_remote_addr`), но смысл описан верно: это адрес непосредственного
  TCP-собеседника (например, балансировщика). Адрес клиента — в `client.ip`;
  при настроенном realip это восстановленный адрес из `X-Forwarded-For`.
- **Изменён смысл:**
  - `timestamp` — с миллисекундами: `2026-09-26T15:06:28.285+00:00`;
  - `service.name` — `ngx-trace-gateway` вместо `nginx` (map `$service_name`
    в `global_hop_name.conf`);
  - `http.request.uri` — для ошибок исходный путь запроса, а не
    `/__errors/…`;
  - `http.request.uri_raw` — путь как пришёл от клиента, без query-строки;
  - `http.request.args` — query-строка из `$request_uri` (не меняется при
    внутренних редиректах); `[REDACTED]`, если в ней есть параметр-секрет;
  - `http.request.headers.referer` — query-строка заменена на `?[REDACTED]`;
  - `http.response.headers.connection` — заголовок Connection ответа
    (`$sent_http_connection`), а не запроса;
  - поля `trace.*` содержат только проверенные значения;
  - клиентские поля с невалидным UTF-8 (`uri`, `uri_raw`, `args`, `user`,
    `user_agent`, `referer`) заменяются на `[invalid-utf8]`, а с не-ASCII
    символами (`host`, `host_header`, `forwarded_for`, `content_type`, `sni`)
    — на `[invalid]`. Длинные корректные значения пишутся как есть;
  - `http.response.status` пишется без ведущих нулей.
- **Строки стали числами:** `timestamp_msec`, `network.server_port`,
  `network.connection.id`, `network.connection.requests`,
  `network.connection.time`, `http.request.size_bytes`,
  `http.response.time_sec`. Поля `network.tcp.*`, `http.upstream.*` и
  `content_length` остались строками: они бывают пустыми, а `$upstream_*` —
  ещё и списками через запятую.
- **Добавлены:** `trace.trace_id_source` (`header`, `traceparent` или
  `generated`), `trace.traceparent.trace_id`, `trace.traceparent.parent_id`,
  `tls.curve`, `http.request.suspicious` (0 или 1).
- Ответы с ошибками (403, 404, 5xx, режим обслуживания, ошибки разбора
  запроса) теперь попадают в лог с исходными `uri` и `args`. Карты `$log_4xx`
  и `$log_5xx` удалены; пример отдельного лога для 5xx оставлен в
  комментарии.
- `error_log` не маскируется (см. «Критичное и безопасность»).

#### Проксирование (proxy_pass)

- Заголовки к бэкенду вынесены в `snippets/proxy_headers.conf` (подключён на
  уровне http). Location со своим `proxy_set_header` или `proxy_hide_header`
  должен подключить этот файл сам.
- Удалены нестандартные заголовки `Scheme`, `SERVER_PORT` и `REMOTE_ADDR`.
  Используйте `X-Forwarded-Proto`, `X-Forwarded-Port` и `X-Real-IP`.
- `X-Forwarded-For` на edge — только адрес клиента, а не
  `$proxy_add_x_forwarded_for` с клиентским значением. За доверенным прокси
  (`global_real_ip.conf`) к пришедшей цепочке добавляется адрес прокси.
- `X-Forwarded-Proto` — схема соединения шлюза; значение от клиента
  принимается только от доверенного прокси.
- Добавлены `X-Forwarded-Host: $host` и `X-Forwarded-Port: $server_port`;
  `Forwarded`, `X-Forwarded-Prefix` и `Proxy` очищаются.
- `Upgrade` пробрасывается только для WebSocket, `Connection` для обычных
  запросов не отправляется (раньше `close`).
- `proxy_read_timeout` и `proxy_send_timeout`: 10s → 60s;
  `proxy_next_upstream_tries`: 3 → 2; добавлен
  `proxy_next_upstream_timeout 30s`.
- Проверка сертификата бэкенда включена. `proxy_pass https://…` на бэкенд с
  самоподписанным сертификатом или сертификатом внутреннего CA теперь
  завершается ошибкой 502. Укажите свой `proxy_ssl_trusted_certificate`.
  Для `proxy_pass` на группу upstream имя для SNI и проверки по умолчанию —
  имя группы, поэтому задайте `proxy_ssl_name`.
- Кэш: ключ `"$scheme|$request_method|$host|$request_uri"` (старый кэш
  недействителен); `keys_zone=appcache` 128m → 32m, `max_size` 10g → 1g;
  `proxy_cache_valid 200 1h` на уровне http удалён, в
  `snippets/proxy_cache.conf` — `200 301 302 10m` и `404 1m`, и то лишь для
  ответов без Cache-Control/Expires.
- Демо-upstream `backend_upstream`: вместо `10.0.0.1–10.0.0.4:9000` —
  `server backend:8080 resolve` (имя перечитывается через DNS из
  `global_resolver.conf`), `keepalive` 64 → 32, `keepalive_timeout 4s`
  (раньше значение по умолчанию 60 с; если idle-таймаут вашего бэкенда
  больше, поднимите значение до чуть меньшего), `keepalive_requests 1000`,
  `fail_timeout` 30s → 10s. Статические адреса оставлены в комментарии. `resolve` в upstream требует
  nginx ≥ 1.27.3, OpenResty ≥ 1.27.3.1 или Angie.
- `location ^~ /api/` проксируется и по HTTP, и по HTTPS (раньше — только в
  невключённом HTTPS-сервере), с лимитами, явным `client_max_body_size 16m`
  и JSON-ошибками.

#### FastCGI, uWSGI, SCGI

- С уровня http удалены `include fastcgi_params`, `SCRIPT_FILENAME`,
  `SCRIPT_NAME`, `include uwsgi_params`, `uwsgi_param QUERY_STRING`/
  `REQUEST_METHOD`, `include scgi_params` и все параметры трассировки.
  В location теперь нужно:
  `include fastcgi_params;` + `include /etc/nginx/snippets/fastcgi_trace_params.conf;`
  (или готовый `snippets/fastcgi_php.conf` с `SCRIPT_FILENAME` и
  `try_files $fastcgi_script_name =404`), для uWSGI и SCGI — аналогичные
  `uwsgi_trace_params.conf` и `scgi_trace_params.conf`.
- Имена параметров: `X-Request-ID` → `HTTP_X_REQUEST_ID` и т. д.
  Приложения читают их обычными средствами для заголовков (PSR-7,
  Laravel/Symfony, Django `request.META`); ключа
  `$_SERVER['X-Request-ID']` больше нет. Параметр `Host` удалён,
  `X-Real-IP`/`X-Forwarded-*` передаются как `HTTP_X_REAL_IP`,
  `HTTP_X_FORWARDED_FOR`, `HTTP_X_FORWARDED_PROTO`, `HTTP_X_FORWARDED_HOST`
  (`$host`) и `HTTP_X_FORWARDED_PORT` (`$server_port`). Добавлены
  `HTTP_X_HOP_NAME`, а также пустые `HTTP_X_FORWARDED_PREFIX`,
  `HTTP_FORWARDED` и `HTTP_PROXY`: они заменяют одноимённые заголовки
  клиента. `X-Mobile-*` передаются, только если непусты.
- Таймауты 10s → 60s, повторов 3 → 2, не дольше 30 с на все попытки
  (`*_next_upstream_timeout 30s`). Удалены `uwsgi_modifier1 30`,
  `*_hide_header Set-Cookie`, `*_ignore_headers` и все `*_cache_*`. Добавлены
  `*_hide_header X-Powered-By` и скрытие заголовков трассировки приложения
  (`X-Request-ID`, `X-Request-Chain`, `X-Prev-Request-ID`, `X-HOP-Name`,
  `X-Mobile-*`, `X-Proxy-Cache`) — в повторно подключаемых
  `snippets/fastcgi_hide_headers.conf`, `uwsgi_hide_headers.conf`,
  `scgi_hide_headers.conf` (правило «всё или ничего» действует и для
  `*_hide_header`).

#### Маршрутизация и защита сайта

- **Удалён список разрешённых методов** на уровне server
  (`GET|HEAD|POST`, остальные — 405). `/api/` принимает любые методы, включая
  PUT, PATCH, DELETE и CORS-preflight OPTIONS: решение за бэкендом. Статика на
  методы кроме GET/HEAD отвечает 405 с `Allow: GET, HEAD`.
- **Удалён редирект на завершающий слеш** и `map $uri $needs_slash` из
  `sites-available/default/default.conf`: `/catalog` отвечает 404, а не 301 на
  `/catalog/`.
- **Изменена канонизация:** только GET/HEAD; не для `/api/` и
  `/.well-known/`; Location относительный; query-строка сохраняется;
  `/…/index.htm` тоже приводится к `/…/`.
- **Удалена блокировка по регулярным выражениям** (`<script`, `GLOBALS`,
  `_REQUEST`, `union…select(`, `concat(`, `..`/`%2e%2e`, пути `/etc|/usr|/var|…`,
  имена конфигов в URI → 403): много ложных срабатываний и простые обходы.
  Подозрительные query-строки теперь только помечаются в логе
  (`http.request.suspicious: 1`). Заблокировать их в выбранном location
  можно так: `if ($request_suspicious) { return 403; }`.
- **Изменён список запретов** (`snippets/deny_sensitive_files.conf`,
  `return 403`): скрытые файлы и каталоги (кроме `/.well-known/`); резервные
  копии, дампы и ключи (`.bak`, `.backup`, `.old`, `.orig`, `.save`, `.swp`,
  `.swo`, `.tmp`, `.sql`, `.sqlite`, `.sqlite3`, `.db`, `.env`, `.ini`,
  `.log`, `.pem`, `.key`, `.p12`, `.pfx`, `~`); конфиги PHP-приложений и
  менеджеров зависимостей; скрипты в `/upload/` и `/uploads/`. Больше не
  запрещены целиком каталоги `/cgi-bin/`, `/includes/`, `/uploads/`, `/tmp/`,
  `/php-cgi/` и файлы `.new`, `.tar`, `.gz`, `.tgz`, `.zip`.
- **Защита от хотлинкинга** выключена по умолчанию: вместо неработавшего
  правила с подменой на `/images/hotlink-placeholder.png` —
  `snippets/hotlink_protection.conf`, который отвечает 403.
- **Страницы ошибок:** именованные location `@error404`, `@error403` и
  `@error50x` удалены. Цель `error_page` — переменная `$error_page_uri`
  (`map` в `conf.d/globals/global_error_pages.conf`), которая решает по
  исходному запросу: путь `/api` или `/api/…` либо `Accept` с JSON и без
  `text/html` → `/__errors/api` (RFC 9457, `application/problem+json`), иначе
  HTML. HTML — один SSI-шаблон из внутреннего `location ^~ /__errors/` для
  кодов 400, 403, 404, 405, 413, 414, 429, 494, 500, 502, 503, 504, он
  показывает код, описание и `X-Request-ID`. `snippets/error_pages.conf`
  подключается в server{} первым: он фиксирует исходный запрос для лога до
  любых `return`. `snippets/api_error_pages.conf` нужен только для API под
  другими префиксами (или добавьте префикс в map).
- Отсутствующий `/favicon.ico` отвечает 204.

#### TLS

- Профиль intermediate из TLSRef 6.0 (бывший Mozilla SSL Configuration
  Generator): `ssl_prefer_server_ciphers on` → `off`, порядок шифров как в
  профиле, `ssl_session_cache shared:SSL:50m` → `10m`,
  `ssl_session_timeout 10m` → `1d`, `ssl_session_tickets off` удалён
  (действует значение по умолчанию — включено).
- `ssl_ecdh_curve` не задаётся: OpenSSL ≥ 3.5 во всех поддерживаемых образах
  первым предлагает постквантовый гибрид X25519MLKEM768.
- OCSP stapling выключен (Let's Encrypt с 2025 года не поддерживает OCSP) и
  вынесен в `snippets/ocsp_stapling.conf`; DNS для него берётся из
  `global_resolver.conf`.

#### Лимиты запросов

- Статус при превышении — 429 вместо 503.
- `public_api_ip`: `60r/m` → `10r/s`.
- Активны только зона `public_api_ip` (`limit_req_zone`) и `perip_conn`
  (`limit_conn_zone`): их использует `/api/` демо-сайта. Шесть остальных
  зон `limit_req_zone` (`app_login`, `security_sensitive`, `public_api_user`,
  `public_api_key`, `admin_area`, `internal_clients`) закомментированы рядом
  со своими примерами. Конфигурация, которая на них ссылается, не пройдёт
  `make check`, пока зона не раскомментирована.
- Ключи `X-Consumer-Id` (`[A-Za-z0-9._:-]{1,64}`) и `X-Api-Key`
  (`[A-Za-z0-9._~-]{16,128}`) больше не заменяются на `anon`: пустой или
  некорректный ключ не учитывается. Зоны по этим ключам используйте только
  вместе с зоной по IP, иначе такие клиенты не ограничиваются вовсе.

#### Служебный сервер

- `conf.d/globals/global_metrics.conf` → `sites-available/status.conf`,
  включается файлом `sites-enabled/01-status.conf`.
- `0.0.0.0:8080` → `127.0.0.1:8080`, `server_name _`. Адрес
  `http://openresty:8080/nginx_status` из других контейнеров больше
  недоступен: экспортер Prometheus запускайте в сетевом пространстве шлюза
  (`network_mode: "service:gateway"`, пример в `status.conf`). Проверка с
  хоста — `make status` и `make health`.

#### Прочее

- `.gitignore`: удалены правила для `rootfs/var/log/`, `rootfs/var/cache/` и
  других runtime-каталогов; добавлены `rootfs/var/www/maintenance/on`, токены
  ACME и `compose.override.*`.

### Добавлено

- **Три дистрибутива, один конфиг.** Проверенные образы:
  `openresty/openresty:1.31.1.1-bookworm` и `-alpine`, `nginx:1.30.5`,
  `nginx:1.31.6`, `docker.angie.software/angie:1.12.2`. Выбор — парой
  `NGX_IMAGE`/`NGX_BIN` в `.env`.
- **`.env.example`**: `NGX_IMAGE`, `NGX_BIN` (с пресетами для всех образов и
  для `nginx:1.30.5-otel`), `HOP_NAME`, `BIND_ADDR`, `HTTP_PORT`,
  `HTTPS_PORT`, `NGX_WORKER_PROCESSES`, `NGX_PID`, `BACKEND_IMAGE`.
- **Демо-бэкенд** `traefik/whoami:v1.11.0` (сервис `backend`):
  `curl http://localhost/api/demo` показывает, какие заголовки трассировки
  получил бэкенд, включая цепочку, которую клиенту не показывают.
- **Демо-сайт** `rootfs/var/www/default/public/`: страница показывает
  `X-Request-ID` текущего запроса (ES-модуль `assets/app.mjs`), есть
  `robots.txt` с `Disallow: /api/`.
- **Новые globals:** `global_real_ip.conf` (шаблон realip и доверенных
  прокси, по умолчанию выключен), `global_resolver.conf` (DNS для имён,
  которые резолвятся во время работы) и `global_grpc.conf`.
- **Snippets** в `rootfs/etc/nginx/snippets/`:
  - заголовки: `response_headers.conf` (общий набор),
    `security_headers.conf` (включая HSTS и Alt-Svc),
    `trace_response_headers.conf`, `api_headers.conf`,
    `headers_html_strict.conf` (CSP, COOP, CORP и `no-referrer` — по
    желанию);
  - listen: `listen_http.conf`, `listen_https.conf`,
    `listen_http_default.conf`, `listen_https_default.conf`;
  - проксирование: `proxy_headers.conf`, `proxy_cache.conf`,
    `websocket.conf`, `sse.conf`;
  - gRPC: `grpc_headers.conf`, `grpc_errors.conf`, `grpc_error_locations.conf`;
  - FastCGI, uWSGI, SCGI: `fastcgi_php.conf`, `fastcgi_trace_params.conf`,
    `uwsgi_trace_params.conf`, `scgi_trace_params.conf`;
  - ошибки: `error_pages.conf`, `api_error_pages.conf`;
  - сайт: `deny_sensitive_files.conf`, `canonical_redirects.conf`,
    `maintenance.conf`, `hotlink_protection.conf`, `acme_challenge.conf`,
    `redirect_to_https.conf`;
  - TLS: `http3.conf`, `ocsp_stapling.conf`;
  - OpenTelemetry: `otel.conf`.
- **OpenTelemetry по желанию.** `modules-available/otel.conf` (`load_module`
  с абсолютными путями для образов nginx `*-otel` и Angie) копируется в
  `modules-enabled/`, затем в `main.d/http.conf` раскомментируется
  `include /etc/nginx/snippets/otel.conf;` (`otel_exporter`, `otel_trace on`,
  `otel_trace_context propagate`). Проверено: конфигурация проходит `-t` на
  `nginx:1.30.5-otel` и Angie 1.12.2; при запросе с `traceparent` бэкенд
  получил новый `traceparent` (спан nginx) с тем же trace-id, а
  `X-Request-ID` совпал с этим trace-id. В OpenResty официального модуля нет.
  Сквозной `X-Request-ID` и цепочка hop'ов работают как без модуля.
- **gRPC.** Бэкенд за `grpc_pass` получает заголовки трассировки,
  `X-Real-IP`, `X-Forwarded-For`, `-Proto`, `-Host` и `-Port`; `Forwarded`,
  `X-Forwarded-Prefix` и `Proxy` очищаются. Для `grpcs://` проверяется
  сертификат, `grpc_next_upstream_timeout 30s`, `X-Powered-By` скрывается.
  Ошибки шлюза отдаются ответом 200 с `Content-Type: application/grpc` и
  `grpc-status` 14 (UNAVAILABLE, для 502/503/504) или 8
  (RESOURCE_EXHAUSTED, для 429) — Trailers-Only по спецификации gRPC.
  Проверено grpcurl: `code = Unavailable`. Код 204 не подходит: nginx убирает
  у него Content-Type, и клиенты видят UNKNOWN.
- **JSON-ошибки для API** (RFC 9457, `application/problem+json`): `type`,
  `title`, `status`, `request_id`. Их получают запросы к `/api` и `/api/…`,
  а также клиенты, которые просят JSON в `Accept` и не просят `text/html`, —
  в том числе при 413 по HTTP/2 и в режиме обслуживания. Ответы бэкенда,
  включая его 4xx/5xx, проходят без изменений.
- **Режим обслуживания:** `touch rootfs/var/www/maintenance/on` — все запросы
  сайта получают 503 с `Retry-After: 120`, кроме ACME; клиенты API получают
  `application/problem+json`; в логе остаются исходные `uri` и `args`;
  `/healthz` продолжает отвечать 200. После `rm` файла режим выключается в
  течение 30 с (столько `open_file_cache` помнит файл) или сразу после
  `make reload`.
- **Служебные адреса** `/healthz` и `/readyz` на `127.0.0.1:8080` рядом с
  `/nginx_status` (`sites-available/status.conf`).
- **HTTPS «из коробки» для разработки:** `default_https.conf`,
  `http_redirect_server.conf`, самоподписанный сертификат только для
  `DNS:localhost` (`make certs`), переключение `make https-on` /
  `make https-off`.
- **HTTP/3 (QUIC) по желанию:** `snippets/http3.conf` (выставляет `$alt_svc`,
  заголовок `Alt-Svc` добавляет общий набор) и закомментированный UDP-порт в
  `compose.yaml`. Требует nginx ≥ 1.30.5 / 1.31.6 или Angie ≥ 1.12.2 и
  OpenSSL ≥ 3.5.1; OpenResty 1.31.1.1 исправлений уязвимостей HTTP/3 2026
  года не содержит.
- **Шаблон редиректа www → apex** для HTTPS-домена (закомментирован в
  `https_server.conf`); HSTS на нём приходит из общего набора заголовков.
- **Лимиты для `/api/`:** `limit_conn perip_conn 50` и
  `limit_req zone=public_api_ip burst=40 delay=20`; новая зона
  `limit_conn_zone perip_conn`.
- **Строгий non-root профиль** `compose.nonroot.yaml`: весь nginx, включая
  мастер-процесс, работает от uid 65534 без capabilities, временные файлы и
  кэш — в tmpfs. Запуск:
  `docker compose -f compose.yaml -f compose.nonroot.yaml up -d --wait`.
- **Makefile:** `help`, `up`, `down`, `restart`, `ps`, `logs`, `check`,
  `reload`, `status`, `health`, `test`, `test-all`, `lint`, `certs`,
  `https-on`, `https-off`, `new-site`. `NGX_IMAGE` и `NGX_BIN` из окружения
  и командной строки перекрывают `.env`, как в `docker compose`. `make check`
  проверяет конфигурацию в отдельном контейнере, `make lint` запускает
  `scripts/lint.sh` и ShellCheck (если установлен) и завершается ошибкой,
  если ShellCheck нашёл проблемы.
- **Скрипты:**
  - `scripts/test.sh` — smoke-тесты на одном образе (130 проверок): `-t` без
    предупреждений, запуск через compose и healthcheck, `/healthz` и
    stub_status изнутри контейнера, заголовки безопасности, скрытие
    заголовков трассировки от не-loopback клиентов, проверка ID и
    `traceparent`, цепочка по эху бэкенда, отказ h2c на порту 80, статика,
    запреты, канонизация, CRLF и открытые редиректы, 444 для чужого Host,
    страницы ошибок и JSON-ошибки по `Accept`, страница 400 для некорректного
    запроса, методы API, заголовки к бэкенду и WebSocket, JSON-лог (включая
    длинные User-Agent, URI и query), 429, отказ бэкенда, reload, мягкая
    остановка, HTTPS (HTTP/2, HSTS на API, 404 и 403, Alt-Svc, строгий
    профиль, 413 по HTTP/2 в `problem+json`), второй сайт через
    `new-site.sh`, ACME, отказ TLS 1.1 и неизвестного SNI, режим
    обслуживания. `make test-all` прогоняет их на всех пяти образах;
  - `scripts/lint.sh` — статические проверки: `error_log off`,
    `listen … http2`, `$uri`/`${uri}` в редиректах, публичные резолверы,
    правило «всё или ничего» для `add_header` и `proxy_set_header` по
    блокам, существование файлов из `include`, символьные ссылки, CRLF и
    завершающий перевод строки (и вне git-репозитория);
  - `scripts/gen-dev-cert.sh` — самоподписанный сертификат для localhost;
  - `scripts/new-site.sh` — новый сайт из шаблона `sites-available/default`
    (`make new-site NAME=shop DOMAIN=shop.example.com UPSTREAM=shop-app:8080`).
- **CI (GitHub Actions)**: при push в `main`, в pull request, вручную и
  раз в неделю по расписанию (ловит изменения в образах):
  - `lint` — `scripts/lint.sh` и ShellCheck;
  - `docs-links` — проверка ссылок и якорей во всех `*.md`
    (`lychee --offline --include-fragments`);
  - `smoke` — `scripts/test.sh` на пяти образах;
  - `nonroot` — запуск `compose.nonroot.yaml` и проверка uid 65534;
  - `optional-modules` — `-t` с включённым OpenTelemetry на
    `nginx:1.30.5-otel` и Angie 1.12.2.
- **Обновления зависимостей:** `renovate.json` (regex-менеджер для тегов
  образов в compose, `.env.example`, Makefile, CI и `scripts/test.sh`),
  Dependabot обновляет версии actions.
- **Документация:** README переписан (быстрый старт, выбор дистрибутива,
  устройство конфигурации, трассировка, лог, безопасность, эксплуатация).
  Руководство разработчика (`docs/developer-guide.md`) описывает контракт
  трассировки (формат ID, цепочку, «пустое значение = нет заголовка», время
  жизни trace ID), границу доверия, связь с W3C Trace Context и
  OpenTelemetry. Примеры интеграции: PHP (PSR-15, Laravel 11/12, Yii2),
  Node.js, Python, Go, Java, браузер (включая CORS), Flutter, Android, iOS и
  очереди; правила для логов, метрик (ID не используются как метки) и Sentry.
- **Файлы репозитория:** `.editorconfig`, `.gitattributes`, `.env.example`,
  `renovate.json`, `CHANGELOG.md`.
