#!/bin/bash
set -eu

: "${TENANT_ID:?TENANT_ID is required}"
: "${CLIENT_ID:?CLIENT_ID is required}"
: "${CLIENT_SECRET:?CLIENT_SECRET is required}"
export POSTFIX_HOSTNAME="${POSTFIX_HOSTNAME:-mailrelay.local}"
export POSTFIX_DOMAIN="${POSTFIX_HOSTNAME#*.}"

# outbound variant: graph (Graph Mail.Send, default) or smtp (SMTP XOAUTH2).
# Everything mode-specific at boot lives in the matching outbound-<mode>.sh adapter.
OUTBOUND_MODE="${OUTBOUND_MODE:-graph}"
OUTBOUND_ADAPTER="/usr/local/bin/outbound-${OUTBOUND_MODE}.sh"
if [ ! -x "$OUTBOUND_ADAPTER" ]; then
    echo "FATAL: unknown OUTBOUND_MODE '$OUTBOUND_MODE' (no $OUTBOUND_ADAPTER)" >&2
    exit 1
fi
echo "Outbound mode: $OUTBOUND_MODE"

TEMPLATES=/usr/local/share/postfix-relay

# ---------------------------------------------------------------- TLS cert
/usr/local/bin/tls-cert.sh install

# ------------------------------------------------------------ config files
# allowed_senders, client_accounts and trusted_networks. Its FATALs stop the boot.
TRUSTED_NETWORKS=$(/usr/local/bin/config-tables.sh access /config)
export TRUSTED_NETWORKS

# ------------------------------------------------------ oldest TLS version
export TLS_MIN_VERSION="${TLS_MIN_VERSION:-TLSv1.2}"
case "$TLS_MIN_VERSION" in
    TLSv1|TLSv1.1|TLSv1.2|TLSv1.3) ;;
    *)
        echo "FATAL: TLS_MIN_VERSION must be TLSv1, TLSv1.1, TLSv1.2 or TLSv1.3, not '$TLS_MIN_VERSION'." >&2
        exit 1 ;;
esac

# ------------------------------------------------- render config templates
envsubst '${POSTFIX_HOSTNAME} ${POSTFIX_DOMAIN} ${TRUSTED_NETWORKS} ${TLS_MIN_VERSION}' \
    < "$TEMPLATES/main.cf.tmpl" > /etc/postfix/main.cf

# ------------------------------------------- optional per-client mailboxes
# config/client_senders. Changes main.cf, so it comes after the render above.
/usr/local/bin/config-tables.sh client-senders /config

mkdir -p /etc/tokens
"$OUTBOUND_ADAPTER" setup

# fix up the spool volume ownership on first run, then lint the rendered config
postfix set-permissions >/dev/null 2>&1 || true
postfix check

# ------------------------------------------------------------ OAuth token
echo "Fetching initial access token..."
if expires_in=$(/usr/local/bin/fetch-token.sh "$OUTBOUND_MODE"); then
    echo "Initial access token obtained (valid ${expires_in}s)."
else
    echo "WARNING: initial token fetch failed - check TENANT_ID/CLIENT_ID/CLIENT_SECRET." >&2
    echo "WARNING: inbound mail will queue until the refresher obtains a token." >&2
fi
/usr/local/bin/token-refresher.sh "$OUTBOUND_MODE" &
/usr/local/bin/tls-cert.sh watch &

exec postfix start-fg
