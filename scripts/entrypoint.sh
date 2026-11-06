#!/bin/bash
set -eu

: "${TENANT_ID:?TENANT_ID is required}"
: "${CLIENT_ID:?CLIENT_ID is required}"
: "${CLIENT_SECRET:?CLIENT_SECRET is required}"
export POSTFIX_HOSTNAME="${POSTFIX_HOSTNAME:-mailrelay.local}"
export POSTFIX_DOMAIN="${POSTFIX_HOSTNAME#*.}"

# outbound variant: graph (Graph Mail.Send, default) or smtp (SMTP XOAUTH2).
# Everything mode-specific lives in the matching outbound-<mode>.sh adapter.
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

# --------------------------------------------------- optional client accounts
# /config/client_accounts: lines of "username password" -> SASL logins
rm -f /etc/sasldb2
if [ -s /config/client_accounts ]; then
    while read -r user pass _; do
        case "$user" in ''|\#*) continue ;; esac
        printf '%s' "$pass" | saslpasswd2 -p -c -u "$POSTFIX_HOSTNAME" "$user"
    done < /config/client_accounts
    chown postfix:sasl /etc/sasldb2 2>/dev/null || chown postfix /etc/sasldb2
    chmod 640 /etc/sasldb2
    echo "Loaded $(sasldblistusers2 | wc -l) SASL client account(s)."
fi

# ------------------------------------------------------- trusted networks
# /config/trusted_networks: one IP or CIDR per line, '#' comments allowed. These
# clients may relay without authentication. Postfix accepts a bad entry at boot
# without complaint, so check each one here.
trusted_networks_fail() {
    echo "FATAL: /config/trusted_networks: $1" >&2
    exit 1
}
TRUSTED_NETWORKS=""
if [ -f /config/trusted_networks ]; then
    check_table=$(mktemp)
    while read -r entry extra || [ -n "${entry:-}" ]; do
        [ -n "$entry" ] || continue
        [ -z "$extra" ] || trusted_networks_fail "expected one IP or CIDR per line, got '$entry $extra'"
        [[ "$entry" =~ ^[0-9]+(\.[0-9]+){3}(/[0-9]+)?$ || "$entry" == *:* ]] \
            || trusted_networks_fail "'$entry' is not an IP or CIDR"
        [[ "$entry" != */0 ]] || trusted_networks_fail "'$entry' would trust every address (open relay)"
        printf '%s OK\n' "$entry" > "$check_table"
        if table_errors=$(postmap -q 0.0.0.0 "cidr:$check_table" 2>&1 | grep -E 'warning|fatal'); then
            trusted_networks_fail "invalid entry '$entry': $table_errors"
        fi
        # mynetworks writes IPv6 addresses in brackets
        case "$entry" in
            *:*/*) entry="[${entry%/*}]/${entry##*/}" ;;
            *:*) entry="[$entry]" ;;
        esac
        TRUSTED_NETWORKS="$TRUSTED_NETWORKS $entry"
    done < <(sed 's/#.*//' /config/trusted_networks | tr -d '\r')
    rm -f "$check_table"
fi
export TRUSTED_NETWORKS
echo "Loaded $(printf '%s' "$TRUSTED_NETWORKS" | wc -w) trusted network(s)."

# ------------------------------------------------- render config templates
envsubst '${POSTFIX_HOSTNAME} ${POSTFIX_DOMAIN} ${TRUSTED_NETWORKS}' \
    < "$TEMPLATES/main.cf.tmpl" > /etc/postfix/main.cf

# ------------------------------------------- optional per-client mailboxes
# /config/client_senders: lines of "<ip-or-cidr|account> <mailbox>". A mapped
# client always sends as its mailbox, whatever it puts in MAIL FROM or From.
# Without entries the policy in main.cf stays untouched. A bad entry is fatal:
# skipping it would silently let that client pick its own sender.
client_senders_fail() {
    echo "FATAL: /config/client_senders: $1" >&2
    exit 1
}
if [ -f /config/client_senders ] && grep -qEv '^\s*(#|$)' /config/client_senders; then
    : > /etc/postfix/client_sender_filter.cidr
    : > /etc/postfix/client_sender_accept.cidr
    : > /etc/postfix/client_sender_filter_accounts
    : > /etc/postfix/client_sender_accept_accounts
    while read -r client mailbox extra || [ -n "${client:-}" ]; do
        case "$client" in ''|\#*) continue ;; esac
        [ -n "$mailbox" ] && [ -z "$extra" ] \
            || client_senders_fail "expected '<ip-or-cidr|account> <mailbox>' for '$client'"
        [[ "$mailbox" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] \
            || client_senders_fail "'$mailbox' is not a mailbox address"
        mailbox=$(printf '%s' "$mailbox" | tr '[:upper:]' '[:lower:]')
        grep -qxF -- "$mailbox OK" /etc/postfix/allowed_senders \
            || client_senders_fail "'$mailbox' (for '$client') is not in allowed_senders"

        if [[ "$client" =~ ^[0-9]+(\.[0-9]+){3}(/[0-9]+)?$ || "$client" == *:* ]]; then
            printf '%s FILTER sender-rewrite:%s\n' "$client" "$mailbox" >> /etc/postfix/client_sender_filter.cidr
            printf '%s OK\n' "$client" >> /etc/postfix/client_sender_accept.cidr
        else
            [ -f /config/client_accounts ] && awk -v u="$client" '$1 == u { found = 1 } END { exit !found }' /config/client_accounts \
                || client_senders_fail "account '$client' is not in client_accounts"
            # smtpd_sasl_local_domain makes Postfix see the login as user@hostname
            printf '%s@%s FILTER sender-rewrite:%s\n' "$client" "$POSTFIX_HOSTNAME" "$mailbox" >> /etc/postfix/client_sender_filter_accounts
            printf '%s@%s OK\n' "$client" "$POSTFIX_HOSTNAME" >> /etc/postfix/client_sender_accept_accounts
        fi
    done < <(tr -d '\r' < /config/client_senders)

    # Postfix only warns about a bad cidr line and then ignores it
    if cidr_errors=$(postmap -q 0.0.0.0 cidr:/etc/postfix/client_sender_filter.cidr 2>&1 | grep -E 'warning|fatal'); then
        client_senders_fail "invalid IP entry: $cidr_errors"
    fi
    postmap hash:/etc/postfix/client_sender_filter_accounts
    postmap hash:/etc/postfix/client_sender_accept_accounts

    # FILTER does not end the restriction list, so a second pass accepts the
    # mapped client. On a double match the last FILTER wins: account over IP.
    postconf -e "smtpd_sender_restrictions = \
check_client_access cidr:/etc/postfix/client_sender_filter.cidr, \
check_sasl_access hash:/etc/postfix/client_sender_filter_accounts, \
check_client_access cidr:/etc/postfix/client_sender_accept.cidr, \
check_sasl_access hash:/etc/postfix/client_sender_accept_accounts, \
check_sender_access hash:/etc/postfix/allowed_senders, reject"
    # one pipe call per message, or Graph would deliver to the header recipients twice
    postconf -e "sender-rewrite_destination_recipient_limit = 1000"
    echo "Loaded $(grep -cEv '^\s*(#|$)' /config/client_senders) client sender mapping(s)."
fi

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
