FROM debian:trixie-slim AS build

ENV DEBIAN_FRONTEND=noninteractive
ARG SASL_XOAUTH2_VERSION=release-0.27

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates cmake g++ make pkg-config pandoc \
        libcurl4-openssl-dev libjsoncpp-dev libsasl2-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch ${SASL_XOAUTH2_VERSION} \
        https://github.com/tarickb/sasl-xoauth2.git /src \
    && cmake -S /src -B /src/build -DCMAKE_INSTALL_PREFIX=/usr \
    && make -C /src/build -j"$(nproc)" \
    && make -C /src/build install DESTDIR=/out


FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        postfix \
        libsasl2-modules \
        sasl2-bin \
        libcurl4 \
        libjsoncpp26 \
        curl \
        jq \
        gettext-base \
        ca-certificates \
        netcat-openbsd \
        busybox \
        openssl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/ /

COPY postfix/master.cf /etc/postfix/master.cf
COPY postfix/sasl-smtpd.conf /etc/postfix/sasl/smtpd.conf
COPY postfix/main.cf.tmpl postfix/sasl-xoauth2.conf.tmpl /usr/local/share/postfix-relay/
COPY scripts/entrypoint.sh scripts/token-refresher.sh scripts/fetch-token.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/token-refresher.sh /usr/local/bin/fetch-token.sh

EXPOSE 25 587

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
