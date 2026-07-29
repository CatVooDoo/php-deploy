# Развёртывание на сервере

Инструкция для чистого сервера (Debian/Ubuntu). Итог: приложение работает по HTTPS,
наружу открыты только порты 80 и 443, служебные сервисы — через SSH-туннель.

Ниже `example.com` — ваш домен, `/var/www/app` — каталог проекта на сервере.

## 1. Подготовка сервера

DNS домена (`example.com` и `www.example.com`) должен указывать A-записью на IP сервера —
без этого сертификат не выпустится.

Установка Docker:

```bash
curl -fsSL https://get.docker.com | sh
docker --version && docker compose version
```

Файрвол:

```bash
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable
```

Порты БД, phpMyAdmin и Mailpit открывать **не нужно** — они слушают только `127.0.0.1`.

## 2. Загрузка проекта

```bash
mkdir -p /var/www/app
# затем залейте содержимое шаблона, например:
#   rsync -av --exclude '.git' ./ user@server:/var/www/app/
cd /var/www/app
```

## 3. Настройка .env

```bash
make init                 # создаст .env и пропишет в него UID/GID вашего пользователя
openssl rand -base64 24   # сгенерируйте пароли (по одному на каждый DB_*)
```

Команду выполняйте **от того пользователя, под которым лежат файлы проекта**
(не через `sudo`) — от его UID будет работать php-fpm, и от этого зависят права
на запись логов и загрузок.

Заполните в `.env`:

```ini
COMPOSE_PROJECT_NAME=app         # уникальное имя проекта
APP_ENV=production
APP_HOST=example.com

DB_DATABASE=app
DB_USERNAME=app
DB_PASSWORD=<сгенерированный пароль>
DB_ROOT_PASSWORD=<другой сгенерированный пароль>

NGINX_TEMPLATES=./docker/nginx/templates/http   # пока http — сертификата ещё нет
```

Пароли задайте до первого запуска: MariaDB создаёт пользователя один раз,
при создании тома. Менять их потом — только через SQL или пересоздание тома.

## 4. Первый запуск (HTTP)

```bash
docker compose up -d --build
docker compose ps          # все контейнеры должны быть Up
make fix-perms             # права на запись для логов и загрузок
```

Проверьте: `http://example.com` открывается. Стартовая страница шаблона покажет
состояние MariaDB, Redis и прав на запись — если что-то красное, чините до перехода
к HTTPS.

## 5. HTTPS: сертификат Let's Encrypt

Certbot работает в контейнере — ставить его на хост не нужно. Укажите в `.env`:

```ini
SSL_EMAIL=admin@example.com     # обязателен, сюда придут письма об истечении
#SSL_DOMAINS=example.com,www.example.com   # по умолчанию APP_HOST и www.APP_HOST
```

Сначала пробный прогон — он проверяет DNS и доступность порта 80, но не расходует
лимиты Let's Encrypt (5 неудачных попыток в час на домен):

```bash
make ssl-test
```

Если проверка прошла — боевой выпуск:

```bash
make ssl
```

Одна команда делает всё: временно переводит nginx на HTTP-профиль, получает
сертификат через webroot (`/.well-known/acme-challenge/` в `src/public`),
переключает nginx на HTTPS-профиль и поднимает контейнер автопродления.
Останавливать nginx не требуется — сайт продолжает работать.

Проверьте: `https://example.com` открывается, `http://` редиректит на `https://`.

## 6. Продление сертификата

Автоматическое: контейнер `certbot` проверяет срок раз в 12 часов и продлевает
сертификат за 30 дней до истечения; nginx раз в 6 часов перечитывает конфиг
и подхватывает новый файл. Ничего настраивать не нужно — ни cron, ни systemd-таймеров.

Полезные команды:

```bash
make ssl-status    # какие сертификаты выпущены и до какого числа действуют
make ssl-renew     # продлить прямо сейчас и перечитать конфиг nginx
docker compose logs certbot   # что делал автопродлеватель
```

Контейнер `certbot` запускается только с профилем `ssl` — его включает `make ssl`,
записывая `COMPOSE_PROFILES=ssl` в `.env`. Поэтому последующие `make up` поднимают
автопродление вместе с остальными сервисами.

