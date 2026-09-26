// Показывает ID текущего запроса: читаем заголовки ответа шлюза.
// Файл — ES-модуль (.mjs): nginx отдаёт его как application/javascript,
// иначе браузер с nosniff отказался бы его выполнять.
const target = document.querySelector('[data-request-id]');

if (target) {
    try {
        const response = await fetch(window.location.pathname, { method: 'HEAD', cache: 'no-store' });
        target.textContent = response.headers.get('X-Request-ID') ?? '—';
    } catch {
        target.textContent = 'недоступен';
    }
}
