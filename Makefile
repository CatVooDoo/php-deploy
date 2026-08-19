.DEFAULT_GOAL := help

# Переменные из .env нужны целям mysql / db-* — подтягиваем, если файл есть.
-include .env
export

DB_USERNAME ?= app
DB_PASSWORD ?= app
DB_DATABASE ?= app
APP_HOST    ?= localhost

# Домены для сертификата: по умолчанию сам домен и www-поддомен.
# Переопределяется переменной SSL_DOMAINS в .env (через запятую или пробел).
SSL_DOMAINS ?= $(APP_HOST) www.$(APP_HOST)

comma := ,
empty :=
space := $(empty) $(empty)
CERTBOT_DOMAINS = $(foreach d,$(subst $(comma),$(space),$(SSL_DOMAINS)),-d $(d))
CERTBOT = docker compose run --rm --entrypoint certbot certbot

# UID/GID текущего пользователя — под ними внутри контейнера работает php-fpm.
HOST_UID := $(shell id -u 2>/dev/null || echo 1000)
HOST_GID := $(shell id -g 2>/dev/null || echo 1000)

# Каталоги, в которые приложению нужно писать (пути относительно src/).
# Дополните списком своего фреймворка, например: storage public/uploads var/cache
WRITABLE_DIRS ?= storage public/uploads

# Записать переменную в .env: заменить строку или добавить, если её нет.
define set_env
	@if grep -q '^$(1)=' .env; then sed -i.bak 's|^$(1)=.*|$(1)=$(2)|' .env && rm -f .env.bak; \
	else printf '$(1)=$(2)\n' >> .env; fi
endef

.PHONY: help init setup up down restart build rebuild ps logs shell php composer \
        mysql db-dump db-import redis-cli xdebug-on xdebug-off clean \
        ssl ssl-ip-addr ssl-test ssl-renew ssl-status ssl-enable ssl-disable \
        fix-perms check-perms

help: ## Показать список команд
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

init: ## Создать .env из .env.example и прописать UID/GID хоста
	@test -f .env || (cp .env.example .env && echo ".env создан — задайте в нём пароли БД")
	$(call set_env,UID,$(HOST_UID))
	$(call set_env,GID,$(HOST_GID))
	@echo "php-fpm будет работать от UID=$(HOST_UID) GID=$(HOST_GID) — как ваш пользователь."

setup: ## Полная первичная установка: .env, сборка, запуск, права
	@$(MAKE) --no-print-directory init
	docker compose up -d --build
	@$(MAKE) --no-print-directory fix-perms
	@echo "Готово. Откройте http://localhost — страница покажет статус окружения."

up: ## Запустить все контейнеры
	docker compose up -d

down: ## Остановить и удалить контейнеры
	docker compose down

restart: ## Перезапустить контейнеры
	docker compose restart

build: ## Собрать образы
	docker compose build

rebuild: ## Пересобрать образы без кэша и перезапустить
	docker compose build --no-cache
	docker compose up -d --force-recreate

ps: ## Статус контейнеров
	docker compose ps

logs: ## Логи всех контейнеров (follow)
	docker compose logs -f

shell: ## Bash в workspace-контейнере
	docker compose exec workspace bash

php: ## Sh в php-fpm контейнере
	docker compose exec php sh

composer: ## Composer install в workspace
	docker compose exec workspace composer install

mysql: ## Консоль MariaDB
	docker compose exec mariadb mariadb -u$(DB_USERNAME) -p$(DB_PASSWORD) $(DB_DATABASE)

db-dump: ## Выгрузить базу в dump.sql
	docker compose exec -T mariadb mariadb-dump -u$(DB_USERNAME) -p$(DB_PASSWORD) $(DB_DATABASE) > dump.sql
	@echo "База выгружена в dump.sql"

db-import: ## Импорт дампа: make db-import FILE=dump.sql
	@test -n "$(FILE)" || (echo "Укажите файл: make db-import FILE=dump.sql" && exit 1)
	docker compose exec -T mariadb mariadb -u$(DB_USERNAME) -p$(DB_PASSWORD) $(DB_DATABASE) < $(FILE)
	@echo "Импортировано из $(FILE)"

redis-cli: ## Консоль Redis
	docker compose exec redis redis-cli

xdebug-on: ## Включить Xdebug (XDEBUG_MODE=debug) и перезапустить php
	sed -i.bak 's/^XDEBUG_MODE=.*/XDEBUG_MODE=debug/' .env && rm -f .env.bak
	docker compose up -d php workspace

xdebug-off: ## Выключить Xdebug и перезапустить php
	sed -i.bak 's/^XDEBUG_MODE=.*/XDEBUG_MODE=off/' .env && rm -f .env.bak
	docker compose up -d php workspace

