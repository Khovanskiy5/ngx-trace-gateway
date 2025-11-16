# Руководство разработчика: сквозная трассировка запросов (Nginx/OpenResty, backend, frontend, mobile)

Это практичное и простое руководство для всех команд: DevOps, backend, frontend и mobile. Здесь описаны стандарты заголовков и идентификаторов, готовые примеры конфигураций и чек‑листы — чтобы вы быстро внедрили единую трассировку и одинаково интерпретировали данные в логах, метриках и APM/Crash‑репортерах.

Компоненты: Nginx/OpenResty, backend‑сервисы, frontend‑web, мобильные приложения (iOS/Android) + аналитика (AppMetrica, Google Firebase/Analytics) и мониторинг ошибок (Sentry).

Смежные файлы в этом репозитории:
- rootfs/etc/nginx/conf.d/http.conf — подключение глобальных модулей
- rootfs/etc/nginx/conf.d/globals/global_trace.conf — map переменные (ID и цепочки)
- rootfs/etc/nginx/conf.d/globals/global_proxy.conf — проброс заголовков X‑*
- rootfs/etc/nginx/conf.d/globals/global_hop_name.conf — имя узла (hop)

Содержание:
- 0. Что и зачем внедряем
- 1. Глоссарий: идентификаторы и заголовки
- 2. Единые правила (форматы, инварианты, best practices)
- 3. Быстрый старт по ролям
  - 3.1 DevOps/Nginx
  - 3.2 Backend
  - 3.3 Frontend
  - 3.4 Mobile
- 4. Nginx: эталонная реализация (где что в репозитории)
- 5. Backend: требования и примеры
- 6. Frontend: требования и примеры
- 7. Mobile: требования и примеры
- 8. Очереди и фоновые задачи
- 9. Логирование и Sentry/метрики
- 10. Проверка и отладка (curl/grep)
- 11. Примеры end‑to‑end сценариев
- 12. Частые ошибки и как их избежать
- 13. Мини‑FAQ
- Приложение A. Генерация 32‑символьного hex ID (примеры кода)

---

## 0. Что и зачем внедряем (коротко)

Цель — однозначно связать все запросы одного пользовательского действия в разных компонентах системы и уметь восстановить маршрут (цепочку hop’ов) запроса. Это нужно для:
- быстрого разбора инцидентов (по одному trace ID можно пройти от клиента до backend);
- корреляции логов, метрик и событий в Sentry/AppMetrica/Google;
- поиска «узких мест» и проблемных звеньев цепочки.

Ключевые идеи:
- один сквозной идентификатор запроса: X-Request-ID;
- на каждом узле генерируем локальный hop‑ID и дописываем себя в цепочку X-Request-Chain;
- вниз по цепочке передаём «кто я» в X-Prev-Request-ID, а пользователю возвращаем «кто был до меня»;
- мобильные идентификаторы (запуск и запрос) передаются прозрачно.

---

## 1. Глоссарий: идентификаторы и заголовки

Идентификаторы:
1) trace_request_id — сквозной ID запроса (end‑to‑end); живёт от клиента до backend. Источник: первый участник в цепочке (клиент или самый первый сервер). Передаётся в X-Request-ID.
2) local_request_id — локальный ID текущего узла (per‑hop); новый для каждого входящего запроса на этот узел.
3) prev_request_id — ID предыдущего hop’а. Это то, что пришло к нам в заголовке X-Prev-Request-ID. Может быть пустым.
4) request_hops_chain — нарастающая цепочка hop’ов в формате hop_name:local_request_id, разделитель: запятая и пробел. Пример: mobile-android:aaa, edge-nginx:bbb, backend-orders:ccc. Передаётся в X-Request-Chain.
5) hop_name — логическое имя роли/узла (не ID). Примеры: edge-nginx, api-nginx, backend-auth, frontend-web, mobile-ios, mobile-android. Возвращаем клиенту в X-HOP-Name.
6) mobile_launch_id — ID одного запуска мобильного приложения; создаётся при старте приложения. Передаётся в X-Mobile-Launch-ID.
7) mobile_request_id — ID конкретного HTTP‑вызова мобильного клиента; новый на каждый запрос. Передаётся в X-Mobile-Request-ID.

