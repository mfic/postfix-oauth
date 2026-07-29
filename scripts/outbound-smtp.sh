#!/bin/bash
# Outbound-mode adapter: SMTP submission to smtp.office365.com with XOAUTH2
# (sasl-xoauth2). Every mode adapter implements the same interface:
#
#   setup                        render config, start aux services (once, at boot)
#   token-scope                  print the OAuth scope this mode needs
#   write-token <token> <ttl>    write this mode's token store atomically
#
# TOKEN_FILE can be overridden, e.g. for tests.
set -eu

TOKEN_FILE="${TOKEN_FILE:-/etc/tokens/token}"

case "${1:?usage: outbound-smtp.sh setup|token-scope|write-token}" in

setup)
    : "${RELAY_MAILBOX:?RELAY_MAILBOX is required in smtp mode (the M365 mailbox Postfix authenticates as)}"

    cat >> /etc/postfix/main.cf <<'EOF'
# OUTBOUND_MODE=smtp: deliver via SMTP submission with XOAUTH2 (sasl-xoauth2).
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

    # syslog to container stdout (sasl-xoauth2 logs failures via syslog)
    busybox syslogd -n -O /proc/1/fd/1 &

    cat > /etc/sasl-xoauth2.conf <<EOF
{
  "client_id": "${CLIENT_ID}",
  "client_secret": "${CLIENT_SECRET}",
  "token_endpoint": "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token",
  "log_to_syslog_on_failure": "yes"
}
EOF
    chmod 600 /etc/sasl-xoauth2.conf

    cat > /etc/postfix/sasl_passwd <<EOF
[smtp.office365.com]:587 ${RELAY_MAILBOX}:${TOKEN_FILE}
EOF
    chmod 600 /etc/postfix/sasl_passwd
    postmap hash:/etc/postfix/sasl_passwd
    ;;

token-scope)
    echo "https://outlook.office365.com/.default"
    ;;

write-token)
    umask 077
    expiry=$(( $(date +%s) + ${3:?expires_in} ))
    printf '{"access_token": "%s", "refresh_token": "client_credentials", "expiry": "%s"}\n' \
        "${2:?token}" "$expiry" > "${TOKEN_FILE}.tmp"
    chown postfix:postfix "${TOKEN_FILE}.tmp" 2>/dev/null || true
    mv -f "${TOKEN_FILE}.tmp" "$TOKEN_FILE"
    ;;

*)
    echo "outbound-smtp: unknown command '$1'" >&2
    exit 64
    ;;
esac
