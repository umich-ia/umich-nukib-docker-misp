# Base image
ARG BASE_IMAGE=quay.io/centos/centos:stream8
FROM $BASE_IMAGE as base

# Some packages requires building, so use different stage for that
FROM base as builder
RUN dnf module enable -y php:7.4 && \
    dnf install -y epel-release && \
    dnf install -y --setopt=tsflags=nodocs --setopt=install_weak_deps=False gcc python39-devel python39-pip python39-wheel php-devel php-mbstring php-json php-xml ssdeep-devel unzip make brotli-devel rpmdevtools yum-utils && \
    useradd --create-home --system --user-group build
# Build su-exec
COPY su-exec.c /tmp/
RUN gcc -Wall -Werror -g -o /usr/local/bin/su-exec /tmp/su-exec.c && \
    chmod u+x /usr/local/bin/su-exec

# Build Python packages
FROM builder as python-build
RUN su-exec build pip3 wheel pydeep -w /tmp/wheels

# Build PHP extensions
FROM builder as php-build
COPY bin/misp_compile_php_extensions.sh /tmp/
RUN chmod u+x /tmp/misp_compile_php_extensions.sh && \
    /tmp/misp_compile_php_extensions.sh

# Build jobber, that is not released for arm64 arch
FROM builder as jobber-build
RUN mkdir /tmp/jobber && \
    cd /tmp/jobber && \
    curl -L https://github.com/dshearer/jobber/archive/refs/tags/v1.4.4.tar.gz | tar zx --strip-components=1 && \
    yum-builddep --assumeyes packaging/rpm/*.spec && \
    make -C packaging/rpm pkg-local "DESTDIR=/tmp/"

# MISP image
FROM base as misp

# Install required system and Python packages
COPY packages /tmp/packages
COPY requirements.txt /tmp/
RUN dnf install -y --setopt=tsflags=nodocs epel-release && \
    dnf module -y enable mod_auth_openidc php:7.4 python39 && \
    dnf install --setopt=tsflags=nodocs --setopt=install_weak_deps=False -y $(grep -vE "^\s*#" /tmp/packages | tr "\n" " ") && \
    alternatives --set python3 /usr/bin/python3.9 && \
    pip3 --no-cache-dir install --disable-pip-version-check -r /tmp/requirements.txt && \
    rm -rf /var/cache/dnf /tmp/packages

ARG MISP_VERSION=develop
ENV MISP_VERSION $MISP_VERSION
ENV GNUPGHOME /var/www/MISP/.gnupg

COPY --from=builder /usr/local/bin/su-exec /usr/local/bin/
COPY --from=python-build /tmp/wheels /wheels
COPY --from=php-build /tmp/php-modules/* /usr/lib64/php/modules/
COPY --from=jobber-build /tmp/jobber*.rpm /tmp
COPY bin/ /usr/local/bin/
COPY misp.conf /etc/httpd/conf.d/misp.conf
COPY httpd-errors/* /var/www/html/
COPY rsyslog.conf /etc/
COPY snuffleupagus-misp.rules /etc/php.d/
COPY .jobber /root/
COPY supervisor.ini /etc/supervisord.d/misp.ini
RUN dnf install -y /tmp/jobber*.rpm && \
    chmod u=rwx,g=rx,o=rx /usr/local/bin/* &&  \
    pip3 install --disable-pip-version-check /wheels/* && \
    /usr/local/bin/misp_install.sh
COPY Config/* /var/www/MISP/app/Config/
RUN chmod u=r,g=r,o=r /var/www/MISP/app/Config/* && \
    chmod 644 /etc/supervisord.d/misp.ini && \
    chmod 644 /etc/rsyslog.conf && \
    chmod 644 /etc/httpd/conf.d/misp.conf && \
    chmod 644 /etc/php.d/snuffleupagus-misp.rules && \
    chmod 644 /root/.jobber && \
    mkdir /run/php-fpm

# Verify image
FROM misp as verify
RUN touch /verified && \
    pip3 install safety && \
    su-exec apache /usr/local/bin/misp_verify.sh

# Final image
FROM misp
# Hack that will force run verify stage
COPY --from=verify /verified /

VOLUME /var/www/MISP/app/tmp/logs/
VOLUME /var/www/MISP/app/files/certs/
VOLUME /var/www/MISP/app/attachments/
VOLUME /var/www/MISP/.gnupg/

WORKDIR /var/www/MISP/
# Web server
EXPOSE 80
# ZeroMQ
EXPOSE 50000
# This is a hack how to go trought mod_auth_openidc
HEALTHCHECK CMD su-exec apache curl -H "Authorization: dummydummydummydummydummydummydummydummy" --fail http://127.0.0.1/fpm-status || exit 1
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisord.conf"]