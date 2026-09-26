# Сквозная трассировка запросов: стандарт для команд

Единые правила для DevOps, backend, frontend и mobile: какие идентификаторы
создаёт каждый участник, в каких заголовках они передаются, как их проверять,
логировать и искать. Эталонная реализация на стороне шлюза — конфигурация
nginx / OpenResty / Angie из этого репозитория (см. [README](../README.md)).
Все примеры ниже согласованы с ней и проверены на локальном стенде.

## Содержание

1. [Как это работает](#1-как-это-работает)
2. [Контракт](#2-контракт)
   - [2.1. Идентификаторы](#21-идентификаторы)
   - [2.2. Заголовки](#22-заголовки)
   - [2.3. Формат ID](#23-формат-id)
   - [2.4. Цепочка X-Request-Chain](#24-цепочка-x-request-chain)
   - [2.5. Имя узла (hop_name)](#25-имя-узла-hop_name)
   - [2.6. Пустое значение = нет заголовка](#26-пустое-значение--нет-заголовка)
   - [2.7. Что делает каждый узел](#27-что-делает-каждый-узел)
   - [2.8. Время жизни trace ID](#28-время-жизни-trace-id)
3. [Граница доверия](#3-граница-доверия)
4. [Шлюз: где что в репозитории](#4-шлюз-где-что-в-репозитории)
5. [W3C Trace Context и OpenTelemetry](#5-w3c-trace-context-и-opentelemetry)
6. [Backend](#6-backend)
   - [6.1. PHP: общий класс TraceContext](#61-php-общий-класс-tracecontext)
   - [6.2. PHP: PSR-15, Monolog, Guzzle](#62-php-psr-15-monolog-guzzle)
   - [6.3. Laravel 11/12](#63-laravel-1112)
   - [6.4. Yii2](#64-yii2)
   - [6.5. Node.js: Express и Fastify](#65-nodejs-express-и-fastify)
   - [6.6. Python: FastAPI / Starlette и httpx](#66-python-fastapi--starlette-и-httpx)
   - [6.7. Go: net/http](#67-go-nethttp)
   - [6.8. Java: Spring Boot](#68-java-spring-boot)
7. [Очереди и фоновые задачи](#7-очереди-и-фоновые-задачи)
8. [Frontend (браузер)](#8-frontend-браузер)
9. [Mobile](#9-mobile)
10. [Логи, метрики, Sentry](#10-логи-метрики-sentry)
11. [Проверка на локальном стенде](#11-проверка-на-локальном-стенде)
12. [Пример end-to-end](#12-пример-end-to-end)
13. [Частые ошибки](#13-частые-ошибки)
14. [FAQ](#14-faq)

---

## 1. Как это работает

Одно действие пользователя («Оформить заказ») порождает запросы через
несколько узлов: приложение → шлюз → сервис заказов → сервис оплаты → задача
в очереди. Чтобы по одному ID найти все эти запросы во всех логах и
восстановить их порядок, каждый узел:

- передаёт дальше **сквозной ID** `X-Request-ID` (один на всё действие);
- создаёт **свой локальный ID** на каждый входящий запрос;
- дописывает себя в **цепочку** `X-Request-Chain` в виде `hop_name:local_id`;
- сообщает следующему узлу «предыдущий — это я»: `X-Prev-Request-ID` = свой локальный ID;
- пишет все эти значения в каждую строку своего лога.

```text
mobile-android      local 9d2c4e1f…   X-Request-ID: 4bf92f35…
      │             X-Prev-Request-ID: 9d2c4e1f…
      │             X-Request-Chain:   mobile-android:9d2c4e1f…
      ▼
edge-gateway        local 5fb3d8f7…   (проверяет, дописывает себя)
      │             X-Prev-Request-ID: 5fb3d8f7…
      │             X-Request-Chain:   mobile-android:9d2c4e1f…, edge-gateway:5fb3d8f7…
      ▼
backend-orders      local 52175c5d…
      │             X-Prev-Request-ID: 52175c5d…
      │             X-Request-Chain:   …, edge-gateway:5fb3d8f7…, backend-orders:52175c5d…
      ▼
backend-billing     local 0af76519…   prev_request_id в логе = 52175c5d…
```

Поиск по `4bf92f35…` находит строки всех узлов; `prev_request_id` в строке
лога указывает на строку вызывающего узла, а цепочка показывает весь путь до
текущего узла.

## 2. Контракт

### 2.1. Идентификаторы

| Идентификатор | Что это | Кто создаёт | Сколько живёт |
|---|---|---|---|
| `trace_request_id` | Сквозной ID действия | Первый узел: клиент или, если клиент не прислал, шлюз | Одно пользовательское действие со всеми порождёнными запросами и задачами ([2.8](#28-время-жизни-trace-id)) |
| `local_request_id` | ID запроса на текущем узле | Каждый узел, всегда сам | Один входящий запрос (одна HTTP-попытка, одна задача) |
| `prev_request_id` | `local_request_id` вызывающего узла | Приходит в `X-Prev-Request-ID` | Как у входящего запроса; у первого узла пусто |
| `hops_chain` | Путь запроса: `hop:local_id, hop:local_id, …` | Каждый узел дописывает себя в конец | Как у запроса |
| `hop_name` | Логическое имя узла (роль): `edge-gateway`, `backend-orders` | Конфигурация узла | Постоянно |
| `mobile_launch_id` | Один запуск мобильного приложения | Мобильный клиент при старте | До перезапуска приложения |
| `mobile_request_id` | Один вызов API из мобильного приложения | Мобильный клиент | Один вызов; повтор (retry) того же вызова может сохранять его |

### 2.2. Заголовки

Имена заголовков HTTP нечувствительны к регистру: `X-Request-ID` и
`x-request-id` — одно и то же.

| Заголовок | В запросе к следующему узлу | В ответе шлюза клиенту | Переменная nginx | Поле JSON-лога шлюза |
|---|---|---|---|---|
| `X-Request-ID` | `trace_request_id` | Всегда | `$trace_request_id` | `trace.trace_request_id` |
| `X-Prev-Request-ID` | `local_request_id` отправителя | Эхо значения из запроса клиента — только доверенным клиентам (по умолчанию loopback) | `$prev_request_id` (входящий), `$local_request_id` (исходящий) | `trace.prev_request_id`, `trace.local_request_id` |
| `X-Request-Chain` | `hops_chain` отправителя (с ним самим в конце) | Только доверенным клиентам (по умолчанию loopback) | `$request_hops_chain` | `trace.hops_chain` |
| `X-HOP-Name` | `hop_name` отправителя | Только доверенным клиентам (по умолчанию loopback) | `$hop_name` | `trace.hop_name` |
| `X-Mobile-Launch-ID` | Как пришёл, если корректен | Эхо (если пришёл корректный) | `$mobile_launch_id` | `trace.mobile_launch_id` |
| `X-Mobile-Request-ID` | Как пришёл, если корректен | Эхо (если пришёл корректный) | `$mobile_request_id` | `trace.mobile_request_id` |
| `traceparent`, `tracestate` | Без изменений (если не включён модуль OpenTelemetry, [раздел 5](#5-w3c-trace-context-и-opentelemetry)) | — | `$traceparent_trace_id`, `$traceparent_parent_id` | `trace.traceparent.*` |

Кроме того, шлюз пишет в лог `trace.trace_id_source` — откуда взят trace ID:
`header` (из `X-Request-ID`), `traceparent` или `generated`, и
`trace.hop_physical` — реальный hostname контейнера.

Кто считается доверенным клиентом, описано в [разделе 3](#3-граница-доверия).
Следующий узел получает все заголовки из второй колонки всегда, независимо от
того, что показано клиенту. Что именно он получил, видно в его логах, а на
локальном стенде — в теле ответа демо-бэкенда ([раздел 11](#11-проверка-на-локальном-стенде)).

### 2.3. Формат ID

Одно правило для `X-Request-ID`, `X-Prev-Request-ID`, `X-Mobile-Launch-ID`,
`X-Mobile-Request-ID` и для ID внутри цепочки:

- **Генерируйте:** 32 шестнадцатеричных символа в нижнем регистре (16
  случайных байт), например `4bf92f3577b34da6a3ce929d0e0e4736`. Это формат
  `$request_id` в nginx и trace-id в W3C Trace Context (не должен состоять
  из одних нулей).
- **Принимается:** `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$` — от 1 до 128
  символов, первый — буква или цифра. Поэтому UUID, ULID и ID балансировщиков
  (Envoy, Heroku и т. п.) проходят без изменений. Для ID внутри цепочки
  первый символ не проверяется (грамматика в [2.4](#24-цепочка-x-request-chain)).
- **Всё остальное заменяется:** шлюз отбрасывает неподходящее значение. Вместо
  `X-Request-ID` он берёт trace-id из корректного `traceparent`
  ([раздел 5](#5-w3c-trace-context-и-opentelemetry)) или генерирует новый ID.
  Некорректные `X-Prev-Request-ID` и `X-Mobile-*` становятся пустыми, а
  цепочка с некорректным элементом обрезается по правилам
  [2.4](#24-цепочка-x-request-chain).
  Неподходящими считаются, например, пробелы, кавычки, кириллица, значение
  длиннее 128 символов, а также повторённый заголовок: nginx склеивает два
  `X-Request-ID` в `aaa, bbb`, и это значение уже не проходит проверку.

| Значение | Результат |
|---|---|
| `4bf92f3577b34da6a3ce929d0e0e4736` | принято (рекомендуемый формат) |
| `3f2504e0-4f89-11d3-9a0c-0305e82c3301` | принято (UUID) |
| `_abc`, `bad id with spaces`, `a"b<script>` | заменено |
| 129 символов | заменено |
| два заголовка `X-Request-ID` | заменено |

Бэкенды проверяют входящие значения тем же регулярным выражением
([раздел 3](#3-граница-доверия)); готовый код — в [разделе 6](#6-backend).

### 2.4. Цепочка X-Request-Chain

```text
chain   = [ "~, " ] element *( ", " element )
element = hop ":" id
hop     = [A-Za-z0-9._-]{1,64}
id      = [A-Za-z0-9._:-]{1,128}
```

- Разделитель элементов — запятая и пробел (`, `); при приёме допускается и
  запятая без пробела. Имя узла двоеточий не содержит, поэтому элемент
  делится по первому `:`.
- Узел **только дописывает** себя в конец, ничего не меняя в начале.
- Во входящей цепочке допускается **не больше 16 элементов**. Если их больше
  или среди них есть некорректный, узел оставляет корректный «хвост» — не
  больше 15 последних корректных элементов подряд — и ставит в начало маркер
  `~` («начало цепочки потеряно»). Если корректного хвоста нет, остаётся
  один `~`. После этого узел дописывает себя. Так цепочка не превышает 17
  элементов (около 3,3 КБ) и не упирается в лимиты заголовков на следующих узлах.

Примеры обработки на шлюзе с `hop_name = edge-gateway` (проверено на стенде):

| Входящий `X-Request-Chain` | Исходящий |
|---|---|
| — | `edge-gateway:<local>` |
| `mobile-android:9d2c4e1f7a3b45c8b6e0f1a2d3c4b5a6` | `mobile-android:9d2c4e1f7a3b45c8b6e0f1a2d3c4b5a6, edge-gateway:<local>` |
| 16 элементов `h1:1, …, h16:16` | все 16 + `edge-gateway:<local>` |
| 17 элементов `h1:1, …, h17:17` | `~, h3:3, …, h17:17, edge-gateway:<local>` |
| `a:1, bad, b:2, c:3` | `~, b:2, c:3, edge-gateway:<local>` |
| `evil", "admin":"x` | `~, edge-gateway:<local>` |
| `~, a:1, b:2` | `~, a:1, b:2, edge-gateway:<local>` |

Цепочка — диагностическая информация для людей. Не разбирайте её в бизнес-логике.

### 2.5. Имя узла (hop_name)

- Формат: `[A-Za-z0-9._-]{1,64}`, без двоеточий, запятых и пробелов.
  Рекомендуется нижний регистр и дефисы.
- Это **роль**, а не экземпляр: `edge-gateway`, `api-nginx`,
  `backend-orders`, `backend-orders-queue`, `frontend-web`, `mobile-android`,
  `mobile-ios`. Экземпляры одной роли различаются по `local_request_id`, а
  реальный hostname шлюз пишет в `trace.hop_physical`.
- Шлюз: переменная `HOP_NAME` в `.env` (по умолчанию `edge-gateway`)
  становится hostname контейнера, а из него — `$hop_name`. Если hostname
  задать неудобно (в Kubernetes это имя пода со случайным суффиксом),
  сопоставьте его с ролью в `rootfs/etc/nginx/conf.d/globals/global_hop_name.conf`.
- Бэкенды берут имя из своей конфигурации (в примерах — переменная окружения
  `HOP_NAME` или параметр `app.hop_name`).

### 2.6. Пустое значение = нет заголовка

Отсутствующий заголовок и заголовок с пустым значением означают одно и то же.
nginx не отправляет пустые заголовки: `proxy_set_header`, `grpc_set_header`
и `add_header` с пустым значением просто пропускаются. В FastCGI, uWSGI и
SCGI пустой параметр может прийти пустой строкой — трактуйте её так же, как
отсутствие. Поэтому:

- не отправляйте пустые заголовки и не ждите их: нет `X-Prev-Request-ID` — значит, «пусто»;
- в логах пустое значение пишется пустой строкой `""`;
- не отправляйте строки `null`, `undefined`, `None`: формально они проходят
  проверку формата и станут «настоящим» ID.

### 2.7. Что делает каждый узел

**Входящий запрос (или сообщение из очереди):**

1. `trace_request_id` = `X-Request-ID`, если значение корректно. Иначе можно
   взять trace-id из корректного `traceparent` (так делает шлюз), иначе —
   новый ID.
2. `prev_request_id` = `X-Prev-Request-ID`, если корректно, иначе пусто.
3. `local_request_id` = новый ID. Создаётся всегда, даже если trace ID
   только что сгенерирован.
4. `hops_chain` = входящая цепочка после проверки и обрезки ([2.4](#24-цепочка-x-request-chain)) + `, ` + `hop_name:local_request_id`.
5. `mobile_launch_id`, `mobile_request_id` = входящие значения, если корректны.
6. Всё это кладётся в контекст запроса и добавляется в каждую строку лога.

**Исходящий запрос (HTTP, gRPC, сообщение в очередь):**

| Заголовок | Значение |
|---|---|
| `X-Request-ID` | `trace_request_id` |
| `X-Prev-Request-ID` | свой `local_request_id` — для следующего узла «предыдущий» это мы |
| `X-Request-Chain` | свой `hops_chain` (он уже заканчивается на нас) |
| `X-HOP-Name` | свой `hop_name` |
| `X-Mobile-Launch-ID`, `X-Mobile-Request-ID` | как пришли, если не пустые |
| `traceparent`, `tracestate` | не трогать: ими управляет OpenTelemetry SDK, если он есть |

**Ответ:**

- Заголовки трассировки в ответе клиенту выставляет **только внешний узел**
  (шлюз). Бэкенд за шлюзом их в ответ не ставит. Если всё же ставит, шлюз
  скрывает копии для всех протоколов (`proxy_pass`, `grpc_pass`,
  `fastcgi_pass`, `uwsgi_pass`, `scgi_pass`), и клиент получает по одной
  копии каждого заголовка.
- Исключение: бэкенд может вернуть `X-Request-Chain` со своей цепочкой. Тогда
  доверенные клиенты ([раздел 3](#3-граница-доверия)) увидят её вместо
  цепочки шлюза: в ней больше узлов. Шлюз берёт цепочку бэкенда, только если
  она корректна по формату [2.4](#24-цепочка-x-request-chain) (до 32
  элементов) и ответ получен от бэкенда, а не из кэша (`HIT`, `STALE`,
  `UPDATING`, `REVALIDATED`): в кэше лежит цепочка чужого запроса.
- Сервис, к которому клиенты обращаются без шлюза, сам возвращает `X-Request-ID`.

**Клиент (браузер, мобильное приложение) — первый узел:**

- `trace_request_id` — новый на каждое пользовательское действие;
- `local_request_id` — новый на каждую HTTP-попытку;
- `X-Prev-Request-ID` = `local_request_id`, `X-Request-Chain` = `hop_name:local_request_id`.
  Шлюз по умолчанию принимает их от любого клиента; если оператор это
  отключил (`$trace_accept_client_hops`, [раздел 3](#3-граница-доверия)),
  hop клиента в цепочке заменяется маркером `~`;
- мобильные приложения добавляют `X-Mobile-Launch-ID` и `X-Mobile-Request-ID`;
- `X-HOP-Name` клиенту отправлять не нужно: шлюз заменяет его своим именем;
- `X-Request-ID` из ответа — это ID, по которому поддержка найдёт запрос.
  Показывайте его в сообщениях об ошибках и отправляйте в Sentry. Если
  клиент прислал некорректный ID, шлюз вернёт свой;
- `X-Prev-Request-ID`, `X-Request-Chain` и `X-HOP-Name` клиент из интернета
  в ответе не получает. Ответ и так относится к его запросу, а вызов API
  определяет эхо `X-Mobile-Request-ID`.

### 2.8. Время жизни trace ID

Один `trace_request_id` соответствует **одному пользовательскому действию**
и всему, что оно породило: запросам между сервисами, задачам в очереди,
повторам. Он не должен жить всю сессию или всё время работы вкладки. Иначе
поиск по trace ID вернёт тысячи несвязанных запросов, а формат trace-id в
W3C/OpenTelemetry предполагает одну трассировку на одно действие.

- Сессию мобильного приложения связывает `mobile_launch_id`. Для веба
  используйте свой ID сессии в логах фронтенда, но не в `X-Request-ID`.
- Если действия в коде не выделены, создавайте новый trace ID на каждый
  запрос. Так по умолчанию работают все примеры ниже; чтобы связать несколько
  запросов одного действия, передайте им один и тот же trace ID.
- Повтор (retry) того же вызова сохраняет `trace_request_id` и
  `mobile_request_id`, но получает новый `local_request_id`.

## 3. Граница доверия

**Что гарантирует шлюз.** Все входящие значения трассировки проверяются в
`global_trace.conf`: формат и длина ID, повторённые заголовки, длина цепочки.
Кавычки, управляющие символы, невалидный UTF-8 и значения размером в
килобайты из `X-Request-ID`, `X-Prev-Request-ID`, `X-Request-Chain` и
`X-Mobile-*` не попадают ни к бэкендам, ни в JSON-лог. Исключение —
`traceparent` и `tracestate`: они уходят к бэкенду как пришли
([раздел 5](#5-w3c-trace-context-и-opentelemetry)), а в лог пишутся только
проверенные поля `traceparent`.

**Чего шлюз не гарантирует.** Подлинности. Клиент из интернета может
прислать корректный по формату, но чужой `X-Request-ID` или выдуманные
элементы цепочки. Отсюда правила:

- ID трассировки служат только для корреляции логов. Не используйте их для
  авторизации, как ключ идемпотентности, ключ кэша или лимитов.
- Бэкенд, к которому можно обратиться в обход шлюза (из внутренней сети,
  из другого сервиса, через очередь), проверяет входящие значения по тем же
  правилам. Код в [разделе 6](#6-backend) это делает.

Обе настройки ниже — `geo` в `rootfs/etc/nginx/conf.d/globals/global_trace.conf`.
Адрес клиента в них — `$remote_addr`, то есть после realip
(`global_real_ip.conf`), если он настроен. После правки — `make reload`.

**Что показывать клиенту: `$trace_expose_internal`.** `X-HOP-Name`,
`X-Request-Chain` и эхо `X-Prev-Request-ID` в ответе раскрывают внутреннюю
топологию. По умолчанию шлюз показывает их только клиентам с loopback-адресов
(`127.0.0.1`, `::1`); `X-Request-ID` и эхо `X-Mobile-*` получают все.
Приватных сетей (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) в списке
нет намеренно, строка-пример для `10.0.0.0/8` закомментирована: при
публикации порта Docker (Docker Desktop, userland-proxy), в Kubernetes с
SNAT и за балансировщиком без realip **любой** внешний клиент приходит с
приватного адреса и увидел бы топологию. Добавляйте сети, только если адреса
клиентов настоящие: realip настроен, SNAT нет. На локальном стенде запрос с
хоста тоже приходит через NAT Docker, поэтому в ответе этих заголовков нет —
смотрите, что получил бэкенд ([раздел 11](#11-проверка-на-локальном-стенде)).

**Чьим hop'ам верить: `$trace_accept_client_hops`.** `X-Request-Chain` и
`X-Prev-Request-ID` описывают узлы до шлюза и ничем не подписаны. По
контракту браузер и мобильное приложение добавляют в цепочку свой hop,
поэтому по умолчанию (`default 1`) шлюз принимает проверенные значения от
любого клиента — как справочные данные, а не как доказательство. Если перед
шлюзом таких клиентов нет (например, это внутренний узел за вашим edge),
поставьте `default 0` и перечислите доверенные сети:

```nginx
geo $trace_accept_client_hops {
    default          0;
    10.0.0.0/8       1;   # сеть внешнего шлюза
}
```

От остальных клиентов цепочка заменяется маркером `~`, а `X-Prev-Request-ID`
отбрасывается (в логе `prev_request_id` пустой). `X-Request-ID` и
`X-Mobile-*` принимаются по-прежнему. Проверено на стенде: запрос с
`X-Request-Chain: mobile-android:9d2c…` уходит к бэкенду с цепочкой
`~, edge-gateway:<local>`. Поэтому на шлюзе, к которому обращаются браузеры и
мобильные приложения, оставляйте `default 1`, иначе их hop'ы пропадут из
цепочки и логов.

## 4. Шлюз: где что в репозитории

Пути указаны от корня репозитория; в контейнере `rootfs/etc/nginx`
смонтирован в `/etc/nginx`.

| Файл | Что делает |
|---|---|
| `rootfs/etc/nginx/conf.d/globals/global_trace.conf` | Проверка входящих ID, выбор trace ID (`X-Request-ID` → `traceparent` → `$request_id`), цепочка с ограничением, чьим hop'ам верить (`$trace_accept_client_hops`) и что показывать клиенту (`$trace_expose_internal`) |
| `rootfs/etc/nginx/conf.d/globals/global_hop_name.conf` | `$hop_name` (по умолчанию hostname), `$hop_physical`, `$service_name` |
| `rootfs/etc/nginx/snippets/proxy_headers.conf` | Заголовки к бэкенду при `proxy_pass` и скрытие заголовков трассировки из ответа бэкенда |
| `rootfs/etc/nginx/snippets/grpc_headers.conf` | То же для `grpc_pass`: метаданные `x-request-id` и т. д., `X-Forwarded-*` |
| `rootfs/etc/nginx/snippets/fastcgi_trace_params.conf`, `uwsgi_trace_params.conf`, `scgi_trace_params.conf` | Параметры `HTTP_X_*` для PHP-FPM, uWSGI, SCGI: трассировка, адрес клиента, `X-Forwarded-*` |
| `rootfs/etc/nginx/snippets/fastcgi_php.conf` | Содержимое location для php-fpm: `try_files`, `fastcgi_params`, трассировка |
| `rootfs/etc/nginx/conf.d/globals/global_grpc.conf`, `global_fastcgi.conf`, `global_uwsgi.conf`, `global_scgi.conf` | Таймауты и повторы (не дольше 30 с на все попытки), скрытие заголовков трассировки и `X-Powered-By` из ответа приложения |
| `rootfs/etc/nginx/snippets/trace_response_headers.conf` | Заголовки ответа клиенту (подключается через `response_headers.conf`) |
| `rootfs/etc/nginx/conf.d/globals/global_logging.conf` | JSON-лог в stdout, объект `trace` |
| `rootfs/etc/nginx/conf.d/globals/global_error_pages.conf` | Выбор формата ошибки (`map $error_page_uri`: HTML или JSON) и тексты |
| `rootfs/etc/nginx/snippets/error_pages.conf` | Ошибки шлюза с ID запроса: HTML-страница и JSON (RFC 9457); подключается в `server{}` первым |
| `rootfs/etc/nginx/snippets/api_error_pages.conf` | Принудительно JSON-ошибки для API под другими префиксами |
| `rootfs/etc/nginx/snippets/grpc_errors.conf`, `grpc_error_locations.conf` | Ошибки шлюза для gRPC-клиентов (`grpc-status`) |
| `rootfs/etc/nginx/conf.d/globals/global_real_ip.conf` | Реальный IP клиента за балансировщиком |
| `rootfs/etc/nginx/modules-available/otel.conf`, `snippets/otel.conf` | OpenTelemetry по желанию ([раздел 5](#5-w3c-trace-context-и-opentelemetry)) |
| `scripts/test.sh` | Smoke-тесты, в том числе контракта трассировки (`make test`) |

**Заголовки ответа клиенту** (`trace_response_headers.conf`):

| Заголовок | Когда есть |
|---|---|
| `X-Request-ID` | всегда |
| `X-HOP-Name`, `X-Request-Chain` | доверенный клиент, по умолчанию только loopback ([раздел 3](#3-граница-доверия)) |
| `X-Prev-Request-ID` | доверенный клиент прислал корректный `X-Prev-Request-ID` (эхо) |
| `X-Mobile-Launch-ID`, `X-Mobile-Request-ID` | клиент прислал корректные значения (эхо) |
| `X-Proxy-Cache` | запрос прошёл через `proxy_cache` |

**Правило «всё или ничего».** `add_header`, `proxy_set_header`,
`proxy_hide_header` (и другие `*_hide_header`), `grpc_set_header`,
`fastcgi_param` / `uwsgi_param` / `scgi_param` и `error_page` наследуются с
верхнего уровня, только если на текущем уровне нет ни одной директивы того
же типа. Если в `location` нужен свой `proxy_set_header` или
`proxy_hide_header`, подключите туда же `snippets/proxy_headers.conf`. Если
нужен свой `add_header` — `snippets/response_headers.conf`. Иначе пропадут
все заголовки трассировки. `make lint` (`scripts/lint.sh`) проверяет каждый
блок конфигурации со своим `add_header` или `proxy_set_header`.

```nginx
location /legacy/ {
    include /etc/nginx/snippets/proxy_headers.conf;   # сначала общий набор
    proxy_set_header X-Legacy-Mode "1";
    proxy_pass http://backend_upstream;
}
```

**PHP-FPM, uWSGI, SCGI.** Эти протоколы передают не заголовки, а параметры.
Приложение видит заголовок `X-Request-ID` как параметр `HTTP_X_REQUEST_ID`
(`$_SERVER['HTTP_X_REQUEST_ID']`, PSR-7 `getHeaderLine('X-Request-ID')`,
Django `request.META['HTTP_X_REQUEST_ID']`). Snippets задают эти параметры
значениями шлюза, заменяя сырые клиентские. Подключайте их в каждом
`location` с `fastcgi_pass` / `uwsgi_pass` / `scgi_pass` **после**
стандартного `*_params`. На уровне `http{}` они не задаются намеренно:
первый же `fastcgi_param` в `location` отменил бы их все.

```nginx
location ~ \.php$ {
    include /etc/nginx/snippets/fastcgi_php.conf;   # fastcgi_params + SCRIPT_FILENAME + трассировка
    fastcgi_pass php-fpm:9000;
}

location / {
    include uwsgi_params;
    include /etc/nginx/snippets/uwsgi_trace_params.conf;
    uwsgi_pass django:3031;
}
```

Если сайт на PHP, уберите из `sites-available/default/app_locations.conf`
заглушку, которая отвечает 404 на `.php`. PHP-приложение получает
`HTTP_X_PREV_REQUEST_ID` = `local_request_id` шлюза и `HTTP_X_REQUEST_CHAIN` с
шлюзом в конце: оно следующий узел, как и HTTP-бэкенд.

Кроме трассировки, snippets передают те же сведения об исходном запросе, что
`proxy_headers.conf` для HTTP-бэкенда:

| Параметр | Значение |
|---|---|
| `HTTP_X_REAL_IP` | `$remote_addr` — адрес клиента (после realip) |
| `HTTP_X_FORWARDED_FOR` | адрес клиента; клиентский `X-Forwarded-For` на edge отбрасывается |
| `HTTP_X_FORWARDED_PROTO` | схема исходного запроса (`http` / `https`) |
| `HTTP_X_FORWARDED_HOST` | `$host` — имя сайта без порта (одно из `server_name`) |
| `HTTP_X_FORWARDED_PORT` | `$server_port` — порт, который слушает шлюз |
| `HTTP_X_FORWARDED_PREFIX`, `HTTP_FORWARDED`, `HTTP_PROXY` | пустая строка: клиентские значения стираются |

Фреймворки, которые доверяют прокси (Laravel `TrustProxies`, Symfony
`trusted_proxies`, Django `USE_X_FORWARDED_HOST`), строят по ним адреса и
схему для ссылок и редиректов. Клиент не может подставить свои значения:
параметр шлюза заменяет одноимённый заголовок. `HTTP_PROXY` очищается из-за
httpoxy (CVE-2016-5385). `X-Forwarded-Port` — порт внутри контейнера (80 или
443): если снаружи порт другой, учитывайте это в приложении.

Заголовки трассировки, которые приложение вернёт в ответе, шлюз скрывает
(`fastcgi_hide_header`, `uwsgi_hide_header`, `scgi_hide_header` в
`global_fastcgi.conf` и соседних файлах), поэтому дублей у клиента нет. Свой
`*_hide_header` в `location` отменяет весь унаследованный список —
повторите в нём строки из глобального файла.

**Ошибки шлюза содержат ID запроса.** Это ответы, которые формирует сам шлюз:
бэкенд недоступен (502, 504), превышен лимит (429), тело больше
`client_max_body_size` (413, для `/api/` лимит 16 МБ), страницы нет (404) и
т. п. Ответы бэкенда, включая его собственные 4xx/5xx, проходят без изменений.
Формат выбирает `map $error_page_uri` в `global_error_pages.conf` по
исходному запросу:

- **JSON** (RFC 9457, `Content-Type: application/problem+json`) — если путь
  `/api` или `/api/…` **или** заголовок `Accept` содержит `application/json`
  (или `application/…+json`) и не содержит `text/html`:

  ```json
  {"type":"about:blank","title":"Gateway Timeout","status":504,"request_id":"4bf92f3577b34da6a3ce929d0e0e4736"}
  ```

- **HTML** — во всех остальных случаях, в том числе при обычном переходе
  браузера по странице вне `/api` (`Accept: text/html,…`): одна страница для
  всех кодов, на ней «ID запроса», который пользователь может передать в
  поддержку.

Поэтому API-клиенты под любым путём получают JSON с `request_id`, если
отправляют `Accept: application/json` ([раздел 8](#8-frontend-браузер),
[раздел 9](#9-mobile)). Префиксы своих API добавьте в тот же `map` или
подключите в их `location` `snippets/api_error_pages.conf`. Статус ответа
сохраняется, а строка access-лога содержит исходные `uri` и `args`, а не
адрес внутренней страницы ошибки. Так же работает режим обслуживания
(`snippets/maintenance.conf`): API-клиенты получают `503` в
`application/problem+json`, браузеры — HTML-страницу.

В каждом новом `server{}` подключайте `snippets/error_pages.conf` **первым**:
он фиксирует исходный запрос для лога до любых `return` в фазе rewrite
(режим обслуживания, редиректы). Страницу с ID получает и запрос, который
nginx не смог разобрать (400, 414, 494). Если ошибка возникла до выбора сайта
(испорченная или слишком длинная строка запроса, 414), такой запрос
обрабатывает сервер по умолчанию `sites-available/catch_all.conf` — в нём
тоже подключён `error_pages.conf`. Если `Host` уже прочитан (например,
слишком большой заголовок после него), ошибку отдаёт сам сайт.

gRPC-клиент ждёт статус в `grpc-status`, а не страницу. Для `location` с
`grpc_pass` подключите `snippets/grpc_errors.conf` (и один раз на `server{}` —
`grpc_error_locations.conf`): 502, 503, 504 превращаются в `UNAVAILABLE`
(14), 429 — в `RESOURCE_EXHAUSTED` (8). Ответ — HTTP 200 с
`Content-Type: application/grpc`, как требует спецификация gRPC, и с
`x-request-id` в метаданных.

**Несколько nginx подряд** (`edge-gateway` → `api-nginx` → backend) с этой
конфигурацией работают без доработок. Каждый узел дописывает себя в цепочку
и скрывает заголовки трассировки из ответа следующего, поэтому клиент
получает по одной копии каждого заголовка. На внутреннем узле можно
принимать цепочку только из сети внешнего шлюза (`$trace_accept_client_hops`,
[раздел 3](#3-граница-доверия)).

**В `error_log` nginx trace ID не пишется.** Ищите запрос по access-логу, а
строки `error_log` сопоставляйте по времени и строке запроса. Учтите: в
отличие от JSON access-лога, `error_log` (stderr, тот же поток
`docker compose logs`) ничего не маскирует. Строки `[warn]` и `[error]`
содержат исходную строку запроса с query, адрес upstream и `Referer`.
Храните этот поток так же осторожно, как секреты.

## 5. W3C Trace Context и OpenTelemetry

`X-Request-ID` и OpenTelemetry не конкурируют. `X-Request-ID` — простой ID для
людей и логов, он работает и там, где OpenTelemetry нет. `traceparent` —
формат для APM (Jaeger, Tempo и т. д.).

Что делает шлюз:

- Если корректного `X-Request-ID` нет, а `traceparent` версии `00` корректен,
  `X-Request-ID` = trace-id из `traceparent`. Тогда в логах и в APM один и тот
  же ID. В логе: `trace.trace_id_source = "traceparent"`.
- `traceparent` и `tracestate` уходят к бэкенду **без изменений**. Свой
  `traceparent` шлюз по умолчанию не создаёт: синтетический родительский span
  изменил бы решение о семплировании во всех сервисах ниже и оставил бы в APM
  «висящих» потомков несуществующего span'а. Настоящие span'ы шлюза даёт
  модуль OpenTelemetry — его можно включить (см. ниже).
- В лог пишутся `trace.traceparent.trace_id` и `trace.traceparent.parent_id`:
  по ним строку лога шлюза можно найти из трассы в APM.

Рекомендации:

- Клиент или сервис с OpenTelemetry SDK может ставить `X-Request-ID` равным
  trace-id текущего span'а (32 hex) — один ID для всех систем. Можно и не
  ставить: шлюз возьмёт trace-id из `traceparent`.
- Бэкенды с OpenTelemetry пишут в логи оба значения: `trace_request_id` и
  trace-id из OTel. Заголовок `X-Request-ID` можно записать в атрибут span'а
  `http.request.header.x-request-id`. Большинство SDK делают это через
  настройку захвата заголовков, например в Java-агенте:
  `otel.instrumentation.http.server.capture-request-headers=X-Request-ID`.
- Не генерируйте `traceparent` из `X-Request-ID` вручную (причина — та же,
  что у шлюза). Это задача OpenTelemetry SDK.

**Span'ы на самом шлюзе (по желанию).** Их создаёт `ngx_otel_module`
([документация](https://nginx.org/en/docs/ngx_otel_module.html)). Модуль
есть в образах nginx с суффиксом `-otel` (`nginx:1.30.5-otel`,
`nginx:1.31.6-otel`) и в образе Angie; в OpenResty официального модуля нет,
там остаётся режим «только чтение». По умолчанию модуль выключен. Включение:

1. В `.env` выберите образ с модулем: `NGX_IMAGE=nginx:1.30.5-otel` и
   `NGX_BIN=nginx` (заготовка есть в `.env.example`) или
   `docker.angie.software/angie:1.12.2` и `NGX_BIN=angie`. Пересоздайте
   контейнеры: `make down && make up`.
2. Скопируйте `rootfs/etc/nginx/modules-available/otel.conf` в
   `rootfs/etc/nginx/modules-enabled/` и оставьте в нём строку `load_module`
   только для своего образа: строка для nginx активна, для Angie —
   закомментирована. Пути в файле абсолютные: каталог `/etc/nginx`
   смонтирован целиком, и ссылка `/etc/nginx/modules` из образа nginx
   недоступна.
3. В `rootfs/etc/nginx/main.d/http.conf` раскомментируйте
   `include /etc/nginx/snippets/otel.conf;`, а в `snippets/otel.conf`
   укажите адрес своего коллектора (`otel_exporter { endpoint …:4317; }`,
   OTLP/gRPC) и `otel_service_name`.
4. `make reload`: проверка конфигурации и применение без остановки.

В `snippets/otel.conf` заданы `otel_trace on` (все запросы; долю можно
задать переменной, например через `split_clients`) и
`otel_trace_context propagate`. При `otel_trace on` решение родителя о
семплировании не учитывается: дальше уходит флаг `01`, даже если клиент
прислал `00`. Чтобы следовать решению родителя, используйте
`otel_trace $otel_parent_sampled;`. Что меняется (проверено на
`nginx:1.30.5-otel`; клиент не прислал ни `X-Request-ID`, ни `traceparent`):

```bash
curl -s -D - http://localhost/api/demo | grep -iE '^(x-request-id|traceparent):'
```

```text
X-Request-ID: 86706952d2dbb6c9dfc6338d4ba1e674                          ← ответ шлюза
Traceparent: 00-86706952d2dbb6c9dfc6338d4ba1e674-88ff0fb7e1d158e4-01   ← бэкенд получил span шлюза
X-Request-Id: 86706952d2dbb6c9dfc6338d4ba1e674
```

- Шлюз передаёт бэкенду **свой** `traceparent`: parent-id в нём — span
  шлюза. Если клиент прислал `traceparent`, трасса продолжается: trace-id и
  решение родителя о семплировании сохраняются. Например, на входящий
  `00-4bf92f35…-00f067aa0ba902b7-01` бэкенд получает
  `00-4bf92f35…-<span шлюза>-01` и `X-Request-ID: 4bf92f35…`.
- Если `traceparent` не пришёл, модуль начинает новую трассу с trace-id,
  равным `$request_id` шлюза. Тот же `$request_id` шлюз ставит в
  `X-Request-ID`, когда клиент своего не прислал, поэтому в логах, в APM и в
  ответе один и тот же ID.
- Если клиент прислал свой `X-Request-ID` без `traceparent`, ID разные:
  `X-Request-ID` остаётся клиентским, а trace-id у OTel новый. Свяжите их,
  добавив `$otel_trace_id` в JSON-лог (готовая строка — в комментарии
  `snippets/otel.conf`), или ставьте в клиентах с OTel SDK `X-Request-ID`
  равным trace-id (рекомендация выше).
- `X-Request-ID`, цепочка hop'ов и JSON-лог работают как раньше.
- Если коллектор недоступен, запросы обслуживаются, а в `error_log`
  появляются строки `OTel export failure`.

## 6. Backend

Все примеры реализуют одно и то же ([2.7](#27-что-делает-каждый-узел)):
проверка входящих значений, новый `local_request_id`, цепочка с обрезкой,
контекст запроса, поля в логах и заголовки исходящих запросов. Имена полей в
логах совпадают с объектом `trace` JSON-лога шлюза: `hop_name`,
`trace_request_id`, `local_request_id`, `prev_request_id`, `hops_chain`,
`mobile_launch_id`, `mobile_request_id`.

Ни один пример не выставляет заголовки трассировки в ответе: это делает шлюз
([2.7](#27-что-делает-каждый-узел)).

### 6.1. PHP: общий класс TraceContext

PHP 8.1+ (проверено на 8.4). Класс не зависит от фреймворка и используется
во всех PHP-примерах ниже.

```php
<?php

declare(strict_types=1);

namespace App\Trace;

/** Идентификаторы трассировки одного hop'а (запроса, задачи из очереди). */
final class TraceContext
{
    private const ID = '/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/D';
    private const ELEMENT = '/^[A-Za-z0-9._-]{1,64}:[A-Za-z0-9._:-]{1,128}$/D';
    private const MAX_CHAIN = 16;

    private static ?self $current = null;

    public function __construct(
        public readonly string $hopName,
        public readonly string $traceRequestId,
        public readonly string $localRequestId,
        public readonly string $prevRequestId,
        public readonly string $hopsChain,
        public readonly string $mobileLaunchId,
        public readonly string $mobileRequestId,
    ) {}

    /** @param callable(string): string $header значение заголовка по имени, '' — если его нет */
    public static function fromHeaders(callable $header, string $hopName): self
    {
        $local = self::newId();

        return new self(
            hopName: $hopName,
            traceRequestId: self::valid($header('X-Request-ID')) ?? self::newId(),
            localRequestId: $local,
            prevRequestId: self::valid($header('X-Prev-Request-ID')) ?? '',
            hopsChain: self::appendHop($header('X-Request-Chain'), "{$hopName}:{$local}"),
            mobileLaunchId: self::valid($header('X-Mobile-Launch-ID')) ?? '',
            mobileRequestId: self::valid($header('X-Mobile-Request-ID')) ?? '',
        );
    }

    /** Заголовки исходящего запроса (или сообщения в очередь); пустые не отправляются. */
    public function outgoingHeaders(): array
    {
        return array_filter([
            'X-Request-ID'        => $this->traceRequestId,
            'X-Prev-Request-ID'   => $this->localRequestId,   // вниз по цепочке «предыдущий» — это мы
            'X-Request-Chain'     => $this->hopsChain,
            'X-HOP-Name'          => $this->hopName,
            'X-Mobile-Launch-ID'  => $this->mobileLaunchId,
            'X-Mobile-Request-ID' => $this->mobileRequestId,
        ], static fn (string $value): bool => $value !== '');
    }

    /** Поля для логов — те же имена, что в объекте trace JSON-лога шлюза. */
    public function toLogContext(): array
    {
        return [
            'hop_name'          => $this->hopName,
            'trace_request_id'  => $this->traceRequestId,
            'local_request_id'  => $this->localRequestId,
            'prev_request_id'   => $this->prevRequestId,
            'hops_chain'        => $this->hopsChain,
            'mobile_launch_id'  => $this->mobileLaunchId,
            'mobile_request_id' => $this->mobileRequestId,
        ];
    }

    public static function newId(): string
    {
        return bin2hex(random_bytes(16));   // 32 hex, как $request_id в nginx
    }

    /** Та же обрезка, что в nginx: до 16 элементов, иначе «~» и 15 последних корректных. */
    public static function appendHop(string $chain, string $hop): string
    {
        $items = $chain === '' ? [] : preg_split('/, ?/', $chain);
        $isValid = static fn (string $item): bool => preg_match(self::ELEMENT, $item) === 1;

        if (count($items) > self::MAX_CHAIN || count(array_filter($items, $isValid)) !== count($items)) {
            $tail = [];
            foreach (array_reverse($items) as $item) {
                if (count($tail) === self::MAX_CHAIN - 1 || !$isValid($item)) {
                    break;
                }
                array_unshift($tail, $item);
            }
            $items = ['~', ...$tail];
        }

        return implode(', ', [...$items, $hop]);
    }

    public static function current(): ?self
    {
        return self::$current;
    }

    public static function setCurrent(?self $trace): void
    {
        self::$current = $trace;
    }

    private static function valid(string $value): ?string
    {
        return preg_match(self::ID, $value) === 1 ? $value : null;
    }
}
```

Текущий контекст хранится в статическом свойстве. В PHP-FPM один процесс
обслуживает один запрос за раз, в RoadRunner и FrankenPHP (worker mode)
middleware сбрасывает значение после запроса. В Swoole/OpenSwoole, где в
одном процессе параллельно выполняются несколько запросов, храните контекст в
контексте корутины.

### 6.2. PHP: PSR-15, Monolog, Guzzle

Middleware PSR-15 (Slim, Mezzio и любой диспетчер PSR-15; PSR-7 — например,
`nyholm/psr7`):

```php
<?php

declare(strict_types=1);

namespace App\Http\Middleware;

use App\Trace\TraceContext;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;

final class TraceMiddleware implements MiddlewareInterface
{
    public function __construct(private readonly string $hopName = 'backend-php') {}

    public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
    {
        $trace = TraceContext::fromHeaders($request->getHeaderLine(...), $this->hopName);
        TraceContext::setCurrent($trace);

        try {
            return $handler->handle($request->withAttribute(TraceContext::class, $trace));
        } finally {
            TraceContext::setCurrent(null);   // важно для долгоживущих воркеров (RoadRunner, FrankenPHP)
        }
    }
}
```

Поля в каждой записи Monolog 3:

```php
use App\Trace\TraceContext;
use Monolog\LogRecord;

$logger->pushProcessor(static fn (LogRecord $record): LogRecord => $record->with(
    extra: $record->extra + (TraceContext::current()?->toLogContext() ?? []),
));
```

Guzzle 7: заголовки берутся в момент отправки, поэтому клиент можно
держать общим сервисом в DI-контейнере. Если в конфигурации клиента уже есть
свой `handler`, добавьте middleware в его стек, а не создавайте новый.

```php
use App\Trace\TraceContext;
use GuzzleHttp\Client;
use GuzzleHttp\HandlerStack;
use GuzzleHttp\Middleware;
use Psr\Http\Message\RequestInterface;

$stack = HandlerStack::create();
$stack->push(Middleware::mapRequest(static function (RequestInterface $request): RequestInterface {
    foreach (TraceContext::current()?->outgoingHeaders() ?? [] as $name => $value) {
        $request = $request->withHeader($name, $value);
    }
    return $request;
}), 'trace');

$http = new Client(['handler' => $stack, 'base_uri' => 'http://billing:8080']);
```

### 6.3. Laravel 11/12

Проверено на Laravel 12. Класс `TraceContext` — `app/Trace/TraceContext.php`
из [6.1](#61-php-общий-класс-tracecontext).

`config/app.php` — имя узла через конфиг (после `php artisan config:cache`
файл `.env` не читается, и `env()` вне файлов конфигурации видит только
системные переменные окружения):

```php
'hop_name' => env('HOP_NAME', 'backend-laravel'),
```

`app/Http/Middleware/TraceMiddleware.php`:

```php
<?php

declare(strict_types=1);

namespace App\Http\Middleware;

use App\Trace\TraceContext;
use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Context;
use Symfony\Component\HttpFoundation\Response;

final class TraceMiddleware
{
    public function handle(Request $request, Closure $next): Response
    {
        $trace = TraceContext::fromHeaders(
            fn (string $name): string => implode(', ', $request->headers->all($name)),
            config('app.hop_name'),
        );
        TraceContext::setCurrent($trace);
        Context::add($trace->toLogContext());   // → в каждую строку лога и в задачи очереди

        return $next($request);
    }
}
```

`bootstrap/app.php` — глобальный middleware (в Laravel 11+ файла
`app/Http/Kernel.php` нет):

```php
->withMiddleware(function (Middleware $middleware): void {
    $middleware->prepend(\App\Http\Middleware\TraceMiddleware::class);
})
```

`app/Providers/AppServiceProvider.php` — исходящие запросы и очереди:

```php
use App\Trace\TraceContext;
use Illuminate\Log\Context\Repository;
use Illuminate\Support\Facades\Context;
use Illuminate\Support\Facades\Http;
use Psr\Http\Message\RequestInterface;

public function boot(): void
{
    // Все исходящие запросы через Http::… получают заголовки трассировки.
    Http::globalRequestMiddleware(function (RequestInterface $request): RequestInterface {
        foreach (TraceContext::current()?->outgoingHeaders() ?? [] as $name => $value) {
            $request = $request->withHeader($name, $value);
        }
        return $request;
    });

    // Точечный вариант вместо глобального: Http::traced()->get(...).
    Http::macro('traced', fn () => Http::withHeaders(TraceContext::current()?->outgoingHeaders() ?? []));

    // Постановка задачи в очередь: заголовки текущего hop'а едут вместе с задачей.
    Context::dehydrating(function (Repository $context): void {
        $context->addHidden('trace_headers', TraceContext::current()?->outgoingHeaders() ?? []);
    });

    // Выполнение задачи: воркер — следующий hop той же трассировки.
    Context::hydrated(function (Repository $context): void {
        $headers = $context->getHidden('trace_headers') ?? [];
        $trace = TraceContext::fromHeaders(
            fn (string $name): string => $headers[$name] ?? '',
            config('app.hop_name') . '-queue',
        );
        TraceContext::setCurrent($trace);
        $context->add($trace->toLogContext());
    });
}
```

Что получается:

- каждая строка лога содержит поля трассировки (Context добавляет их как
  метаданные записи);
- `Http::get(...)` отправляет `X-Request-ID`, `X-Prev-Request-ID` (свой
  `local_request_id`), цепочку и мобильные ID;
- задача из очереди выполняется как отдельный hop `backend-laravel-queue` с
  той же трассировкой: `prev_request_id` = `local_request_id` запроса, который
  её поставил. Задача без трассировки (например, из планировщика) получает
  новый trace ID.

### 6.4. Yii2

Класс `TraceContext` из [6.1](#61-php-общий-класс-tracecontext)
подключается автозагрузкой Composer. Компонент-bootstrap:

```php
<?php

declare(strict_types=1);

namespace app\components;

use App\Trace\TraceContext;
use yii\base\BootstrapInterface;
use yii\base\Component;
use yii\web\Application as WebApplication;

final class TraceBootstrap extends Component implements BootstrapInterface
{
    public string $hopName = 'backend-yii';

    public function bootstrap($app): void
    {
        if ($app instanceof WebApplication) {
            $headers = $app->getRequest()->getHeaders();
            TraceContext::setCurrent(TraceContext::fromHeaders(
                fn (string $name): string => implode(', ', $headers->get($name, [], false)),
                $this->hopName,
            ));
        }
    }
}
```

`config/web.php` — лог и исходящие запросы через `yii2-httpclient`:

```php
use App\Trace\TraceContext;

return [
    // trace — до log, чтобы ранние записи лога уже имели ID
    'bootstrap' => ['trace', 'log'],
    'components' => [
        'trace' => [
            'class' => app\components\TraceBootstrap::class,
            'hopName' => 'backend-yii',
        ],
        'log' => [
            'targets' => [[
                'class' => yii\log\FileTarget::class,
                'levels' => ['error', 'warning', 'info'],
                // [trace_request_id][local_request_id] в начале каждой строки
                'prefix' => function (): string {
                    $t = TraceContext::current();
                    return $t ? "[{$t->traceRequestId}][{$t->localRequestId}]" : '[-][-]';
                },
            ]],
        ],
        'httpClient' => [
            'class' => yii\httpclient\Client::class,
            'on beforeSend' => function (yii\httpclient\RequestEvent $event): void {
                $event->request->addHeaders(TraceContext::current()?->outgoingHeaders() ?? []);
            },
        ],
        // ...
    ],
];
```

Использование: `Yii::$app->httpClient->get('http://billing:8080/api/invoices')->send()`.

### 6.5. Node.js: Express и Fastify

Node.js 20+, ESM. Контекст запроса хранится в `AsyncLocalStorage` и
доступен в любом месте обработки запроса, в том числе после `await`.

`trace.mjs`:

```js
import { AsyncLocalStorage } from 'node:async_hooks';
import { randomBytes } from 'node:crypto';

const ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const ELEMENT = /^[A-Za-z0-9._-]{1,64}:[A-Za-z0-9._:-]{1,128}$/;
const MAX_CHAIN = 16;

export const newId = () => randomBytes(16).toString('hex');
const valid = (value) => (typeof value === 'string' && ID.test(value) ? value : '');

export function appendHop(chain, hop) {
  let items = chain ? chain.split(/, ?/) : [];
  if (items.length > MAX_CHAIN || !items.every((item) => ELEMENT.test(item))) {
    const tail = [];
    for (const item of items.toReversed()) {
      if (tail.length === MAX_CHAIN - 1 || !ELEMENT.test(item)) break;
      tail.unshift(item);
    }
    items = ['~', ...tail];
  }
  return [...items, hop].join(', ');
}

// get(name) — значение заголовка по имени в нижнем регистре или undefined.
export function fromHeaders(get, hopName) {
  const localRequestId = newId();
  return {
    hopName,
    traceRequestId: valid(get('x-request-id')) || newId(),
    localRequestId,
    prevRequestId: valid(get('x-prev-request-id')),
    hopsChain: appendHop(get('x-request-chain') ?? '', `${hopName}:${localRequestId}`),
    mobileLaunchId: valid(get('x-mobile-launch-id')),
    mobileRequestId: valid(get('x-mobile-request-id')),
  };
}

export function outgoingHeaders(t) {
  const headers = {
    'X-Request-ID': t.traceRequestId,
    'X-Prev-Request-ID': t.localRequestId, // вниз по цепочке «предыдущий» — это мы
    'X-Request-Chain': t.hopsChain,
    'X-HOP-Name': t.hopName,
    'X-Mobile-Launch-ID': t.mobileLaunchId,
    'X-Mobile-Request-ID': t.mobileRequestId,
  };
  return Object.fromEntries(Object.entries(headers).filter(([, value]) => value));
}

// Поля для логов — те же имена, что в объекте trace JSON-лога шлюза.
export const logFields = (t) => ({
  hop_name: t.hopName,
  trace_request_id: t.traceRequestId,
  local_request_id: t.localRequestId,
  prev_request_id: t.prevRequestId,
  hops_chain: t.hopsChain,
  mobile_launch_id: t.mobileLaunchId,
  mobile_request_id: t.mobileRequestId,
});

export const traceStorage = new AsyncLocalStorage();
export const currentTrace = () => traceStorage.getStore();

// fetch, который сам добавляет заголовки текущего запроса.
export function tracedFetch(input, init = {}) {
  const headers = new Headers(init.headers);
  const t = currentTrace();
  if (t) for (const [name, value] of Object.entries(outgoingHeaders(t))) headers.set(name, value);
  return fetch(input, { ...init, headers });
}
```

Express 5 и логгер pino:

```js
import express from 'express';
import pino from 'pino';
import { currentTrace, fromHeaders, logFields, traceStorage, tracedFetch } from './trace.mjs';

const HOP_NAME = process.env.HOP_NAME ?? 'backend-orders';
const log = pino({ mixin: () => (currentTrace() ? logFields(currentTrace()) : {}) });

const app = express();
app.use((req, res, next) => traceStorage.run(fromHeaders((name) => req.get(name), HOP_NAME), next));

app.post('/api/orders', express.json(), async (req, res) => {
  log.info('create order');   // строка лога с trace_request_id, local_request_id, …
  const billing = await tracedFetch('http://billing:8080/api/invoices', { method: 'POST' });
  res.status(billing.ok ? 201 : 502).end();
});

app.listen(8080);
```

Fastify 5 — тот же модуль, контекст задаётся в хуке `onRequest`:

```js
fastify.addHook('onRequest', (req, reply, done) => {
  traceStorage.run(fromHeaders((name) => req.headers[name], HOP_NAME), done);
});
```

Повторённый заголовок Node.js склеивает через `, `, и такое значение не
проходит проверку — как на шлюзе.

### 6.6. Python: FastAPI / Starlette и httpx

Python 3.10+. Контекст — `contextvars`, он корректно работает с `async`.

`tracing.py` (не называйте модуль `trace.py`: так называется модуль
стандартной библиотеки):

```python
import dataclasses
import re
import secrets
from collections.abc import Callable
from contextvars import ContextVar

ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
ELEMENT = re.compile(r"[A-Za-z0-9._-]{1,64}:[A-Za-z0-9._:-]{1,128}")
MAX_CHAIN = 16


def new_id() -> str:
    return secrets.token_hex(16)  # 32 hex


def _valid(value: str | None) -> str:
    return value if value and ID.fullmatch(value) else ""


def append_hop(chain: str, hop: str) -> str:
    items = re.split(r", ?", chain) if chain else []
    if len(items) > MAX_CHAIN or not all(ELEMENT.fullmatch(item) for item in items):
        tail: list[str] = []
        for item in reversed(items):
            if len(tail) == MAX_CHAIN - 1 or not ELEMENT.fullmatch(item):
                break
            tail.insert(0, item)
        items = ["~", *tail]
    return ", ".join([*items, hop])


@dataclasses.dataclass(frozen=True, slots=True)
class Trace:
    # Имена полей = имена полей trace.* в JSON-логе шлюза.
    hop_name: str
    trace_request_id: str
    local_request_id: str
    prev_request_id: str
    hops_chain: str
    mobile_launch_id: str
    mobile_request_id: str

    @classmethod
    def from_headers(cls, get: Callable[[str], str | None], hop_name: str) -> "Trace":
        local = new_id()
        return cls(
            hop_name=hop_name,
            trace_request_id=_valid(get("x-request-id")) or new_id(),
            local_request_id=local,
            prev_request_id=_valid(get("x-prev-request-id")),
            hops_chain=append_hop(get("x-request-chain") or "", f"{hop_name}:{local}"),
            mobile_launch_id=_valid(get("x-mobile-launch-id")),
            mobile_request_id=_valid(get("x-mobile-request-id")),
        )

    def outgoing_headers(self) -> dict[str, str]:
        headers = {
            "X-Request-ID": self.trace_request_id,
            "X-Prev-Request-ID": self.local_request_id,  # вниз по цепочке «предыдущий» — это мы
            "X-Request-Chain": self.hops_chain,
            "X-HOP-Name": self.hop_name,
            "X-Mobile-Launch-ID": self.mobile_launch_id,
            "X-Mobile-Request-ID": self.mobile_request_id,
        }
        return {name: value for name, value in headers.items() if value}

    def log_fields(self) -> dict[str, str]:
        return dataclasses.asdict(self)


current_trace: ContextVar[Trace | None] = ContextVar("current_trace", default=None)
```

Приложение:

```python
import logging
import os

import httpx
from fastapi import FastAPI, Request

from tracing import Trace, current_trace

HOP_NAME = os.getenv("HOP_NAME", "backend-python")
app = FastAPI()


@app.middleware("http")
async def trace_middleware(request: Request, call_next):
    # Повторённый заголовок → «a, b» → не проходит проверку, как на шлюзе.
    trace = Trace.from_headers(lambda name: ", ".join(request.headers.getlist(name)), HOP_NAME)
    token = current_trace.set(trace)
    try:
        return await call_next(request)
    finally:
        current_trace.reset(token)


async def add_trace_headers(request: httpx.Request) -> None:
    if (trace := current_trace.get()) is not None:
        request.headers.update(trace.outgoing_headers())


# Один клиент на приложение; заголовки добавляются при каждой отправке.
http = httpx.AsyncClient(event_hooks={"request": [add_trace_headers]})


class TraceLogFilter(logging.Filter):
    """Добавляет ID в каждую запись лога."""

    def filter(self, record: logging.LogRecord) -> bool:
        trace = current_trace.get()
        record.trace_request_id = trace.trace_request_id if trace else "-"
        record.local_request_id = trace.local_request_id if trace else "-"
        return True


handler = logging.StreamHandler()
handler.addFilter(TraceLogFilter())
handler.setFormatter(logging.Formatter("%(levelname)s [%(trace_request_id)s %(local_request_id)s] %(message)s"))
logging.getLogger().addHandler(handler)
```

Для JSON-логов добавляйте в запись всё из `trace.log_fields()`. Django и
Flask за uWSGI получают значения шлюза в `request.META["HTTP_X_REQUEST_ID"]`
и т. д.; middleware строится так же, через `Trace.from_headers`.

### 6.7. Go: net/http

Go 1.24+ (только стандартная библиотека).

```go
// Package tracing — трассировка для net/http.
package tracing

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"regexp"
	"slices"
	"strings"
)

var (
	idRe      = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)
	elementRe = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}:[A-Za-z0-9._:-]{1,128}$`)
	sepRe     = regexp.MustCompile(`, ?`)
)

const maxChain = 16

type Trace struct {
	HopName, TraceRequestID, LocalRequestID, PrevRequestID string
	HopsChain, MobileLaunchID, MobileRequestID             string
}

func NewID() string {
	b := make([]byte, 16)
	rand.Read(b) // с Go 1.24 не возвращает ошибку
	return hex.EncodeToString(b)
}

func valid(v string) string {
	if idRe.MatchString(v) {
		return v
	}
	return ""
}

func AppendHop(chain, hop string) string {
	var items []string
	if chain != "" {
		items = sepRe.Split(chain, -1)
	}
	if len(items) > maxChain || slices.ContainsFunc(items, func(s string) bool { return !elementRe.MatchString(s) }) {
		var tail []string
		for i := len(items) - 1; i >= 0 && len(tail) < maxChain-1 && elementRe.MatchString(items[i]); i-- {
			tail = append([]string{items[i]}, tail...)
		}
		items = append([]string{"~"}, tail...)
	}
	return strings.Join(append(items, hop), ", ")
}

// FromHeaders: повторённый заголовок склеивается через ", " и не проходит проверку — как в nginx.
func FromHeaders(h http.Header, hopName string) Trace {
	get := func(name string) string { return strings.Join(h.Values(name), ", ") }
	local := NewID()
	trace := valid(get("X-Request-ID"))
	if trace == "" {
		trace = NewID()
	}
	return Trace{
		HopName:         hopName,
		TraceRequestID:  trace,
		LocalRequestID:  local,
		PrevRequestID:   valid(get("X-Prev-Request-ID")),
		HopsChain:       AppendHop(get("X-Request-Chain"), hopName+":"+local),
		MobileLaunchID:  valid(get("X-Mobile-Launch-ID")),
		MobileRequestID: valid(get("X-Mobile-Request-ID")),
	}
}

func (t Trace) OutgoingHeaders() map[string]string {
	h := map[string]string{
		"X-Request-ID":        t.TraceRequestID,
		"X-Prev-Request-ID":   t.LocalRequestID, // вниз по цепочке «предыдущий» — это мы
		"X-Request-Chain":     t.HopsChain,
		"X-HOP-Name":          t.HopName,
		"X-Mobile-Launch-ID":  t.MobileLaunchID,
		"X-Mobile-Request-ID": t.MobileRequestID,
	}
	for k, v := range h {
		if v == "" {
			delete(h, k)
		}
	}
	return h
}

// LogAttrs — поля для slog с теми же именами, что в JSON-логе шлюза.
func (t Trace) LogAttrs() []any {
	return []any{
		"hop_name", t.HopName, "trace_request_id", t.TraceRequestID,
		"local_request_id", t.LocalRequestID, "prev_request_id", t.PrevRequestID,
		"hops_chain", t.HopsChain, "mobile_launch_id", t.MobileLaunchID,
		"mobile_request_id", t.MobileRequestID,
	}
}

type ctxKey struct{}

func FromContext(ctx context.Context) (Trace, bool) {
	t, ok := ctx.Value(ctxKey{}).(Trace)
	return t, ok
}

// Middleware кладёт Trace в context запроса.
func Middleware(hopName string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx := context.WithValue(r.Context(), ctxKey{}, FromHeaders(r.Header, hopName))
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// Transport добавляет заголовки к исходящим запросам, созданным с контекстом входящего.
type Transport struct{ Base http.RoundTripper }

func (tr Transport) RoundTrip(req *http.Request) (*http.Response, error) {
	if t, ok := FromContext(req.Context()); ok {
		req = req.Clone(req.Context()) // RoundTripper не должен менять исходный запрос
		for k, v := range t.OutgoingHeaders() {
			req.Header.Set(k, v)
		}
	}
	base := tr.Base
	if base == nil {
		base = http.DefaultTransport
	}
	return base.RoundTrip(req)
}
```

Использование: исходящий запрос обязательно создаётся с контекстом входящего
(`http.NewRequestWithContext(r.Context(), …)`), иначе `Transport` не найдёт
трассировку.

```go
var client = &http.Client{Transport: tracing.Transport{}}

func createOrder(w http.ResponseWriter, r *http.Request) {
	t, _ := tracing.FromContext(r.Context())
	slog.InfoContext(r.Context(), "create order", t.LogAttrs()...)

	req, _ := http.NewRequestWithContext(r.Context(), http.MethodPost, "http://billing:8080/api/invoices", nil)
	resp, err := client.Do(req)
	if err != nil {
		http.Error(w, "billing unavailable", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	w.WriteHeader(http.StatusCreated)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/orders", createOrder)
	http.ListenAndServe(":8080", tracing.Middleware("backend-go", mux))
}
```

### 6.8. Java: Spring Boot

Java 21, Spring Boot 3.2+ и 4.x (проверено на 3.5 и 4.1). Контекст хранится
в атрибуте запроса и в MDC (SLF4J).

```java
package com.example.trace;

import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.regex.Pattern;

/** Идентификаторы трассировки одного hop'а. */
public record Trace(String hopName, String traceRequestId, String localRequestId, String prevRequestId,
                    String hopsChain, String mobileLaunchId, String mobileRequestId) {

    private static final Pattern ID = Pattern.compile("[A-Za-z0-9][A-Za-z0-9._:-]{0,127}");
    private static final Pattern ELEMENT = Pattern.compile("[A-Za-z0-9._-]{1,64}:[A-Za-z0-9._:-]{1,128}");
    private static final int MAX_CHAIN = 16;
    private static final SecureRandom RANDOM = new SecureRandom();

    public static String newId() {
        byte[] bytes = new byte[16];
        RANDOM.nextBytes(bytes);
        return HexFormat.of().formatHex(bytes);   // 32 hex
    }

    private static String valid(String value) {
        return value != null && ID.matcher(value).matches() ? value : "";
    }

    public static String appendHop(String chain, String hop) {
        List<String> items = chain == null || chain.isEmpty()
                ? new ArrayList<>() : new ArrayList<>(Arrays.asList(chain.split(", ?", -1)));
        if (items.size() > MAX_CHAIN || !items.stream().allMatch(i -> ELEMENT.matcher(i).matches())) {
            List<String> tail = new ArrayList<>();
            for (int i = items.size() - 1;
                 i >= 0 && tail.size() < MAX_CHAIN - 1 && ELEMENT.matcher(items.get(i)).matches(); i--) {
                tail.addFirst(items.get(i));
            }
            items = new ArrayList<>(List.of("~"));
            items.addAll(tail);
        }
        items.add(hop);
        return String.join(", ", items);
    }

    /** header — значение заголовка по имени ("" или null, если его нет). */
    public static Trace fromHeaders(Function<String, String> header, String hopName) {
        String local = newId();
        String trace = valid(header.apply("X-Request-ID"));
        return new Trace(hopName, trace.isEmpty() ? newId() : trace, local,
                valid(header.apply("X-Prev-Request-ID")),
                appendHop(header.apply("X-Request-Chain"), hopName + ":" + local),
                valid(header.apply("X-Mobile-Launch-ID")),
                valid(header.apply("X-Mobile-Request-ID")));
    }

    public Map<String, String> outgoingHeaders() {
        Map<String, String> h = new LinkedHashMap<>();
        h.put("X-Request-ID", traceRequestId);
        h.put("X-Prev-Request-ID", localRequestId);   // вниз по цепочке «предыдущий» — это мы
        h.put("X-Request-Chain", hopsChain);
        h.put("X-HOP-Name", hopName);
        h.put("X-Mobile-Launch-ID", mobileLaunchId);
        h.put("X-Mobile-Request-ID", mobileRequestId);
        h.values().removeIf(String::isEmpty);
        return h;
    }

    /** Поля для MDC — те же имена, что в JSON-логе шлюза. */
    public Map<String, String> logFields() {
        return Map.of("hop_name", hopName, "trace_request_id", traceRequestId,
                "local_request_id", localRequestId, "prev_request_id", prevRequestId,
                "hops_chain", hopsChain, "mobile_launch_id", mobileLaunchId,
                "mobile_request_id", mobileRequestId);
    }
}
```

Фильтр:

```java
package com.example.trace;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Collections;
import org.slf4j.MDC;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class TraceFilter extends OncePerRequestFilter {

    private final String hopName;

    public TraceFilter(@Value("${app.hop-name:backend-java}") String hopName) {
        this.hopName = hopName;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        // Повторённый заголовок склеивается через ", " и не проходит проверку — как в nginx.
        Trace trace = Trace.fromHeaders(
                name -> String.join(", ", Collections.list(request.getHeaders(name))), hopName);
        request.setAttribute(Trace.class.getName(), trace);
        trace.logFields().forEach(MDC::put);
        try {
            chain.doFilter(request, response);
        } finally {
            trace.logFields().keySet().forEach(MDC::remove);
        }
    }
}
```

`RestClient` с interceptor'ом (в Spring Boot 4 бин `RestClient.Builder` даёт
стартер `spring-boot-starter-restclient`):

```java
package com.example.trace;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.client.RestClient;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

@Configuration
public class TraceClientConfig {

    @Bean
    RestClient restClient(RestClient.Builder builder) {
        return builder
                .requestInterceptor((request, body, execution) -> {
                    if (RequestContextHolder.getRequestAttributes() instanceof ServletRequestAttributes attrs
                            && attrs.getRequest().getAttribute(Trace.class.getName()) instanceof Trace trace) {
                        trace.outgoingHeaders().forEach(request.getHeaders()::set);
                    }
                    return execution.execute(request, body);
                })
                .build();
    }
}
```

Лог — `application.properties`:

```properties
app.hop-name=backend-orders
logging.pattern.level=%5p [%X{trace_request_id:-} %X{local_request_id:-}]
```

Со structured logging (Spring Boot 3.4+, `logging.structured.format.console=ecs`
или `logstash`) поля MDC попадают в JSON автоматически. MDC привязан к
потоку: для `@Async` и собственных пулов потоков переносите его через
`TaskDecorator`. `RequestContextHolder` в другом потоке тоже пуст, поэтому
при вызове `RestClient` из фонового потока передавайте `Trace` явно.

## 7. Очереди и фоновые задачи

Сообщение в очереди — такой же вызов, как HTTP-запрос: продюсер кладёт в
заголовки (metadata) сообщения те же поля, что и в исходящий HTTP-запрос, а
консьюмер обрабатывает их тем же `fromHeaders`, что и middleware.

| Заголовок сообщения | Значение у продюсера |
|---|---|
| `X-Request-ID` | `trace_request_id` |
| `X-Prev-Request-ID` | `local_request_id` продюсера |
| `X-Request-Chain` | `hops_chain` продюсера |
| `X-HOP-Name` | `hop_name` продюсера |
| `X-Mobile-Launch-ID`, `X-Mobile-Request-ID` | если есть |
| `traceparent`, `tracestate` | если используется OpenTelemetry |

- Используйте те же имена, что в HTTP. В Kafka имена заголовков
  чувствительны к регистру, а значения — байты (UTF-8).
- Консьюмер — отдельный hop со своим `hop_name` (`backend-orders-queue`,
  `worker-emails`). На каждую обработку, в том числе повторную, создаётся
  новый `local_request_id`. Trace ID остаётся прежним.
- Задача без входящей трассировки (cron, планировщик) начинает новую: пустые
  заголовки дают новый trace ID и цепочку из одного элемента.

Laravel делает это автоматически ([6.3](#63-laravel-1112)). Пример для
любого брокера на Python (модуль `tracing` из [6.6](#66-python-fastapi--starlette-и-httpx)):

```python
from tracing import Trace, current_trace


# Продюсер: внутри обработки HTTP-запроса.
def publish_order_created(broker, order_id: int) -> None:
    trace = current_trace.get()
    headers = trace.outgoing_headers() if trace else {}
    broker.publish("orders.created", body={"order_id": order_id}, headers=headers)


# Консьюмер: каждое сообщение — новый hop.
def handle_message(message) -> None:
    headers = {name.lower(): value for name, value in (message.headers or {}).items()}
    token = current_trace.set(Trace.from_headers(headers.get, "worker-emails"))
    try:
        ...  # обработка; логи и исходящие запросы получают трассировку
    finally:
        current_trace.reset(token)
```

`broker.publish` и `message.headers` замените на API своего клиента
(aio-pika, confluent-kafka, SQS и т. д.). Для Kafka значения заголовков нужно
кодировать и декодировать (`value.encode()` / `value.decode()`).

## 8. Frontend (браузер)

Браузер — первый узел: он создаёт trace ID действия и свой локальный ID
каждого запроса, `hop_name` — `frontend-web`.

```ts
// api.ts — fetch с заголовками трассировки
const HOP_NAME = 'frontend-web';

export function newId(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * traceId — ID пользовательского действия. По умолчанию новый на каждый вызов;
 * чтобы связать несколько запросов одного действия, передайте один и тот же.
 */
export async function tracedFetch(
  input: RequestInfo | URL,
  init: RequestInit = {},
  traceId: string = newId(),
): Promise<Response> {
  const localId = newId(); // ID этого запроса на стороне браузера
  const headers = new Headers(init.headers);
  headers.set('X-Request-ID', traceId);
  headers.set('X-Prev-Request-ID', localId);
  headers.set('X-Request-Chain', `${HOP_NAME}:${localId}`);
  // Ошибки самого шлюза (429, 502, 504 …) придут в JSON с request_id под любым путём.
  if (!headers.has('Accept')) headers.set('Accept', 'application/json');

  const response = await fetch(input, { ...init, headers });
  if (!response.ok) {
    // Шлюз мог заменить невалидный ID — берём тот, что он вернул.
    const requestId = response.headers.get('X-Request-ID') ?? traceId;
    console.warn(`API ${response.status}, request_id=${requestId}`);
  }
  return response;
}
```

Одно действие — несколько запросов:

```ts
const action = newId();
const [cart, prices] = await Promise.all([
  tracedFetch('/api/cart', {}, action),
  tracedFetch('/api/prices', {}, action),
]);
```

`crypto.getRandomValues` работает во всех браузерах и в любом контексте;
`crypto.randomUUID()` доступен только в защищённом контексте (HTTPS или
localhost).

Что браузер получает в ответе от шлюза: `X-Request-ID` (всегда) и больше
ничего из трассировки. `X-Request-Chain`, `X-HOP-Name` и эхо
`X-Prev-Request-ID` шлюз показывает только loopback-клиентам
([раздел 3](#3-граница-доверия)). Hop браузера `frontend-web:<local>`
попадает в цепочку, которую получает бэкенд, и в лог шлюза, пока на шлюзе
`$trace_accept_client_hops` = 1 (по умолчанию).

`Accept: application/json` в примере выше выбирает формат ошибок шлюза
([раздел 4](#4-шлюз-где-что-в-репозитории)): вместо HTML-страницы придёт
`application/problem+json` с полем `request_id`. Для путей `/api/…` JSON
приходит и без него. `Accept` со значением `application/json` не требует
CORS-preflight.

### CORS

Если фронтенд и API на одном origin (SPA отдаётся тем же шлюзом), CORS не
нужен. Для API на другом origin:

- Любой нестандартный заголовок, в том числе `X-Request-ID`, заставляет
  браузер отправить preflight-запрос `OPTIONS`. Шлюз пропускает `OPTIONS` в
  `location ^~ /api/` к бэкенду: CORS настраивает **бэкенд** (см. комментарий в
  `sites-available/default/app_locations.conf`).
- Ответ на preflight должен разрешать заголовки трассировки, а обычные ответы —
  открывать `X-Request-ID` для JavaScript. Без `Access-Control-Expose-Headers`
  вызов `response.headers.get('X-Request-ID')` вернёт `null`.

```http
HTTP/1.1 204 No Content
Access-Control-Allow-Origin: https://app.example.com
Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE
Access-Control-Allow-Headers: Content-Type, Authorization, X-Request-ID, X-Prev-Request-ID, X-Request-Chain, X-Mobile-Launch-ID, X-Mobile-Request-ID, traceparent, tracestate
Access-Control-Max-Age: 600
Vary: Origin
```

```http
Access-Control-Allow-Origin: https://app.example.com
Access-Control-Expose-Headers: X-Request-ID
Vary: Origin
```

- Laravel, `config/cors.php`: `'allowed_headers'` — список выше,
  `'exposed_headers' => ['X-Request-ID']`, `'max_age' => 600`.
- Express, пакет `cors`: `cors({ origin, allowedHeaders, exposedHeaders: ['X-Request-ID'], maxAge: 600 })`.
- FastAPI: `CORSMiddleware(..., allow_headers=[...], expose_headers=["X-Request-ID"], max_age=600)`.
- Spring: `CorsRegistry` → `.allowedHeaders(...).exposedHeaders("X-Request-ID").maxAge(600)`.
- Если в браузере включена трассировка Sentry или OpenTelemetry, добавьте в
  `Access-Control-Allow-Headers` их заголовки (`sentry-trace`, `baggage`).

Ответы, которые формирует сам шлюз (429, 502, 504), идут без CORS-заголовков
бэкенда. Браузер покажет их как CORS-ошибку, и JavaScript не прочитает ни
статус, ни `request_id`, хотя в логе шлюза запрос есть. Если это важно,
отвечайте на CORS в nginx. Помните про правило «всё или ничего»: в
`location` со своими `add_header` подключите `snippets/response_headers.conf`.

## 9. Mobile

Мобильное приложение — первый узел (`hop_name` — `mobile-android` или
`mobile-ios`):

- `mobile_launch_id` — создаётся один раз при запуске приложения;
- `X-Request-ID` — новый на каждое пользовательское действие (по умолчанию —
  на каждый вызов API); чтобы связать вызовы одного действия, передайте один ID;
- `mobile_request_id` — один вызов API; при повторе того же вызова передайте прежний;
- `local_request_id` — новый на каждую HTTP-попытку; он уходит в
  `X-Prev-Request-ID` и в цепочку `hop_name:local_request_id`.

Мобильный клиент — такой же узел, как остальные: в цепочку попадает его
`local_request_id`, а не `mobile_request_id`. Так повторы одного вызова,
которые делает приложение, видны в логах шлюза как разные попытки с общим
`mobile_request_id`.

Hop приложения шлюз принимает, пока на нём `$trace_accept_client_hops` = 1
(по умолчанию, [раздел 3](#3-граница-доверия)). В ответе приложение получает
`X-Request-ID` и эхо `X-Mobile-Launch-ID` / `X-Mobile-Request-ID`;
`X-Prev-Request-ID`, `X-Request-Chain` и `X-HOP-Name` клиентам из интернета
не возвращаются. Отправляйте `Accept: application/json`: тогда ошибки самого
шлюза (429, 502, 504 …) под любым путём придут в JSON с `request_id`, а не
HTML-страницей.

### Flutter / Dart: http ^1.x и Dio 5

```dart
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;

final _random = Random.secure();

/// 32 hex-символа (16 случайных байт).
String newId() => List.generate(
    16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

/// Создаётся один раз при запуске приложения.
class TraceSession {
  TraceSession(this.hopName) : mobileLaunchId = newId();

  final String hopName; // mobile-android | mobile-ios
  final String mobileLaunchId;

  /// Заголовки одной HTTP-попытки: новый local_request_id на каждую отправку.
  Map<String, String> attemptHeaders() {
    final localId = newId();
    return {
      'X-Prev-Request-ID': localId,
      'X-Request-Chain': '$hopName:$localId',
      'X-Mobile-Launch-ID': mobileLaunchId,
    };
  }
}

/// package:http ^1.x
class TracedClient extends http.BaseClient {
  TracedClient(this._inner, this._session);

  final http.Client _inner;
  final TraceSession _session;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers
      ..putIfAbsent('X-Request-ID', newId) // своё значение — чтобы связать запросы одного действия
      ..putIfAbsent('X-Mobile-Request-ID', newId) // сохраняется при повторе того же вызова
      ..addAll(_session.attemptHeaders());
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// Dio 5.x
class TraceInterceptor extends Interceptor {
  TraceInterceptor(this._session);

  final TraceSession _session;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.headers
      ..putIfAbsent('X-Request-ID', newId)
      ..putIfAbsent('X-Mobile-Request-ID', newId)
      ..addAll(_session.attemptHeaders());
    handler.next(options);
  }
}
```

```dart
final session = TraceSession(Platform.isIOS ? 'mobile-ios' : 'mobile-android'); // dart:io
final client = TracedClient(http.Client(), session);
final dio = Dio()..interceptors.add(TraceInterceptor(session));

final action = newId();
await client.get(Uri.parse('https://api.example.com/api/cart'), headers: {'X-Request-ID': action});
await dio.get('https://api.example.com/api/prices', options: Options(headers: {'X-Request-ID': action}));
```

Заголовки в `package:http` и Dio нечувствительны к регистру, поэтому
`putIfAbsent` находит значение, заданное как `x-request-id`. Если
retry-интерцептор Dio повторно отправляет те же `RequestOptions`,
`X-Request-ID` и `X-Mobile-Request-ID` сохраняются, а `local_request_id`
создаётся новый.

### Android: OkHttp (Kotlin)

```kotlin
import java.security.SecureRandom
import okhttp3.Interceptor
import okhttp3.Response

object TraceIds {
    private val random = SecureRandom()

    /** 32 hex (16 случайных байт). */
    fun newId(): String = ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it) }
}

/** Создаётся один раз при запуске приложения (например, в Application.onCreate). */
class TraceSession(val hopName: String = "mobile-android") {
    val mobileLaunchId: String = TraceIds.newId()
}

/** Application-интерцептор: вызывается один раз на вызов API. */
class TraceInterceptor(private val session: TraceSession) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val localId = TraceIds.newId()
        return chain.proceed(
            request.newBuilder()
                // Заданные вызывающим кодом значения сохраняются: одно действие — один X-Request-ID.
                .header("X-Request-ID", request.header("X-Request-ID") ?: TraceIds.newId())
                .header("X-Mobile-Request-ID", request.header("X-Mobile-Request-ID") ?: TraceIds.newId())
                .header("X-Prev-Request-ID", localId)
                .header("X-Request-Chain", "${session.hopName}:$localId")
                .header("X-Mobile-Launch-ID", session.mobileLaunchId)
                .build(),
        )
    }
}

// val client = OkHttpClient.Builder().addInterceptor(TraceInterceptor(session)).build()
```

`addInterceptor` вызывается один раз на вызов; внутренние повторы и редиректы
OkHttp идут с теми же заголовками. Для Retrofit передайте этот `OkHttpClient`
в `Retrofit.Builder().client(...)`. ID запроса для отчёта об ошибке —
`response.header("X-Request-ID")`.

### iOS: URLSession (Swift)

```swift
import Foundation

enum TraceIds {
    /// 32 hex в нижнем регистре (UUID v4 без дефисов).
    static func newId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// Создаётся один раз при запуске приложения.
final class TraceSession: Sendable {
    let hopName = "mobile-ios"
    let mobileLaunchId = TraceIds.newId()

    /// Добавляет заголовки трассировки. traceRequestId — ID пользовательского
    /// действия; mobileRequestId — ID вызова API (при повторе передайте тот же).
    func traced(_ request: URLRequest,
                traceRequestId: String = TraceIds.newId(),
                mobileRequestId: String = TraceIds.newId()) -> URLRequest {
        var request = request
        let localId = TraceIds.newId()
        request.setValue(traceRequestId, forHTTPHeaderField: "X-Request-ID")
        request.setValue(localId, forHTTPHeaderField: "X-Prev-Request-ID")
        request.setValue("\(hopName):\(localId)", forHTTPHeaderField: "X-Request-Chain")
        request.setValue(mobileLaunchId, forHTTPHeaderField: "X-Mobile-Launch-ID")
        request.setValue(mobileRequestId, forHTTPHeaderField: "X-Mobile-Request-ID")
        return request
    }
}
```

```swift
let trace = TraceSession()   // например, свойство App или AppDelegate
let url = URL(string: "https://api.example.com/api/orders")!
let (data, response) = try await URLSession.shared.data(for: trace.traced(URLRequest(url: url)))
if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
    // Шлюз мог заменить невалидный ID — в отчёт об ошибке берите значение из ответа.
    let requestId = http.value(forHTTPHeaderField: "X-Request-ID") ?? ""
    print("API \(http.statusCode), request_id=\(requestId)")
}
```

### Аналитика и отчёты о сбоях

- `mobile_launch_id` задайте один раз как параметр сессии: в Crashlytics —
  `setCustomKey`, в AppMetrica — параметр окружения приложения (app environment).
- `trace_request_id` (из ответа) добавляйте к событиям об ошибках API.
- Цепочку в аналитику не отправляйте: она длинная и ничего не даёт вне логов.

## 10. Логи, метрики, Sentry

**Логи.** Каждая строка лога, записанная при обработке запроса, содержит
`hop_name`, `trace_request_id`, `local_request_id`, `prev_request_id`,
`hops_chain`, `mobile_launch_id`, `mobile_request_id` — с этими именами, как в
JSON-логе шлюза. Тогда один запрос в Loki, Elasticsearch или ClickHouse
находит строки всех узлов. Пустые значения пишите как `""`.

**Метрики.** ID трассировки **никогда** не используются как метки (labels)
Prometheus и теги метрик. Каждое новое значение метки создаёт новый
временной ряд, и уникальный на каждый запрос ID быстро выводит систему
метрик из строя. Документация Prometheus прямо предостерегает от меток с
неограниченным множеством значений, таких как ID пользователей.

- Метки — с небольшим числом значений: `hop_name`, шаблон маршрута
  (`/api/orders/{id}`, а не фактический путь), метод, класс статуса (`2xx`, `5xx`).
- Связь «метрика → конкретный запрос» дают exemplars (OpenMetrics,
  OpenTelemetry): к отдельным точкам гистограммы прикладывается trace ID, и
  новых рядов не появляется.
- Или просто переходите из графика в логи по времени и `hop_name`.

**Sentry.**

- Теги (индексируются, по ним работает поиск): `trace_request_id` и
  `hop_name`. Значение тега ограничено 200 символами, поэтому цепочку в тег
  не кладите: после 4–5 узлов она длиннее.
- Остальное — в структурированный контекст (`setContext`) под своим именем,
  например `request_trace`. Имя `trace` не используйте: его занимает
  собственная трассировка Sentry.
- `extra` (Additional Data) Sentry объявил устаревшим в пользу контекстов.

```ts
Sentry.withScope((scope) => {
  scope.setTag('trace_request_id', requestId);
  scope.setTag('hop_name', 'frontend-web');
  scope.setContext('request_trace', { local_request_id: localId, hops_chain: chain });
  Sentry.captureException(error);
});
```

```php
\Sentry\configureScope(function (\Sentry\State\Scope $scope): void {
    $trace = \App\Trace\TraceContext::current();
    if ($trace !== null) {
        $scope->setTag('trace_request_id', $trace->traceRequestId);
        $scope->setTag('hop_name', $trace->hopName);
        $scope->setContext('request_trace', $trace->toLogContext());
    }
});
```

## 11. Проверка на локальном стенде

Стенд — `compose.yaml`: шлюз `edge-gateway` на `http://localhost` (порт
`HTTP_PORT` из `.env`, по умолчанию 80) и демо-бэкенд `traefik/whoami`,
который в теле ответа возвращает все полученные заголовки. Путь `/api/…`
проксируется в него, поэтому ответ на `/api/…` показывает, что получил
бэкенд. Если в `.env` задан другой `HTTP_PORT` или `HOP_NAME`, подставьте
свои значения.

```bash
make up            # или: docker compose up -d --wait
make health        # {"status":"ok"} — служебный сервер 127.0.0.1:8080 внутри контейнера
```

Запрос с хоста приходит в контейнер через NAT Docker, то есть не с
loopback-адреса. Поэтому в ответе шлюза вы увидите только `X-Request-ID` (и
эхо `X-Mobile-*`). `X-HOP-Name`, `X-Request-Chain` и `X-Prev-Request-ID`
смотрите в теле ответа (что получил бэкенд), в логе шлюза или в ответе
loopback-клиенту (проверка 2).

**1. Шлюз — первый узел.**

```bash
curl -i http://localhost/api/demo
```

Заголовки ответа (сокращено):

```text
HTTP/1.1 200 OK
Content-Type: text/plain; charset=utf-8
X-Request-ID: a522c23e652df8bedd5c1c83e34b0ece
Cache-Control: no-store
```

Тело — что получил бэкенд (сокращено; whoami пишет имена заголовков в
каноническом виде Go, регистр не важен):

```text
GET /api/demo HTTP/1.1
Host: localhost
X-Forwarded-For: 172.25.0.1
X-Forwarded-Host: localhost
X-Forwarded-Port: 80
X-Forwarded-Proto: http
X-Hop-Name: edge-gateway
X-Prev-Request-Id: a522c23e652df8bedd5c1c83e34b0ece
X-Real-Ip: 172.25.0.1
X-Request-Chain: edge-gateway:a522c23e652df8bedd5c1c83e34b0ece
X-Request-Id: a522c23e652df8bedd5c1c83e34b0ece
```

Клиент ничего не прислал, поэтому шлюз сгенерировал trace ID, и он совпадает
с `local_request_id` шлюза. `X-Prev-Request-ID` для бэкенда — это
`local_request_id` шлюза. `X-Real-Ip` — адрес сетевого шлюза Docker, через
который прошёл NAT (у вас может быть другим). Для `edge-gateway` это обычный
клиент не с loopback, поэтому `X-HOP-Name` и `X-Request-Chain` в ответ не
попали.

**2. Loopback-клиент видит топологию.** Запустите curl в сетевом
пространстве контейнера шлюза: запрос придёт с `::1` или `127.0.0.1`. Способ
работает с любым образом шлюза (в самих образах curl может не быть):

```bash
docker run --rm --network "container:$(docker compose ps -q gateway)" \
  curlimages/curl -si http://localhost/api/demo
```

В заголовках ответа (сокращено):

```text
X-Request-ID: 1d3da9b546a70b2f6760a3212aa6041b
X-HOP-Name: edge-gateway
X-Request-Chain: edge-gateway:1d3da9b546a70b2f6760a3212aa6041b
```

Эхо `X-Prev-Request-ID` появится, если loopback-клиент его прислал. Кому ещё
показывать эти заголовки, задаёт `geo $trace_expose_internal`
([раздел 3](#3-граница-доверия)).

**3. Запрос от мобильного клиента.**

```bash
curl -i http://localhost/api/orders \
  -H 'X-Request-ID: 4bf92f3577b34da6a3ce929d0e0e4736' \
  -H 'X-Prev-Request-ID: 9d2c4e1f7a3b45c8b6e0f1a2d3c4b5a6' \
  -H 'X-Request-Chain: mobile-android:9d2c4e1f7a3b45c8b6e0f1a2d3c4b5a6' \
  -H 'X-Mobile-Launch-ID: 1c8e5a0b2f4d4e6a8c0b1d2e3f4a5b6c' \
  -H 'X-Mobile-Request-ID: 7f3a9c2e5b1d4f6a8e0c2b4d6f8a1c3e'
```

Заголовки трассировки в ответе:

```text
X-Request-ID: 4bf92f3577b34da6a3ce929d0e0e4736
X-Mobile-Launch-ID: 1c8e5a0b2f4d4e6a8c0b1d2e3f4a5b6c
X-Mobile-Request-ID: 7f3a9c2e5b1d4f6a8e0c2b4d6f8a1c3e
```

В теле — что получил бэкенд (сокращено):

```text
X-Hop-Name: edge-gateway
X-Mobile-Launch-Id: 1c8e5a0b2f4d4e6a8c0b1d2e3f4a5b6c
X-Mobile-Request-Id: 7f3a9c2e5b1d4f6a8e0c2b4d6f8a1c3e
X-Prev-Request-Id: 5fb3d8f7be1ad8afdcd3ecade64dbdef
X-Request-Chain: mobile-android:9d2c4e1f7a3b45c8b6e0f1a2d3c4b5a6, edge-gateway:5fb3d8f7be1ad8afdcd3ecade64dbdef
X-Request-Id: 4bf92f3577b34da6a3ce929d0e0e4736
```

В `X-Prev-Request-ID` бэкенд получил ID шлюза (`5fb3d8f7…`), а не клиента, и
цепочку с hop'ом приложения. `X-Prev-Request-ID` клиента (`9d2c4e1f…`) шлюз
записал в лог как `prev_request_id`. `local_request_id` шлюза при каждом
запуске свой.

**4. Лог шлюза по trace ID** (нужен `jq`; без него — просто `grep`):

```bash
docker compose logs --no-log-prefix gateway | grep '^{' \
  | jq -c 'select(.trace.trace_request_id == "4bf92f3577b34da6a3ce929d0e0e4736") | .trace'
```

```json
{"hop_name":"edge-gateway","hop_physical":"edge-gateway","prev_request_id":"9d2c4e1f7a3b45c8b6e0f1a2d3c4b5a6","local_request_id":"5fb3d8f7be1ad8afdcd3ecade64dbdef","trace_request_id":"4bf92f3577b34da6a3ce929d0e0e4736","trace_id_source":"header","hops_chain":"mobile-android:9d2c4e1f7a3b45c8b6e0f1a2d3c4b5a6, edge-gateway:5fb3d8f7be1ad8afdcd3ecade64dbdef","mobile_launch_id":"1c8e5a0b2f4d4e6a8c0b1d2e3f4a5b6c","mobile_request_id":"7f3a9c2e5b1d4f6a8e0c2b4d6f8a1c3e","traceparent":{"trace_id":"","parent_id":""}}
```

**5. traceparent вместо X-Request-ID.** `-D -` выводит заголовки ответа
вместе с телом (в теле whoami — то, что получил бэкенд):

```bash
curl -s -D - http://localhost/api/demo \
  -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
  | grep -iE '^(x-request-id|traceparent):'
```

```text
X-Request-ID: 4bf92f3577b34da6a3ce929d0e0e4736                          ← ответ шлюза
Traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01   ← бэкенд получил без изменений
X-Request-Id: 4bf92f3577b34da6a3ce929d0e0e4736                          ← бэкенд получил trace-id
```

В логе шлюза — `"trace_id_source":"traceparent"` и
`"traceparent":{"trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","parent_id":"00f067aa0ba902b7"}`.
С включённым модулем OpenTelemetry `traceparent` у бэкенда будет другим
([раздел 5](#5-w3c-trace-context-и-opentelemetry)).

**6. Некорректные значения заменяются.**

```bash
curl -s -o /dev/null -D - http://localhost/api/demo -H 'X-Request-ID: bad id with spaces' \
  | grep -i '^x-request-id'
# X-Request-ID: <новые 32 hex>

curl -s http://localhost/api/demo \
  -H 'X-Request-Chain: h1:1, h2:2, h3:3, h4:4, h5:5, h6:6, h7:7, h8:8, h9:9, h10:10, h11:11, h12:12, h13:13, h14:14, h15:15, h16:16, h17:17' \
  | grep -i '^x-request-chain'
# X-Request-Chain: ~, h3:3, h4:4, …, h17:17, edge-gateway:<local>
```

Цепочку смотрим в теле ответа, то есть у бэкенда: в заголовках ответа
клиенту с хоста её нет. Остальные случаи — в таблице
[2.4](#24-цепочка-x-request-chain), они проверены так же.

**7. Пустой заголовок.** `curl -H 'X-Prev-Request-ID: '` (двоеточие и
пробел) не отправляет заголовок вовсе — так в curl удаляют заголовки. Пустое
значение отправляется через точку с запятой:

```bash
curl -sv -o /dev/null http://localhost/api/demo \
  -H 'X-Request-ID: 5c1e0f7a9b3d4c2e8f6a1b0c9d8e7f6a' -H 'X-Prev-Request-ID;' 2>&1 | grep -i prev
# > X-Prev-Request-ID:          ← запрос ушёл с пустым заголовком

docker compose logs --no-log-prefix gateway | grep '^{' \
  | jq -c 'select(.trace.trace_request_id == "5c1e0f7a9b3d4c2e8f6a1b0c9d8e7f6a") | .trace.prev_request_id'
# ""
```

Шлюз считает пустой заголовок отсутствующим: `prev_request_id` в логе
пустой, как и без заголовка.

**8. Ошибки шлюза содержат ID.** HTML-страница — для браузера и для curl
без `Accept`:

```bash
curl -s http://localhost/missing -H 'X-Request-ID: 4bf92f3577b34da6a3ce929d0e0e4736' | grep 'ID запроса'
# … укажите ID запроса: <code>4bf92f3577b34da6a3ce929d0e0e4736</code></p>
```

JSON — для клиента, который просит JSON:

```bash
curl -i http://localhost/missing -H 'Accept: application/json' \
  -H 'X-Request-ID: 4bf92f3577b34da6a3ce929d0e0e4736'
```

```text
HTTP/1.1 404 Not Found
Content-Type: application/problem+json
X-Request-ID: 4bf92f3577b34da6a3ce929d0e0e4736
Cache-Control: no-store

{"type":"about:blank","title":"Not Found","status":404,"request_id":"4bf92f3577b34da6a3ce929d0e0e4736"}
```

Бэкенд недоступен:

```bash
docker compose stop backend
curl -i http://localhost/api/demo -H 'X-Request-ID: 4bf92f3577b34da6a3ce929d0e0e4736'
docker compose start backend
```

Ответ — `504 Gateway Time-out` через 5 с (`proxy_connect_timeout`), пока
шлюз соединяется по старому адресу бэкенда, или сразу `502 Bad Gateway`, когда
имя `backend` перестало разрешаться (DNS перечитывается раз в 10 с,
`global_resolver.conf`). В обоих случаях `Content-Type:
application/problem+json`, в теле
`"request_id":"4bf92f3577b34da6a3ce929d0e0e4736"`. Для `/api/` JSON приходит
и без `Accept`. После `docker compose start backend` шлюз возвращает бэкенд в
работу в течение примерно 10 секунд.

**9. Изменение конфигурации.** После правки файлов в `rootfs/etc/nginx`
(например, `geo $trace_expose_internal`):

```bash
make check     # проверка конфигурации в отдельном контейнере
make reload    # проверка и применение без остановки (SIGHUP)
make status    # stub_status: соединения и запросы
```

Без `make` — полная форма (`NGX_BIN` — `openresty`, `nginx` или `angie`, как
в `.env`):

```bash
docker compose exec gateway "$NGX_BIN" -c /etc/nginx/nginx.conf -t -g "pid /run/nginx.pid;"
docker compose kill -s HUP gateway
```

Внутри контейнера конфигурация шлюза используется только с ключом
`-c /etc/nginx/nginx.conf`: команды без него работают с конфигурацией самого
образа, а не шлюза.

Эти и другие проверки (всего 130) выполняет `make test`
(`scripts/test.sh`). Он поднимает отдельный проект compose на своих портах
(28080, 28443) и стенд из `make up` не трогает. Остановить стенд: `make down`.

## 12. Пример end-to-end

Пользователь нажимает «Оформить заказ» в Android-приложении. Сервис заказов
`backend-orders` (Laravel) вызывает сервис оплаты `backend-billing` (Go) и
ставит задачу на отправку письма. Все ID — 32 hex.

**Приложение** (`mobile-android`, запуск `1c8e5a0b…`, действие — новый trace ID):

```text
POST /api/orders
X-Request-ID:        4bf92f3577b34da6a3ce929d0e0e4736
X-Prev-Request-ID:   9d2c4e1f7a3b45c8b6e0f1a2d3c4b5a6    ← local_request_id приложения
X-Request-Chain:     mobile-android:9d2c4e1f7a3b45c8b6e0f1a2d3c4b5a6
X-Mobile-Launch-ID:  1c8e5a0b2f4d4e6a8c0b1d2e3f4a5b6c
X-Mobile-Request-ID: 7f3a9c2e5b1d4f6a8e0c2b4d6f8a1c3e
```

**Шлюз** (`edge-gateway`, local `5fb3d8f7…`) проверяет значения,
принимает hop приложения (`$trace_accept_client_hops` = 1, по умолчанию),
пишет строку лога с `prev_request_id = 9d2c4e1f…` и проксирует в `backend-orders`:

```text
X-Request-ID:        4bf92f3577b34da6a3ce929d0e0e4736
X-Prev-Request-ID:   5fb3d8f7be1ad8afdcd3ecade64dbdef
X-Request-Chain:     mobile-android:9d2c4e1f7a3b45c8b6e0f1a2d3c4b5a6, edge-gateway:5fb3d8f7be1ad8afdcd3ecade64dbdef
X-HOP-Name:          edge-gateway
X-Mobile-Launch-ID:  1c8e5a0b2f4d4e6a8c0b1d2e3f4a5b6c
X-Mobile-Request-ID: 7f3a9c2e5b1d4f6a8e0c2b4d6f8a1c3e
```

**backend-orders** (local `52175c5d…`) логирует
`prev_request_id = 5fb3d8f7…` и вызывает `backend-billing`:

```text
X-Request-ID:        4bf92f3577b34da6a3ce929d0e0e4736
X-Prev-Request-ID:   52175c5dbc662808a893b980f1320112
X-Request-Chain:     mobile-android:9d2c4e1f7a3b45c8b6e0f1a2d3c4b5a6, edge-gateway:5fb3d8f7be1ad8afdcd3ecade64dbdef, backend-orders:52175c5dbc662808a893b980f1320112
X-HOP-Name:          backend-orders
X-Mobile-Launch-ID:  1c8e5a0b2f4d4e6a8c0b1d2e3f4a5b6c
X-Mobile-Request-ID: 7f3a9c2e5b1d4f6a8e0c2b4d6f8a1c3e
```

**backend-billing** (local `0af7651916cd43dd8448eb211c80319c`) пишет в лог
`prev_request_id = 52175c5d…` и цепочку
`…, backend-orders:52175c5d…, backend-billing:0af76519…`.

**Задача в очереди** (`backend-orders-queue`, local `891fb2a9…`) выполняется
позже, с тем же trace ID: `prev_request_id = 52175c5d…`, цепочка
`…, backend-orders:52175c5d…, backend-orders-queue:891fb2a9a557cf3bcce020bb8d64c503`.

**Ответ приложению** от шлюза: `X-Request-ID: 4bf92f35…` и `X-Mobile-*`
(эхо; `X-Mobile-Request-ID` указывает вызов API, к которому относится
ответ). `X-Prev-Request-ID`, `X-HOP-Name` и `X-Request-Chain` приложение из
интернета не получит: их шлюз показывает только loopback-клиентам.

**Разбор инцидента.** Пользователь сообщает ID `4bf92f35…` из экрана ошибки.
Поиск по `trace_request_id` во всех логах возвращает строки шлюза,
backend-orders, backend-billing и задачи из очереди. Порядок и вложенность
восстанавливаются по `prev_request_id` → `local_request_id`:
приложение → шлюз → backend-orders → (backend-billing, backend-orders-queue).
Все события запуска приложения находятся по `mobile_launch_id = 1c8e5a0b…`.

## 13. Частые ошибки

- **Один trace ID на сессию или вкладку.** Поиск по нему возвращает
  тысячи запросов. Trace ID — на действие, сессия — в `mobile_launch_id`.
- **`X-Prev-Request-ID` = входящий prev.** В исходящем запросе это всегда
  свой `local_request_id`.
- **Цепочка перезаписывается** вместо дописывания, или узел не добавляет себя.
- **Нет своего `local_request_id`** — узел использует trace ID как локальный.
  Его строки лога нельзя отличить от строк других узлов.
- **Отправка пустых заголовков и строк `null` / `undefined`.** Пустые
  заголовки бесполезны, а `undefined` проходит проверку формата и становится ID.
- **Бэкенд выставляет заголовки трассировки в ответе.** Шлюз скрывает эти
  копии для всех протоколов, но свой `*_hide_header` в `location` отменяет
  унаследованный список, и клиент получит дубли ([раздел 4](#4-шлюз-где-что-в-репозитории)).
- **Свой `proxy_set_header`, `proxy_hide_header` или `add_header` в `location`
  без `include` соответствующего snippet'а.** Пропадают все заголовки
  трассировки ([раздел 4](#4-шлюз-где-что-в-репозитории)).
- **PHP-location без `fastcgi_trace_params.conf`** (или без
  `fastcgi_php.conf`). PHP видит сырые заголовки клиента, а не значения
  шлюза, в том числе поддельные `X-Forwarded-Host` и `X-Forwarded-Proto`.
- **Приватные сети в `$trace_expose_internal`, когда адреса клиентов не
  настоящие** (NAT Docker, SNAT в Kubernetes, балансировщик без realip).
  Топологию увидит любой клиент ([раздел 3](#3-граница-доверия)).
- **`$trace_accept_client_hops` = 0 на шлюзе, к которому обращаются браузеры
  и мобильные приложения.** Их hop'ы превращаются в `~` и пропадают из
  цепочки и логов.
- **Новый `server{}` без `snippets/error_pages.conf` или не с ним первым.**
  Ошибки шлюза уходят встроенными страницами nginx без ID запроса, а при
  `return` в фазе rewrite лог может получить не исходный запрос.
- **Проверка или перезагрузка конфигурации внутри контейнера без
  `-c /etc/nginx/nginx.conf`.** Команда работает с конфигурацией образа, а
  не шлюза. Используйте `make check` и `make reload` ([раздел 11](#11-проверка-на-локальном-стенде)).
- **ID в метках метрик** и **цепочка в тегах Sentry** ([раздел 10](#10-логи-метрики-sentry)).
- **Доверие к ID**: использование как ключа идемпотентности, для
  авторизации или лимитов.
- **`hop_name` = ID контейнера** или с двоеточием. Имя должно быть ролью и
  соответствовать `[A-Za-z0-9._-]{1,64}`.
- **Потеря контекста в асинхронном коде**: Go-запрос без
  `NewRequestWithContext`, Java-код в другом потоке без переноса MDC,
  задачи очереди без заголовков трассировки.

## 14. FAQ

**Можно ли генерировать trace ID на каждом узле?**
Нет. Он создаётся один раз — первым узлом — и передаётся без изменений. Каждый
узел генерирует только свой `local_request_id`.

**UUID вместо 32 hex можно?**
Принимается (формат из [2.3](#23-формат-id)), но генерируйте 32 hex: это
совпадает с `$request_id` nginx и trace-id W3C.

**Почему шлюз вернул другой `X-Request-ID`, чем я отправил?**
Значение не прошло проверку ([2.3](#23-формат-id)) или заголовок был
отправлен дважды. Шлюз взял trace-id из корректного `traceparent`
(в логе `trace_id_source = "traceparent"`) или сгенерировал новый ID
(`trace_id_source = "generated"`).

**Почему в ответе нет `X-Request-Chain` и `X-HOP-Name`?**
По умолчанию шлюз показывает их только клиентам с loopback-адресов
([раздел 3](#3-граница-доверия)); запрос с хоста в контейнер приходит через
NAT Docker. Цепочка есть в логе шлюза (`trace.hops_chain`) и у бэкенда: на
стенде её показывает тело ответа `curl http://localhost/api/demo`
([раздел 11](#11-проверка-на-локальном-стенде)).

**Почему в ответе нет `X-Prev-Request-ID`?**
Это эхо входящего значения, а не ID шлюза, и его, как и цепочку, видят
только loopback-клиенты. Кроме того, значения нет, если клиент его не
прислал, прислал некорректное или шлюз не принимает hop'ы этого клиента
(`$trace_accept_client_hops`).

**Что значит `~` в начале цепочки?**
Входящая цепочка была длиннее 16 элементов или содержала некорректный
элемент, и начало отброшено ([2.4](#24-цепочка-x-request-chain)). Или шлюз
не принимает цепочку от этого клиента (`$trace_accept_client_hops` = 0 для
его адреса, [раздел 3](#3-граница-доверия)).

**Как получать ошибки шлюза в JSON?**
Для путей `/api/…` JSON (RFC 9457) приходит всегда. Для остальных отправляйте
`Accept: application/json` без `text/html` или добавьте префикс своего API в
`map $error_page_uri` ([раздел 4](#4-шлюз-где-что-в-репозитории)).

**Почему `edge-gateway` встречается в цепочке дважды?**
Запрос прошёл через шлюз два раза, например сервис вызвал другой сервис
через публичный адрес. Это нормально: у каждого прохода свой `local_request_id`.

**Почему у шлюза `trace_request_id` совпадает с `local_request_id`?**
Клиент не прислал trace ID, и шлюз, будучи первым узлом, использовал свой
`$request_id`.

**Как поменять имя шлюза в цепочке?**
`HOP_NAME` в `.env` (затем `docker compose up -d`, чтобы пересоздать контейнер
с новым hostname) или карта в `global_hop_name.conf` (затем `make reload`).

**У нас OpenTelemetry — этот стандарт нужен?**
Да, они дополняют друг друга ([раздел 5](#5-w3c-trace-context-и-opentelemetry)):
`X-Request-ID` есть в каждой строке лога шлюза и работает без APM, а при
наличии `traceparent` шлюз использует тот же ID. Span'ы самого шлюза можно
включить модулем OpenTelemetry в образах nginx `*-otel` и Angie.
