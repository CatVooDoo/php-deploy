# Docker-окружение для PHP-проектов

Готовый шаблон окружения: **nginx + PHP-FPM + MariaDB + Redis + phpMyAdmin + Mailpit**.
Разворачивается одинаково на локальной машине и на чистом сервере — разница только
в значениях `.env`.

Кода приложения в шаблоне нет: положите свой в `src/`, корень веб-сервера — `src/public/`.

## Состав

| Сервис | Образ | Порт (хост) | Назначение |
|---|---|---|---|
| nginx | `nginx:alpine` | `APP_PORT` (80), `APP_SSL_PORT` (443) | Веб-сервер |
| php | `php:8.4-fpm-alpine` | — | PHP-FPM (+ Xdebug, Redis, GD, intl, OPcache) |
| workspace | тот же образ | — | Контейнер для composer / npm / CLI |
| mariadb | `mariadb:lts` | `127.0.0.1:3306` | База данных |
| redis | `redis:alpine` | `127.0.0.1:6379` | Кэш / очереди |
| phpmyadmin | `phpmyadmin` | `127.0.0.1:8080` | Управление БД |
| mailpit | `axllent/mailpit` | `127.0.0.1:1025`, `127.0.0.1:8025` | Перехват исходящей почты |
| certbot | `certbot/certbot` | — | Выпуск и автопродление TLS-сертификатов (профиль `ssl`) |

Наружу смотрят только **80 и 443**. Служебные сервисы привязаны к `127.0.0.1` —
снаружи недоступны, доступ к ним через SSH-туннель (см. [DEPLOY.md](DEPLOY.md)).

## Быстрый старт

```bash
make setup    # .env + UID/GID хоста + сборка + запуск + права на запись
# затем задайте в .env: COMPOSE_PROJECT_NAME, APP_HOST и пароли БД
```

Или по шагам: `make init` → `make up` → `make fix-perms`.

Открыть:

- Приложение — http://localhost (страница-заглушка проверяет связь с БД и Redis)
- phpMyAdmin — http://localhost:8080
- Mailpit — http://localhost:8025

Стартовая страница `src/public/index.php` — временная: удалите её, когда появится
код приложения.

## Структура

```
.env.example                     эталон настроек, копируется в .env
docker-compose.yaml              описание сервисов
Makefile                         команды (make help)
docker/
  nginx/templates/http/          конфиг без TLS — профиль по умолчанию
  nginx/templates/https/         конфиг с TLS и редиректом на HTTPS
  nginx/certs/                   сертификаты (сюда их кладёт certbot)
  php/Dockerfile                 сборка образа PHP-FPM
  php/conf.d/custom.ini          настройки PHP
  php/conf.d/xdebug.ini          настройки Xdebug
  mariadb/config/my.cnf          настройки MariaDB
  mariadb/init/                  SQL-скрипты первичной инициализации БД
src/                             код приложения
  public/                        корень веб-сервера (document root)
  public/uploads/                загружаемые файлы (доступны на запись)
  storage/logs/                  логи приложения (доступны на запись)
  storage/cache/                 кэш приложения (доступен на запись)
```

## Настройка

Всё конфигурируется через `.env` — правьте только его, файлы сервисов трогать не нужно.
Ключевые переменные:

| Переменная | Назначение |
|---|---|
| `COMPOSE_PROJECT_NAME` | Префикс контейнеров и томов — задайте уникальный для проекта |
| `APP_HOST` | Домен проекта, подставляется в конфиг nginx |
| `APP_PORT` / `APP_SSL_PORT` | Порты nginx на хосте |
| `NGINX_TEMPLATES` | Профиль nginx: `.../templates/http` или `.../templates/https` (переключает `make ssl`) |
| `SSL_EMAIL` | Почта для Let's Encrypt — обязательна для `make ssl` |
| `SSL_DOMAINS` | Домены в сертификате; по умолчанию `APP_HOST` и `www.APP_HOST` |
| `SSL_CERTS_DIR` | Каталог сертификатов; `/etc/letsencrypt`, если они выпущены на хосте |
| `PHP_VERSION` | Версия PHP для сборки образа |
| `UID` / `GID` | Под ними работает php-fpm — от них зависят права на запись (ставит `make init`) |
| `XDEBUG_MODE` | `off` \| `debug` \| `develop` \| `coverage` \| `profile` |
| `DB_*` | Имя базы, пользователь и пароли |
| `UPLOAD_LIMIT` | Лимит загрузки для nginx и phpMyAdmin |

У всех переменных есть безопасные значения по умолчанию, так что окружение
поднимется и без `.env` — но для реальной работы пароли задать обязательно.

### HTTP или HTTPS

По умолчанию включён профиль **http**: работает сразу, сертификаты не нужны —
это режим для локальной разработки и для первого запуска на сервере.

