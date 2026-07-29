#!/bin/bash
set -eu

: "${TENANT_ID:?TENANT_ID is required}"
: "${CLIENT_ID:?CLIENT_ID is required}"
: "${CLIENT_SECRET:?CLIENT_SECRET is required}"
export POSTFIX_HOSTNAME="${POSTFIX_HOSTNAME:-mailrelay.local}"
export POSTFIX_DOMAIN="${POSTFIX_HOSTNAME#*.}"
export PRINTER_NETWORKS="${PRINTER_NETWORKS:-}"

# outbound variant: graph (Graph Mail.Send, default) or smtp (SMTP XOAUTH2)
OUTBOUND_MODE="${OUTBOUND_MODE:-graph}"
case "$OUTBOUND_MODE" in
    graph) ;;
    smtp) : "${RELAY_MAILBOX:?RELAY_MAILBOX is required in smtp mode (the M365 mailbox Postfix authenticates as)}" ;;
    *) echo "FATAL: OUTBOUND_MODE must be 'graph' or 'smtp', got '$OUTBOUND_MODE'" >&2; exit 1 ;;
esac
echo "Outbound mode: $OUTBOUND_MODE"

TEMPLATES=/usr/local/share/postfix-relay

# ---------------------------------------------------------------- TLS cert
# Self-signed cert for STARTTLS unless one is mounted at /config/tls
if [ -f /config/tls/cert.pem ] && [ -f /config/tls/key.pem ]; then
    cp /config/tls/cert.pem /etc/postfix/cert.pem
    cp /config/tls/key.pem /etc/postfix/key.pem
elif [ ! -f /etc/postfix/cert.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=${POSTFIX_HOSTNAME}" \
        -keyout /etc/postfix/key.pem -out /etc/postfix/cert.pem 2>/dev/null
fi
chmod 600 /etc/postfix/key.pem

# ------------------------------------------------------- sender whitelist
# /config/allowed_senders: one address per line, '#' comments allowed.
# Anything not on the list is rejected at MAIL FROM time.
if [ ! -s /config/allowed_senders ]; then
    echo "FATAL: /config/allowed_senders is missing or empty - no sender would be allowed." >&2
    exit 1
fi
grep -Ev '^\s*(#|$)' /config/allowed_senders \
    | awk '{print tolower($1), "OK"}' > /etc/postfix/allowed_senders
postmap hash:/etc/postfix/allowed_senders

# ------------------------------------------- optional per-printer accounts
# /config/printer_accounts: lines of "username password" -> SASL logins
rm -f /etc/sasldb2
if [ -s /config/printer_accounts ]; then
    while read -r user pass _; do
        case "$user" in ''|\#*) continue ;; esac
        printf '%s' "$pass" | saslpasswd2 -p -c -u "$POSTFIX_HOSTNAME" "$user"
    done < /config/printer_accounts
    chown postfix:sasl /etc/sasldb2 2>/dev/null || chown postfix /etc/sasldb2
    chmod 640 /etc/sasldb2
    echo "Loaded $(sasldblistusers2 | wc -l) printer SASL account(s)."
fi

# ------------------------------------------------- render config templates
envsubst '${POSTFIX_HOSTNAME} ${POSTFIX_DOMAIN} ${PRINTER_NETWORKS}' \
    < "$TEMPLATES/main.cf.tmpl" > /etc/postfix/main.cf
cat "$TEMPLATES/outbound-${OUTBOUND_MODE}.cf" >> /etc/postfix/main.cf

mkdir -p /etc/tokens
if [ "$OUTBOUND_MODE" = smtp ]; then
    # syslog to container stdout (sasl-xoauth2 logs failures via syslog)
    busybox syslogd -n -O /proc/1/fd/1 &

    envsubst '${TENANT_ID} ${CLIENT_ID} ${CLIENT_SECRET}' \
        < "$TEMPLATES/sasl-xoauth2.conf.tmpl" > /etc/sasl-xoauth2.conf
    chmod 600 /etc/sasl-xoauth2.conf

    cat > /etc/postfix/sasl_passwd <<EOF
[smtp.office365.com]:587 ${RELAY_MAILBOX}:/etc/tokens/token
EOF
    chmod 600 /etc/postfix/sasl_passwd
    postmap hash:/etc/postfix/sasl_passwd

    export TOKEN_SCOPE=https://outlook.office365.com/.default
    export TOKEN_FORMAT=sasl-xoauth2
else
    # Postfix scrubs the environment of pipe(8) commands, so graph-send.sh
    # reads its settings from this file (GRAPH_ENDPOINT overridable for tests).
    mkdir -p /etc/postfix-relay
    cat > /etc/postfix-relay/graph-send.env <<EOF
GRAPH_ENDPOINT=${GRAPH_ENDPOINT:-https://graph.microsoft.com/v1.0}
TOKEN_FILE=/etc/tokens/token
EOF

    export TOKEN_SCOPE=https://graph.microsoft.com/.default
    export TOKEN_FORMAT=raw
fi

# fix up the spool volume ownership on first run, then lint the rendered config
postfix set-permissions >/dev/null 2>&1 || true
postfix check

# ------------------------------------------------------------ OAuth token
echo "Fetching initial access token..."
if expires_in=$(/usr/local/bin/fetch-token.sh); then
    echo "Initial access token obtained (valid ${expires_in}s)."
else
    echo "WARNING: initial token fetch failed - check TENANT_ID/CLIENT_ID/CLIENT_SECRET." >&2
    echo "WARNING: inbound mail will queue until the refresher obtains a token." >&2
fi
/usr/local/bin/token-refresher.sh &

exec postfix start-fg