Заголовки (всегда отправляем и логируем, даже если значение пустое):
- X-Request-ID = trace_request_id
- X-Prev-Request-ID: во входящем запросе — «кто был до меня»; в исходящем запросе — всегда наш local_request_id
- X-Request-Chain = request_hops_chain
- X-HOP-Name = hop_name (логическое имя узла)
- X-Mobile-Launch-ID = mobile_launch_id
- X-Mobile-Request-ID = mobile_request_id

Формат всех ID: 32‑символьная шестнадцатеричная строка (случайные 16 байт, закодированные в hex). См. Приложение A.

---

## 2. Единые правила (инварианты и best practices)

- Всегда отправляйте и логируйте X-Request-ID, X-Prev-Request-ID, X-Request-Chain; для мобильных клиентов дополнительно X-Mobile-Launch-ID и X-Mobile-Request-ID.
- prev_request_id в логах отражает то, что пришло сверху (или пустую строку). В исходящем запросе X-Prev-Request-ID всегда равен нашему local_request_id.
- Цепочку X-Request-Chain не перезаписываем — только дописываем текущий hop.
- Используйте общий middleware/interceptor, чтобы не размножать логику по коду.
- Не меняйте формат ID (только 32‑символьный hex), не используйте UUID/ULID, чтобы не усложнять парсинг логов/метрик.

---

## 3. Быстрый старт по ролям

### 3.1. DevOps / Nginx
- Подключите файлы из globals в http.conf (в этом репозитории уже подключено в правильном порядке).
- Убедитесь, что в global_hop_name.conf настроено понятное имя роли (hop_name). По умолчанию оно берётся из hostname.
- В global_trace.conf объявлены map для prev/trace/local/current_hop/цепочки и мобильных ID.
- В global_proxy.conf выставляются заголовки X‑* и возвращаются клиенту.

### 3.2. Backend
- На входе прочитайте заголовки, сгенерируйте local_request_id, соберите current_hop и цепочку. Сохраните всё в контексте запроса/логгера.
- На исходящих HTTP запросах выставляйте X-Request-ID, X-Prev-Request-ID (свой local_request_id), X-Request-Chain, X-HOP-Name, X-Mobile-Launch-ID, X-Mobile-Request-ID.
- Логируйте все идентификаторы и добавляйте их в Sentry (tags/extra).

### 3.3. Frontend
- Держите один trace_request_id на сессию/жизненный цикл вкладки (пока сервер не навяжет свой). На каждый запрос генерируйте новый local_request_id и дописывайте себя в цепочку.
- Отправляйте X-Request-ID, X-Prev-Request-ID (обычно пусто), X-Request-Chain и, если проксируете мобильные данные, X-Mobile-*.

### 3.4. Mobile
- При старте приложения создайте mobile_launch_id; на каждый HTTP‑запрос создавайте новый mobile_request_id.
- В каждый запрос отправляйте X-Request-ID, X-Prev-Request-ID (пусто), X-Request-Chain (с текущим hop), X-Mobile-Launch-ID и X-Mobile-Request-ID.
- Логируйте эти значения и отправляйте их в Sentry/AppMetrica/Google.

---

## 4. Nginx: эталонная реализация (где что в репозитории)

Карты (map) объявлены в rootfs/etc/nginx/conf.d/globals/global_trace.conf. Ключевые моменты:
- prev_request_id: map $http_x_prev_request_id $prev_request_id { default $http_x_prev_request_id; "" ""; }
- trace_request_id: если $http_x_request_id пуст, берём $request_id
- local_request_id = $request_id
- current_hop = "$hop_name:$local_request_id"
- request_hops_chain: через map дописываем current_hop к пришедшей цепочке
- mobile_launch_id и mobile_request_id читаются «как есть» (или пустая строка)

