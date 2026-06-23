FROM docker.io/serversideup/php:8.4-fpm-nginx-alpine3.21

USER root

# PHP
RUN install-php-extensions imagick gd bcmath

# Raise the PHP upload limits to match the 1GB cap configured in nginx and
# ejabberd mod_http_upload so large media uploads are not rejected at the
# PHP layer before reaching the XMPP HTTP upload service.
RUN printf "upload_max_filesize = 1024M\npost_max_size = 1024M\nmax_execution_time = 600\nmax_input_time = 600\nmemory_limit = 1024M\n" \
    > /usr/local/etc/php/conf.d/movim-uploads.ini

# S6
COPY ./etc/s6-overlay/s6-rc.d/movim-migrations/ /etc/s6-overlay/s6-rc.d/movim-migrations/
COPY ./etc/s6-overlay/s6-rc.d/movim-daemon/ /etc/s6-overlay/s6-rc.d/movim-daemon/
COPY ./etc/s6-overlay/s6-rc.d/tail-log/ /etc/s6-overlay/s6-rc.d/tail-log/
RUN touch /etc/s6-overlay/s6-rc.d/user/contents.d/movim-migrations
RUN touch /etc/s6-overlay/s6-rc.d/user/contents.d/movim-daemon
RUN touch /etc/s6-overlay/s6-rc.d/user/contents.d/tail-log

# nginx websocket
COPY /etc/nginx/conf.d/movim-websocket.conf /etc/nginx/server-opts.d/

# Movim

ENV SSL_MODE=full
ENV PHP_OPCACHE_ENABLE=1
ENV DAEMON_INTERFACE=127.0.0.1
ENV DAEMON_PORT=8083
ENV NGINX_WEBROOT=/var/www/html/public

WORKDIR /var/www/html

# Setup some directories
RUN mkdir cache; \
    chown -R www-data:www-data cache; \
    mkdir log; \
    chown -R www-data:www-data log

# install 3rd party dependencies
COPY composer.lock composer.json .
RUN composer install

COPY .php_cs phinx.php daemon.php VERSION .
COPY config ./config
COPY locales ./locales
COPY public ./public
RUN mkdir -p public/cache; \
    chown -R www-data:www-data public/cache; \
    mkdir public/images; \
    chown -R www-data:www-data public/images
COPY workers ./workers
COPY database ./database
COPY src ./src
COPY app ./app

USER www-data
