#!/bin/bash
set -eu

: "${TENANT_ID:?TENANT_ID is required}"
: "${CLIENT_ID:?CLIENT_ID is required}"
: "${CLIENT_SECRET:?CLIENT_SECRET is required}"
: "${RELAY_MAILBOX:?RELAY_MAILBOX is required (the M365 mailbox Postfix authenticates as)}"
POSTFIX_HOSTNAME="${POSTFIX_HOSTNAME:-mailrelay.local}"
PRINTER_NETWORKS="${PRINTER_NETWORKS:-}"

# syslog to container stdout (sasl-xoauth2 logs failures via syslog)
busybox syslogd -n -O /proc/1/fd/1 &

# ---------------------------------------------------------------- TLS cert
# Self-signed cert for STARTTLS on 587 unless one is mounted at /config/tls
if [ -f /config/tls/cert.pem ] && [ -f /config/tls/key.pem ]; then
    cp /config/tls/cert.pem /etc/postfix/cert.pem
    cp /config/tls/key.pem /etc/postfix/key.pem
else
    if [ ! -f /etc/postfix/cert.pem ]; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=${POSTFIX_HOSTNAME}" \
            -keyout /etc/postfix/key.pem -out /etc/postfix/cert.pem 2>/dev/null
    fi
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
# /config/printer_accounts: lines of "username password" -> SASL logins on 587
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

mkdir -p /etc/postfix/sasl
cat > /etc/postfix/sasl/smtpd.conf <<'EOF'
pwcheck_method: auxprop
auxprop_plugin: sasldb
mech_list: PLAIN LOGIN
EOF

# ------------------------------------------------------ outbound OAuth2
cat > /etc/sasl-xoauth2.conf <<EOF
{
  "client_id": "${CLIENT_ID}",
  "client_secret": "${CLIENT_SECRET}",
  "token_endpoint": "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token",
  "log_to_syslog_on_failure": "yes"
}
EOF

mkdir -p /etc/tokens
cat > /etc/postfix/sasl_passwd <<EOF
[smtp.office365.com]:587 ${RELAY_MAILBOX}:/etc/tokens/token
EOF
chmod 600 /etc/postfix/sasl_passwd
postmap hash:/etc/postfix/sasl_passwd

# ------------------------------------------------------------- main.cf
cat > /etc/postfix/main.cf <<EOF
myhostname = ${POSTFIX_HOSTNAME}
mydomain = ${POSTFIX_HOSTNAME#*.}
myorigin = \$myhostname
mydestination =
local_recipient_maps =
local_transport = error:local delivery is disabled
alias_maps =
append_dot_mydomain = no
biff = no
compatibility_level = 3.6
maillog_file = /dev/stdout
smtpd_banner = \$myhostname ESMTP
message_size_limit = 52428800

# who may relay without auth: the printers' fixed IPs
mynetworks = 127.0.0.0/8 [::1]/128 ${PRINTER_NETWORKS}

# inbound (printers -> us)
smtpd_helo_required = yes
smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject
smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject
# sender whitelist applies to EVERYONE, including whitelisted IPs and
# authenticated printers: unknown MAIL FROM -> 550
smtpd_sender_restrictions = check_sender_access hash:/etc/postfix/allowed_senders, reject

# optional username/password auth for printers (sasldb, enabled on 25 and 587)
smtpd_sasl_auth_enable = yes
smtpd_sasl_type = cyrus
smtpd_sasl_path = smtpd
smtpd_sasl_local_domain = \$myhostname
smtpd_sasl_security_options = noanonymous
broken_sasl_auth_clients = yes

# STARTTLS offered but not forced (printers often can't do TLS)
smtpd_tls_security_level = may
smtpd_tls_cert_file = /etc/postfix/cert.pem
smtpd_tls_key_file = /etc/postfix/key.pem
smtpd_tls_auth_only = no

# outbound (us -> Microsoft 365 via XOAUTH2)
relayhost = [smtp.office365.com]:587
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options =
smtp_sasl_mechanism_filter = xoauth2
smtp_tls_security_level = encrypt
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
smtp_tls_loglevel = 1
# M365 rejects mail whose envelope sender isn't the authenticated mailbox or a
# SendAs-permitted address; retry a few times, then bounce back to the printer
smtp_sender_dependent_authentication = no
EOF

# ------------------------------------------------------------- master.cf
# chroot disabled everywhere so sasldb/token files are reachable
cat > /etc/postfix/master.cf <<'EOF'
# service type  private unpriv  chroot  wakeup  maxproc command + args
smtp       inet  n       -       n       -       -       smtpd
submission inet  n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=may
pickup     unix  n       -       n       60      1       pickup
cleanup    unix  n       -       n       -       0       cleanup
qmgr       unix  n       -       n       300     1       qmgr
tlsmgr     unix  -       -       n       1000?   1       tlsmgr
rewrite    unix  -       -       n       -       -       trivial-rewrite
bounce     unix  -       -       n       -       0       bounce
defer      unix  -       -       n       -       0       bounce
trace      unix  -       -       n       -       0       bounce
verify     unix  -       -       n       -       1       verify
flush      unix  n       -       n       1000?   0       flush
proxymap   unix  -       -       n       -       -       proxymap
smtp       unix  -       -       n       -       -       smtp
relay      unix  -       -       n       -       -       smtp
showq      unix  n       -       n       -       -       showq
error      unix  -       -       n       -       -       error
retry      unix  -       -       n       -       -       error
discard    unix  -       -       n       -       -       discard
local      unix  -       n       n       -       -       local
virtual    unix  -       n       n       -       -       virtual
lmtp       unix  -       -       n       -       -       lmtp
anvil      unix  -       -       n       -       1       anvil
scache     unix  -       -       n       -       1       scache
postlog    unix-dgram n  -       n       -       1       postlogd
EOF

# fix up the spool volume ownership on first run
postfix set-permissions >/dev/null 2>&1 || true

echo "Fetching initial access token..."
/usr/local/bin/token-refresher.sh &

# wait for the first token so the queue doesn't start deferring immediately
for _ in $(seq 1 30); do
    [ -s /etc/tokens/token ] && break
    sleep 1
done
[ -s /etc/tokens/token ] || echo "WARNING: no access token yet - check TENANT_ID/CLIENT_ID/CLIENT_SECRET" >&2

exec postfix start-fg
