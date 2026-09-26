# ngx-trace-gateway — частые команды. `make` или `make help` — список целей.
#
# Дистрибутив берётся из .env (NGX_IMAGE/NGX_BIN), см. .env.example.

# Приоритет как у docker compose: переменная окружения / командной строки,
# затем .env, затем значение по умолчанию. (`include .env` перекрыл бы
# переменные окружения, поэтому .env читается вручную.)
ENV_NGX_IMAGE := $(shell sed -n 's/^NGX_IMAGE=//p' .env 2>/dev/null | tail -n1)
ENV_NGX_BIN   := $(shell sed -n 's/^NGX_BIN=//p' .env 2>/dev/null | tail -n1)
NGX_IMAGE ?= $(or $(ENV_NGX_IMAGE),openresty/openresty:1.31.1.1-bookworm)
NGX_BIN   ?= $(or $(ENV_NGX_BIN),openresty)
export NGX_IMAGE NGX_BIN

# Матрица для test-all: образ=бинарник.
MATRIX := openresty/openresty:1.31.1.1-bookworm=openresty \
          openresty/openresty:1.31.1.1-alpine=openresty \
          nginx:1.30.5=nginx \
          nginx:1.31.6=nginx \
          docker.angie.software/angie:1.12.2=angie

SITE_LINK := rootfs/etc/nginx/sites-enabled/default.conf

# Запрос к служебному серверу 127.0.0.1:8080 изнутри контейнера: в образах
# разный набор утилит (curl / wget / только bash).
define in_container_get
docker compose exec -T gateway sh -c 'curl -fsS http://127.0.0.1:8080$(1) 2>/dev/null \
 || wget -qO- http://127.0.0.1:8080$(1) 2>/dev/null \
 || bash -c "exec 3<>/dev/tcp/127.0.0.1/8080; printf \"GET $(1) HTTP/1.0\r\n\r\n\" >&3; sed \"1,/^\r*$$/d\" <&3"'
endef

.DEFAULT_GOAL := help
.PHONY: help up down restart ps logs check reload status health test test-all lint certs https-on https-off new-site

help: ## Показать список команд
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "} {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

up: ## Запустить шлюз и демо-бэкенд
	docker compose up -d --wait

down: ## Остановить и удалить контейнеры и том кэша
	docker compose down -v --remove-orphans

restart: down up ## Перезапустить с нуля

ps: ## Состояние контейнеров
	docker compose ps

logs: ## JSON-логи шлюза (Ctrl+C — выход)
	docker compose logs -f --no-log-prefix gateway

# Внутри контейнера конфиг используется только так: `<bin> -c /etc/nginx/nginx.conf`.
# Голые `nginx -t` / `nginx -s reload` работают с конфигом самого образа.
check: ## Проверить конфигурацию (nginx -t) в отдельном контейнере
	docker compose run --rm --no-deps -T gateway $(NGX_BIN) -c /etc/nginx/nginx.conf -t -g 'worker_processes 1; pid /run/nginx.pid;'

reload: check ## Проверить и применить конфигурацию без остановки (SIGHUP)
	docker compose kill -s HUP gateway

status: ## stub_status: соединения и запросы
	@$(call in_container_get,/nginx_status)

health: ## /healthz служебного сервера
	@$(call in_container_get,/healthz)

test: ## Smoke-тесты на текущем образе (NGX_IMAGE/NGX_BIN)
	scripts/test.sh

test-all: ## Smoke-тесты на всех поддерживаемых образах
	@set -e; for p in $(MATRIX); do NGX_IMAGE=$${p%=*} NGX_BIN=$${p#*=} scripts/test.sh; done

lint: ## Статические проверки конфигурации и скриптов
	scripts/lint.sh
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck scripts/*.sh; else echo "shellcheck не установлен — пропускаю"; fi

certs: ## Самоподписанный сертификат для localhost в rootfs/etc/nginx/ssl
	scripts/gen-dev-cert.sh

https-on: ## Включить HTTPS для демо-сайта (dev-сертификат, если его нет)
	@[ -f rootfs/etc/nginx/ssl/fullchain.pem ] || scripts/gen-dev-cert.sh
	@printf '# Включённый сайт (HTTPS). Вернуть HTTP: make https-off\ninclude /etc/nginx/sites-available/default/default_https.conf;\n' > $(SITE_LINK)
	@echo "HTTPS включён. Применить: make reload"

https-off: ## Вернуть демо-сайт на HTTP
	@printf '# Включённый сайт. Для HTTPS замените default.conf на default_https.conf.\ninclude /etc/nginx/sites-available/default/default.conf;\n' > $(SITE_LINK)
	@echo "HTTPS выключен. Применить: make reload"

new-site: ## Создать сайт из шаблона: make new-site NAME=shop DOMAIN=shop.example.com UPSTREAM=shop-app:8080
	scripts/new-site.sh "$(NAME)" "$(DOMAIN)" "$(UPSTREAM)"