Проброс и возврат заголовков реализованы в rootfs/etc/nginx/conf.d/globals/global_proxy.conf:
- add_header и proxy_set_header для X-Request-ID, X-Request-Chain, X-Prev-Request-ID, X-HOP-Name, X-Mobile-Launch-ID, X-Mobile-Request-ID.


---

## 5. Backend: требования и пример алгоритма

Входящий запрос:
1) raw_prev = X-Prev-Request-ID (или "")
2) raw_trace = X-Request-ID (или "")
3) raw_hops = X-Request-Chain (или "")
4) raw_mobile_launch_id = X-Mobile-Launch-ID (или "")
5) raw_mobile_req_id = X-Mobile-Request-ID (или "")

Далее:
- prev_request_id = raw_prev
- trace_request_id = raw_trace, если пусто — сгенерировать новый 32‑hex
- local_request_id = новый 32‑hex
- hop_name = значение из конфигурации сервиса (например, "backend-api")
- current_hop = hop_name + ":" + local_request_id
- request_hops_chain = raw_hops ? raw_hops + ", " + current_hop : current_hop
- mobile_launch_id = raw_mobile_launch_id; mobile_request_id = raw_mobile_req_id

Исходящие HTTP запросы — выставить заголовки:
- X-HOP-Name = hop_name
- X-Request-ID = trace_request_id
- X-Request-Chain = request_hops_chain
- X-Prev-Request-ID = local_request_id
- X-Mobile-Launch-ID = mobile_launch_id
- X-Mobile-Request-ID = mobile_request_id

---

### 5.1. Backend на PHP: практический пример

Ниже простой, но полноценный пример на PHP, который соответствует инвариантам из разделов выше.

Входящий HTTP (PSR-15 middleware, подходит для Slim/Nyholm, можно адаптировать под Laravel Middleware):
```
<?php

namespace App\Http\Middleware;

use Psr\Http\Message\ServerRequestInterface as Request;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface as Handler;
use Psr\Http\Message\ResponseInterface as Response;

final class TraceMiddleware implements MiddlewareInterface
{
    private string $hopName;

    public function __construct(string $hopName = null)
    {
        $this->hopName = $hopName ?: (getenv('HOP_NAME') ?: 'backend-php');
    }

    private function id32(): string
    {
        return bin2hex(random_bytes(16)); // 32-символьный hex
    }

    public function process(Request $request, Handler $handler): Response
    {
        $rawPrev   = (string)($request->getHeaderLine('X-Prev-Request-ID') ?: '');
        $rawTrace  = (string)($request->getHeaderLine('X-Request-ID') ?: '');
        $rawHops   = (string)($request->getHeaderLine('X-Request-Chain') ?: '');
        $rawMLaunch= (string)($request->getHeaderLine('X-Mobile-Launch-ID') ?: '');
        $rawMReq   = (string)($request->getHeaderLine('X-Mobile-Request-ID') ?: '');

        $traceId   = $rawTrace !== '' ? $rawTrace : $this->id32();
        $localId   = $this->id32();
        $currentHop= $this->hopName . ':' . $localId;
        $hopsChain = $rawHops !== '' ? ($rawHops . ', ' . $currentHop) : $currentHop;

        // Сохраняем в attributes для использования в контроллерах/логгере/клиентах
        $request = $request
            ->withAttribute('trace_request_id', $traceId)
            ->withAttribute('prev_request_id', $rawPrev)
            ->withAttribute('local_request_id', $localId)
            ->withAttribute('hop_name', $this->hopName)
            ->withAttribute('current_hop', $currentHop)
            ->withAttribute('request_hops_chain', $hopsChain)
            ->withAttribute('mobile_launch_id', $rawMLaunch)
            ->withAttribute('mobile_request_id', $rawMReq);

        return $handler->handle($request);
    }
}
```

