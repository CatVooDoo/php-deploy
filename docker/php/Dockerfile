ARG PHP_VERSION=8.4
FROM php:${PHP_VERSION}-fpm-alpine

RUN apk add --no-cache \
    bash \
    curl \
    git \
    unzip \
    nodejs \
    npm \
    shadow \
    oniguruma-dev \
    libzip-dev \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    icu-dev \
    mariadb-client

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install \
        pdo_mysql \
        mbstring \
        zip \
        gd \
        opcache \
        bcmath \
        intl

RUN apk add --no-cache $PHPIZE_DEPS linux-headers \
    && pecl install redis xdebug \
    && docker-php-ext-enable redis xdebug \
    && apk del $PHPIZE_DEPS linux-headers \
    && rm -rf /tmp/pear

COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# ---------------------------------------------------------------------------
# Права на файлы.
#
# В alpine php-fpm работает от www-data (UID 82), а файлы проекта на хосте
# принадлежат вашему пользователю (обычно UID 1000). Из-за этого PHP не может
# писать в примонтированные каталоги: обработчик отрабатывает, но логи, кэш
# и загрузки не создаются — как правило, без единой ошибки в браузере.
#
# Поэтому переносим www-data на UID/GID хоста (make init подставляет их в .env).
# Флаг -o разрешает неуникальные ID — так мы не упрёмся в занятые в образе.
# ---------------------------------------------------------------------------
ARG UID=1000
ARG GID=1000

RUN groupmod -o -g "${GID}" www-data \
    && usermod  -o -u "${UID}" -g "${GID}" www-data \
    && mkdir -p /var/www/html \
    && chown -R www-data:www-data /var/www/html /root/.composer 2>/dev/null || true

WORKDIR /var/www/html
