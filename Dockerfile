FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        postfix \
        libsasl2-modules \
        sasl2-bin \
        curl \
        jq \
        gettext-base \
        ca-certificates \
        netcat-openbsd \
        openssl \
    && rm -rf /var/lib/apt/lists/*

COPY postfix/master.cf /etc/postfix/master.cf
COPY postfix/sasl-smtpd.conf /etc/postfix/sasl/smtpd.conf
COPY postfix/main.cf.tmpl /usr/local/share/postfix-relay/
COPY scripts/entrypoint.sh scripts/token-refresher.sh scripts/fetch-token.sh scripts/graph-send.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/token-refresher.sh \
        /usr/local/bin/fetch-token.sh /usr/local/bin/graph-send.sh

EXPOSE 25 587

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