Исходящие HTTP (Guzzle middleware):
```
<?php

use GuzzleHttp\Client;
use GuzzleHttp\HandlerStack;
use Psr\Http\Message\RequestInterface;

function traced_guzzle_client(array $baseConfig, array $ctx): Client {
    // $ctx: trace_request_id, request_hops_chain, local_request_id, hop_name,
    //      mobile_launch_id, mobile_request_id
    $stack = HandlerStack::create();
    $stack->push(function(callable $handler) use ($ctx) {
        return function(RequestInterface $request, array $options) use ($handler, $ctx) {
            $request = $request
                ->withHeader('X-HOP-Name',        $ctx['hop_name'])
                ->withHeader('X-Request-ID',      $ctx['trace_request_id'])
                ->withHeader('X-Request-Chain',   $ctx['request_hops_chain'])
                ->withHeader('X-Prev-Request-ID', $ctx['local_request_id']) // наш local_id
                ->withHeader('X-Mobile-Launch-ID',$ctx['mobile_launch_id'] ?? '')
                ->withHeader('X-Mobile-Request-ID',$ctx['mobile_request_id'] ?? '');
            return $handler($request, $options);
        };
    });
    $config = $baseConfig + ['handler' => $stack];
    return new Client($config);
}
```

Под Laravel можно повторить логику в HTTP middleware и использовать Guzzle Http::withHeaders(...) или собственный клиент с HandlerStack, как выше.

#### 5.1.1. Laravel (HTTP middleware + исходящие запросы)

Минимальный пример встроенного middleware и использования Http‑клиента.

1) HTTP middleware (app/Http/Middleware/TraceMiddleware.php):
```
<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;

class TraceMiddleware
{
    private string $hopName;

    public function __construct(?string $hopName = null)
    {
        $this->hopName = $hopName ?? (env('HOP_NAME', 'backend-laravel'));
    }

    private function id32(): string
    {
        return bin2hex(random_bytes(16));
    }

    public function handle(Request $request, Closure $next)
    {
        $rawPrev    = (string) $request->header('X-Prev-Request-ID', '');
        $rawTrace   = (string) $request->header('X-Request-ID', '');
        $rawHops    = (string) $request->header('X-Request-Chain', '');
        $rawMLaunch = (string) $request->header('X-Mobile-Launch-ID', '');
        $rawMReq    = (string) $request->header('X-Mobile-Request-ID', '');

        $traceId    = $rawTrace !== '' ? $rawTrace : $this->id32();
        $localId    = $this->id32();
        $currentHop = $this->hopName . ':' . $localId;
        $hopsChain  = $rawHops !== '' ? ($rawHops . ', ' . $currentHop) : $currentHop;

        // Контекст — в контейнере (доступен через app('trace.ctx'))
        $ctx = [
            'trace_request_id'   => $traceId,
            'prev_request_id'    => $rawPrev,
            'local_request_id'   => $localId,
            'hop_name'           => $this->hopName,
            'current_hop'        => $currentHop,
            'request_hops_chain' => $hopsChain,
            'mobile_launch_id'   => $rawMLaunch,
            'mobile_request_id'  => $rawMReq,
        ];
        app()->instance('trace.ctx', $ctx);

        // Передаём дальше по конвейеру
        $response = $next($request);

        // Возвращаем клиенту заголовки (в ответе prev = что пришло сверху)
        $response->headers->set('X-HOP-Name',         $this->hopName);
        $response->headers->set('X-Request-ID',       $traceId);
        $response->headers->set('X-Request-Chain',    $hopsChain);
        $response->headers->set('X-Prev-Request-ID',  $rawPrev);
        $response->headers->set('X-Mobile-Launch-ID', $rawMLaunch);
        $response->headers->set('X-Mobile-Request-ID',$rawMReq);

        return $response;
    }
}
```

Регистрация в Kernel (app/Http/Kernel.php):
```
protected $middleware = [
    // ...
    \App\Http\Middleware\TraceMiddleware::class,
];
// или в группе 'api' / 'web'
```