fix-perms: ## Выдать php-fpm права на запись в каталоги из WRITABLE_DIRS
	docker compose exec -u root php sh -c 'cd /var/www/html \
		&& mkdir -p $(WRITABLE_DIRS) \
		&& chown -R www-data:www-data $(WRITABLE_DIRS) \
		&& chmod -R u+rwX,g+rwX $(WRITABLE_DIRS)'
	@echo "Права выданы: $(WRITABLE_DIRS)"
	@$(MAKE) --no-print-directory check-perms

check-perms: ## Проверить, от кого работает PHP и куда он может писать
	@docker compose exec -u root php sh -c 'echo "PHP-воркеры работают от www-data = UID $$(id -u www-data), GID $$(id -g www-data)"'
	@docker compose exec -u www-data php sh -c 'cd /var/www/html; \
		for d in $(WRITABLE_DIRS); do \
			if [ -w "$$d" ]; then echo "  [ok]   $$d — запись доступна"; \
			else echo "  [FAIL] $$d — записи НЕТ (make fix-perms)"; fi; \
		done'

ssl: ## Выпустить сертификат Let's Encrypt и включить HTTPS
	@test -f .env || (echo "Нет .env — сначала make init" && exit 1)
	@test -n "$(SSL_EMAIL)" || (echo "Задайте SSL_EMAIL в .env" && exit 1)
	@test "$(APP_HOST)" != "localhost" || (echo "APP_HOST=localhost — укажите в .env реальный домен" && exit 1)
	@echo "==> Выпуск сертификата для: $(SSL_DOMAINS)"
	@echo "    Домены должны A-записью указывать на этот сервер, порт 80 открыт."
	$(call set_env,NGINX_TEMPLATES,./docker/nginx/templates/http)
	docker compose up -d nginx
	$(CERTBOT) certonly --webroot -w /var/www/html/public \
		$(CERTBOT_DOMAINS) --email $(SSL_EMAIL) --agree-tos --no-eff-email -n
	@$(MAKE) --no-print-directory ssl-enable

ssl-ip-addr: ## Выпустить Let's Encrypt сертификат для IP и включить HTTPS
	@test -f .env || (echo "Нет .env — сначала make init" && exit 1)
	@test -n "$(SSL_EMAIL)" || (echo "Задайте SSL_EMAIL в .env" && exit 1)
	@test "$(APP_HOST)" != "localhost" || (echo "APP_HOST=localhost — укажите IP сервера в .env" && exit 1)
	@echo "==> Выпуск IP-сертификата для: $(APP_HOST)"
	@echo "    Используется Let's Encrypt shortlived profile."
	$(call set_env,NGINX_TEMPLATES,./docker/nginx/templates/http)
	docker compose up -d nginx
	$(CERTBOT) certonly --webroot -w /var/www/html/public \
		--preferred-profile shortlived \
		--ip-address $(APP_HOST) \
		--email $(SSL_EMAIL) \
		--agree-tos --no-eff-email -n
	@$(MAKE) --no-print-directory ssl-enable

ssl-test: ## Пробный выпуск через staging-сервер (не тратит лимиты Let's Encrypt)
	@test -f .env || (echo "Нет .env — сначала make init" && exit 1)
	@test -n "$(SSL_EMAIL)" || (echo "Задайте SSL_EMAIL в .env" && exit 1)
	$(call set_env,NGINX_TEMPLATES,./docker/nginx/templates/http)
	docker compose up -d nginx
	$(CERTBOT) certonly --webroot -w /var/www/html/public \
		$(CERTBOT_DOMAINS) --email $(SSL_EMAIL) --agree-tos --no-eff-email -n --dry-run
	@echo "Проверка прошла. Боевой выпуск: make ssl"

ssl-enable: ## Переключить nginx на HTTPS и запустить автопродление
	$(call set_env,NGINX_TEMPLATES,./docker/nginx/templates/https)
	$(call set_env,COMPOSE_PROFILES,ssl)
	docker compose --profile ssl up -d nginx certbot
	@echo "HTTPS включён. Проверьте: https://$(APP_HOST)"

ssl-disable: ## Вернуть nginx на HTTP и остановить автопродление
	$(call set_env,NGINX_TEMPLATES,./docker/nginx/templates/http)
	$(call set_env,COMPOSE_PROFILES,)
	docker compose stop certbot || true
	docker compose up -d nginx
	@echo "HTTPS выключен, работает HTTP."

ssl-renew: ## Продлить сертификат вручную и перечитать конфиг nginx
	$(CERTBOT) renew --webroot -w /var/www/html/public
	docker compose exec nginx nginx -s reload
	@echo "Продление выполнено."

ssl-status: ## Показать выпущенные сертификаты и сроки их действия
	@$(CERTBOT) certificates

clean: ## Остановить контейнеры и УДАЛИТЬ тома (данные БД будут потеряны)
	@printf "Удалить контейнеры вместе с данными БД? [y/N] " && read ans && [ "$$ans" = "y" ]
	docker compose down -v