На боевом домене HTTPS включается одной командой:

```bash
# в .env: APP_HOST=example.com и SSL_EMAIL=admin@example.com
make ssl-test    # пробный прогон, не расходует лимиты Let's Encrypt
make ssl         # выпуск сертификата + переключение nginx на HTTPS
```

`make ssl` сам получает сертификат через webroot, переключает `NGINX_TEMPLATES`
на https-профиль и поднимает контейнер автопродления. Certbot работает в Docker —
ставить его на хост не нужно, cron и systemd-таймеры не требуются.

Продление автоматическое: certbot проверяет срок раз в 12 часов, nginx раз в 6 часов
перечитывает конфиг. Вручную — `make ssl-renew`, состояние — `make ssl-status`,
откат на HTTP — `make ssl-disable`. Подробности в [DEPLOY.md](DEPLOY.md).

### База данных

Схему проекта положите в `docker/mariadb/init/` — скрипты оттуда выполнятся при
первом создании базы. Готовый дамп заливается отдельно: `make db-import FILE=dump.sql`.
Подробности — в [docker/mariadb/init/README.md](docker/mariadb/init/README.md).

## Команды

`make help` покажет полный список. Основные:

```bash
make setup                  # первичная установка «под ключ»
make up / down / restart    # управление контейнерами
make check-perms            # диагностика прав на запись
make fix-perms              # выдать php-fpm права на запись
make logs                   # логи всех контейнеров
make ps                     # статус контейнеров
make shell                  # bash в workspace (composer, npm и т.д.)
make composer               # composer install
make mysql                  # консоль MariaDB
make db-dump                # выгрузить базу в dump.sql
make db-import FILE=x.sql   # залить дамп
make ssl                    # выпустить сертификат и включить HTTPS
make ssl-test               # пробный выпуск (staging, без расхода лимитов)
make ssl-renew              # продлить сертификат вручную
make ssl-status             # сроки действия выпущенных сертификатов
make ssl-disable            # вернуться на HTTP
make xdebug-on / xdebug-off # переключить Xdebug
make rebuild                # пересобрать образы без кэша
make clean                  # снести контейнеры вместе с данными БД (спросит подтверждение)
```

## Права на запись

Самая частая проблема при развёртывании на Ubuntu: PHP-обработчик отрабатывает,
но не может создать ни лог, ни загруженный файл — причём часто вообще без ошибки
на странице. Причина всегда одна: **UID процесса PHP не совпадает с владельцем файлов**.
В alpine php-fpm по умолчанию работает от `www-data` с UID 82, а файлы проекта
на сервере принадлежат вам (обычно UID 1000) — и запись в примонтированный
каталог запрещает уже сама файловая система хоста.

Шаблон решает это сам: `make init` записывает ваши `id -u` / `id -g` в `.env`,
а при сборке образа `www-data` переносится на эти UID/GID. В итоге PHP пишет
файлы от вашего пользователя, и вы можете их спокойно редактировать и удалять.

```bash
make check-perms   # от кого работает PHP и куда он может писать
make fix-perms     # создать каталоги и выдать права
```

Стартовая страница показывает то же самое в браузере — включая владельца
и права каталога, если запись не удалась.

Список каталогов задаётся переменной `WRITABLE_DIRS` в начале `Makefile`
(по умолчанию `storage public/uploads`). Для фреймворка добавьте свои,
например `var/cache var/log` для Symfony или `bootstrap/cache` для Laravel.

**Если не помогло:**

| Симптом | Причина и решение |
|---|---|
| `make check-perms` показывает UID 82 | Образ собран со старыми аргументами — `make init && make rebuild` |
| Права выданы, но запись всё равно не идёт | Проверьте, что каталог не попал под `chown root` при деплое: `ls -ln src/storage` |
| Permission denied только на сервере | SELinux (RHEL/Fedora, на Ubuntu редко) — добавьте `:z` к bind-монтированию в `docker-compose.yaml` |
| Ошибок нет, но файла нет | PHP пишет ошибки в лог, а не на страницу: `docker compose logs php` |

## Xdebug

По умолчанию выключен (`XDEBUG_MODE=off` — нулевой оверхед).
Включение: `make xdebug-on`.

Настройки IDE: порт **9003**, IDE key `PHPSTORM`, path mapping `./src` → `/var/www/html`.

## Почта

Исходящие письма перехватывает Mailpit и наружу они **не уходят** — смотрите их
в веб-интерфейсе на порту 8025. Для реальной отправки укажите в `.env` боевой SMTP
(`MAIL_HOST`, `MAIL_PORT`).

## Развёртывание на сервере

См. [DEPLOY.md](DEPLOY.md) — установка Docker, выпуск сертификата, переключение
на HTTPS, автопродление и бэкапы.