2) Исходящие HTTP (Laravel Http facade):
```
<?php

use Illuminate\Support\Facades\Http;

$ctx = app('trace.ctx');

$resp = Http::withHeaders([
    'X-HOP-Name'          => $ctx['hop_name'],
    'X-Request-ID'        => $ctx['trace_request_id'],
    'X-Request-Chain'     => $ctx['request_hops_chain'],
    'X-Prev-Request-ID'   => $ctx['local_request_id'],
    'X-Mobile-Launch-ID'  => $ctx['mobile_launch_id'] ?? '',
    'X-Mobile-Request-ID' => $ctx['mobile_request_id'] ?? '',
])->post('https://downstream.local/api', [/* payload */]);
```

Подсказка: можно оформить Http::macro('withTrace', fn($ctx) => Http::withHeaders([...])) и вызывать Http::withTrace(app('trace.ctx'))->get(...).

#### 5.1.2. Yii2 (ActionFilter + исходящие запросы)

1) Фильтр для входящих запросов (components/TraceFilter.php):
```
<?php
namespace app\components;

use Yii;
use yii\base\ActionFilter;

class TraceFilter extends ActionFilter
{
    public string $hopName = 'backend-yii2';

    private function id32(): string
    {
        return bin2hex(random_bytes(16));
    }

    public function beforeAction($action)
    {
        $req = Yii::$app->request;
        $h   = $req->headers;

        $rawPrev    = (string)($h->get('X-Prev-Request-ID', ''));
        $rawTrace   = (string)($h->get('X-Request-ID', ''));
        $rawHops    = (string)($h->get('X-Request-Chain', ''));
        $rawMLaunch = (string)($h->get('X-Mobile-Launch-ID', ''));
        $rawMReq    = (string)($h->get('X-Mobile-Request-ID', ''));

        $traceId    = $rawTrace !== '' ? $rawTrace : $this->id32();
        $localId    = $this->id32();
        $currentHop = $this->hopName . ':' . $localId;
        $hopsChain  = $rawHops !== '' ? ($rawHops . ', ' . $currentHop) : $currentHop;

        Yii::$app->params['trace'] = [
            'trace_request_id'   => $traceId,
            'prev_request_id'    => $rawPrev,
            'local_request_id'   => $localId,
            'hop_name'           => $this->hopName,
            'current_hop'        => $currentHop,
            'request_hops_chain' => $hopsChain,
            'mobile_launch_id'   => $rawMLaunch,
            'mobile_request_id'  => $rawMReq,
        ];

        return parent::beforeAction($action);
    }

    public function afterAction($action, $result)
    {
        $resp = Yii::$app->response;
        $t = Yii::$app->params['trace'] ?? [];

        // Возвращаем клиенту идентификаторы (prev = что пришло сверху)
        $resp->headers->set('X-HOP-Name',          $t['hop_name'] ?? $this->hopName);
        $resp->headers->set('X-Request-ID',        $t['trace_request_id'] ?? '');
        $resp->headers->set('X-Request-Chain',     $t['request_hops_chain'] ?? '');
        $resp->headers->set('X-Prev-Request-ID',   $t['prev_request_id'] ?? '');
        $resp->headers->set('X-Mobile-Launch-ID',  $t['mobile_launch_id'] ?? '');
        $resp->headers->set('X-Mobile-Request-ID', $t['mobile_request_id'] ?? '');

        return parent::afterAction($action, $result);
    }
}
```

Подключение к контроллеру:
```
public function behaviors()
{
    $b = parent::behaviors();
    $b['trace'] = [
        'class' => \app\components\TraceFilter::class,
        'hopName' => getenv('HOP_NAME') ?: 'backend-yii2',
    ];
    return $b;
}
```

Либо глобально в конфиге: 'as trace' => ['class' => app\components\TraceFilter::class, 'hopName' => 'backend-yii2'].