Вернуться на HTTP (например, при смене домена): `make ssl-disable`.

### Если сертификат уже выпущен на хосте

Когда certbot стоял на сервере раньше и сертификаты лежат в `/etc/letsencrypt`,
выпускать заново не нужно — просто укажите путь в `.env`:

```ini
SSL_CERTS_DIR=/etc/letsencrypt
NGINX_TEMPLATES=./docker/nginx/templates/https
```

```bash
docker compose up -d nginx
```

Продление в этом случае остаётся за хостовым certbot. Проследите, чтобы он
использовал метод `webroot` (`-w /var/www/app/src/public`), а не `standalone`:
80-й порт занят nginx, и standalone-продление на нём упадёт.

### Если nginx не стартует

Почти всегда причина — отсутствующий сертификат по пути
`/etc/letsencrypt/live/${APP_HOST}/fullchain.pem` внутри контейнера.
Смотрите `docker compose logs nginx`, при необходимости откатитесь
на HTTP через `make ssl-disable`.

## 7. Права на запись

Классическая проблема на Ubuntu: обработчик отрабатывает, но PHP не может
создать ни лог, ни загруженный файл — часто вообще без ошибки на странице.
Причина в несовпадении UID: в alpine php-fpm работает от `www-data` (UID 82),
а файлы проекта принадлежат вашему пользователю.

Шаблон закрывает это автоматически — `make init` (или `make setup`) прописывает
в `.env` ваши `id -u` / `id -g`, и при сборке образа `www-data` переносится
на них. Отдельно ничего делать не нужно, достаточно проверить:

```bash
make check-perms   # покажет UID PHP и статус каждого каталога
make fix-perms     # если где-то нет записи
```

Каталоги задаются переменной `WRITABLE_DIRS` в `Makefile`
(по умолчанию `storage public/uploads`) — добавьте туда пути своего фреймворка.

Важно: если вы залили проект на сервер под `root` (`rsync` от root, распаковка
архива sudo), файлы окажутся с владельцем `root`, и `make fix-perms` вернёт всё
на место. Разбор остальных случаев — в разделе «Права на запись» в [README.md](README.md).

## 8. База данных

Схема из `docker/mariadb/init/` применяется автоматически при первом создании тома.
Готовый дамп:

```bash
make db-import FILE=dump.sql
```

## Служебные интерфейсы

Наружу они не смотрят. Доступ с локальной машины — через SSH-туннель:

```bash
ssh -L 8080:127.0.0.1:8080 -L 8025:127.0.0.1:8025 user@example.com
```

- phpMyAdmin — http://localhost:8080
- Mailpit — http://localhost:8025

## Обновление приложения

```bash
cd /var/www/app
git pull                       # или rsync новой версии
docker compose exec workspace composer install --no-dev -o
docker compose up -d --build   # если менялся Dockerfile или .env
```

OPcache перечитывает изменившиеся файлы раз в 2 секунды — сбрасывать вручную не нужно.

## Бэкапы

```bash
# База (положите в cron)
docker compose exec -T mariadb mariadb-dump -u$DB_USERNAME -p$DB_PASSWORD $DB_DATABASE \
  | gzip > /backup/db-$(date +%F).sql.gz

# Загруженные файлы
tar czf /backup/uploads-$(date +%F).tar.gz -C /var/www/app/src/public uploads
```

Проверяйте восстановление из бэкапа хотя бы раз: непроверенный бэкап бэкапом не является.

## Чеклист безопасности

- [ ] Пароли `DB_PASSWORD` и `DB_ROOT_PASSWORD` — случайные, не из `.env.example`
- [ ] `.env` не попал в репозиторий (он в `.gitignore`)
- [ ] Файрвол открывает только 22, 80, 443
- [ ] Порт 3306 наружу не проброшен (проверьте `docker compose ps`)
- [ ] `APP_ENV=production`, `XDEBUG_MODE=off`
- [ ] HTTPS работает, `make ssl-status` показывает актуальный сертификат
- [ ] Из `src/public/` удалены отладочные и служебные скрипты — файлы там доступны по прямому URL
- [ ] `MAIL_HOST` указывает на боевой SMTP, если приложение реально шлёт почту