2) Исходящие HTTP (yii\httpclient\Client):
```
<?php
use yii\httpclient\Client;
use Yii;

$t = Yii::$app->params['trace'] ?? [];

$client = new Client();
$response = $client->createRequest()
    ->setMethod('POST')
    ->setUrl('https://downstream.local/api')
    ->addHeaders([
        'X-HOP-Name'          => $t['hop_name'] ?? 'backend-yii2',
        'X-Request-ID'        => $t['trace_request_id'] ?? '',
        'X-Request-Chain'     => $t['request_hops_chain'] ?? '',
        'X-Prev-Request-ID'   => $t['local_request_id'] ?? '',
        'X-Mobile-Launch-ID'  => $t['mobile_launch_id'] ?? '',
        'X-Mobile-Request-ID' => $t['mobile_request_id'] ?? '',
    ])
    ->setData(['foo' => 'bar'])
    ->send();
```

Примечание: формат ID — всегда 32‑символьный hex; prev в исходящем запросе — это ваш local_request_id.

## 6. Frontend: требования и пример алгоритма

- Поддерживайте постоянный trace_request_id в рамках вкладки/сессии.
- На каждый запрос генерируйте local_request_id и дописывайте текущий hop (frontend-web:local_id) к цепочке.
- Отправляйте: X-Request-ID, X-Prev-Request-ID (обычно пусто), X-Request-Chain, при необходимости X-Mobile-*.
- Логируйте всё и отправляйте в Sentry.

---

## 7. Mobile: требования и пример алгоритма

- При старте приложения: mobile_launch_id = новый 32‑hex.
- На каждый HTTP‑вызов: mobile_request_id = новый 32‑hex; hop_name = mobile-ios|mobile-android; current_hop = hop_name:mobile_request_id; цепочка = current_hop (или пришедшая + current_hop).
- Отправляйте заголовки: X-Request-ID, X-Prev-Request-ID (пусто), X-Request-Chain, X-Mobile-Launch-ID, X-Mobile-Request-ID.
- Интеграции: добавляйте эти значения в Sentry/AppMetrica/Google события.

---

### 7.1. Flutter (Android/iOS): пример клиента

Пример обёртки над http.Client, которая автоматически добавляет X-* заголовки и генерирует идентификаторы согласно правилам.

```
// pubspec.yaml: зависимость
// dependencies:
//   http: ^1.1.0

import 'dart:convert';
import 'dart:math';
import 'dart:io' show Platform;
import 'package:http/http.dart' as http;

String id32() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  const hex = '0123456789abcdef';
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(hex[(b >> 4) & 0xF]);
    sb.write(hex[b & 0xF]);
  }
  return sb.toString();
}

class TraceContext {
  TraceContext()
      : mobileLaunchId = id32(),
        hopName = Platform.isAndroid ? 'mobile-android' : (Platform.isIOS ? 'mobile-ios' : 'mobile');

  String? traceRequestId; // живёт всю сессию
  final String mobileLaunchId; // при старте
  final String hopName;        // платформа
}

class TracedClient extends http.BaseClient {
  TracedClient(this._inner, this.ctx);

  final http.Client _inner;
  final TraceContext ctx;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    // Обеспечиваем сквозной trace
    ctx.traceRequestId ??= id32();

    // Генерируем per-request id для мобильного клиента
    final mobileRequestId = id32();
    final currentHop = '${ctx.hopName}:$mobileRequestId';

    // Мы — первый hop, поэтому цепочка = currentHop
    final chain = currentHop;

    request.headers.addAll({
      'X-HOP-Name': ctx.hopName,
      'X-Request-ID': ctx.traceRequestId!,
      'X-Request-Chain': chain,
      'X-Prev-Request-ID': '', // у клиента нет предыдущего hop
      'X-Mobile-Launch-ID': ctx.mobileLaunchId,
      'X-Mobile-Request-ID': mobileRequestId,
    });

    return _inner.send(request);
  }
}

// Использование
// final client = TracedClient(http.Client(), TraceContext());
// final resp = await client.get(Uri.parse('https://api.example.com/ping'));
```

Если вы используете Dio, реализуйте Interceptor, добавляющий те же заголовки в onRequest. Логируйте идентификаторы и передавайте их в Sentry/AppMetrica как теги/поля события.

## 8. Очереди и фоновые задачи

При постановке задач сохраняйте в payload/metadata: trace_request_id, request_hops_chain, mobile_launch_id, mobile_request_id.
При обработке: восстановите значения из сообщения, сгенерируйте свой local_request_id, допишите current_hop в цепочку и продолжайте правила.

---

## 9. Логирование и Sentry/метрики

Каждая запись лога и каждое событие в Sentry должны содержать:
- hop_name
- trace_request_id
- local_request_id
- prev_request_id
- request_hops_chain
- mobile_launch_id
- mobile_request_id

Рекомендации:
- используйте единый middleware/фильтр/интерцептор;
- в Sentry добавляйте поля в tags/extra; в метрики передавайте их как лейблы/теги.

---

## 10. Проверка и отладка

Пример запроса к локальному стенду:
```
curl -i http://localhost/ \
  -H "X-Request-ID: 0123456789abcdef0123456789abcdef" \
  -H "X-Prev-Request-ID: " \
  -H "X-Request-Chain: frontend-web:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  -H "X-Mobile-Launch-ID: " \
  -H "X-Mobile-Request-ID: "
```

Что проверить в ответе:
- X-Request-ID совпадает с вашим или навязан сервером;
- X-Request-Chain содержит ваш hop и hop Nginx (добавился новый элемент);
- X-Prev-Request-ID в ответе отражает prev_request_id (что пришло);
- X-HOP-Name присутствует и равно логическому имени узла.

В логах Nginx убедитесь, что все поля сериализуются (см. global_logging.conf).

---

## 11. Примеры end‑to‑end сценариев

1) Первый запрос мобильного приложения:
- mobile_launch_id = "launch-1111"
- trace_request_id ещё нет → клиент генерирует "trace-aaa"
- mobile_request_id = "mob-req-001"
- hop_name = "mobile-android"
- current_hop = "mobile-android:mob-req-001"
- request_hops_chain = "mobile-android:mob-req-001"
- Заголовки запроса:
  - X-Request-ID = "trace-aaa"
  - X-Prev-Request-ID = ""
  - X-Request-Chain = "mobile-android:mob-req-001"
  - X-Mobile-Launch-ID = "launch-1111"
  - X-Mobile-Request-ID = "mob-req-001"

2) Edge Nginx принимает запрос, формирует свои идентификаторы и цепочку, логирует всё и проксирует в backend.

3) Backend генерирует свой local_request_id, расширяет цепочку, логирует все идентификаторы и при необходимости проксирует дальше, сохраняя мобильные ID.

---

## 12. Частые ошибки и как их избежать

- Неправильное понимание X-Prev-Request-ID. В ответе клиенту — это то, что пришло сверху; в исходящем запросе вниз — всегда ваш local_request_id.
- Случайные форматы идентификаторов (UUID/ULID). Используйте только 32‑символьный hex.
- Потеря мобильных ID на промежуточных слоях. Проксируйте их всегда, даже если значение пустое.
- Отсутствие единого middleware/interceptor. Внедрите общий слой — меньше ошибок и расхождений.

---

## 13. Мини‑FAQ

В: Можно ли генерировать trace_request_id на каждом узле?
О: Нет. Он должен быть сквозным. Генерируйте его только если он отсутствует во входящем запросе.

В: Что писать в X-Prev-Request-ID, если я первый в цепочке?
О: Пустую строку во входящем; в исходящем вниз — свой local_request_id.

В: Что класть в X-HOP-Name?
О: Логическое имя узла/роли (например, api-nginx, backend-orders). Оно помогает читать цепочку.

---

## Приложение A. Генерация 32‑символьного hex ID

JavaScript/TypeScript (Node.js):
```
const crypto = require('crypto');
function id32() { return crypto.randomBytes(16).toString('hex'); }
```

PHP:
```
<?php
function id32(): string { return bin2hex(random_bytes(16)); }
```

Dart (Flutter):
```
import 'dart:math';

String id32() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  const hex = '0123456789abcdef';
  final sb = StringBuffer();
  for (final b in bytes) { sb.write(hex[(b >> 4) & 0xF]); sb.write(hex[b & 0xF]); }
  return sb.toString();
}
```
