#!/bin/bash
# Postfix pipe command: delivers one queued message to Microsoft 365 via the
# Graph sendMail API. Called as: graph-send.sh <envelope-sender> <recipient>...
# with the raw MIME message on stdin.
#
# TOKEN_FILE and GRAPH_ENDPOINT can be overridden, e.g. for tests. Postfix
# runs pipe commands with a scrubbed environment, so in the container these
# come from the env file written by outbound-graph.sh.
set -u

[ -f /etc/postfix-relay/graph-send.env ] && . /etc/postfix-relay/graph-send.env

TOKEN_FILE="${TOKEN_FILE:-/etc/tokens/token}"
GRAPH_ENDPOINT="${GRAPH_ENDPOINT:-https://graph.microsoft.com/v1.0}"

sender=$1
shift

msg=$(mktemp)
response=$(mktemp)
auth_header=$(mktemp)
trap 'rm -f "$msg" "$msg.bcc" "$msg.notice" "$msg.bounce" "$response" "$auth_header"' EXIT
cat > "$msg"

# Postfix's own notices have no mailbox to send from: bounces arrive with the
# null sender, which pipe(8) expands to MAILER-DAEMON, and postmaster notices
# with double_bounce_sender. A bounce becomes a plain text notice to
# FAILURE_NOTICE_MAILBOX, sent as FAILURE_NOTICE_SENDER, if those are set.
# Everything else is only logged, since posting it would just fail at Graph;
# postmaster notices can quote printer credentials from the SMTP transcript, so
# they are never mailed. pipe(8) logs command output only on failure, hence exit
# 69; Postfix discards an undeliverable notice without generating another one.
#
# failure-notice.sh is called through bash and by its own directory: pipe(8)'s
# scrubbed PATH doesn't reach it, and it isn't executable in a checkout. Its
# failure defers, so that no broken notice is posted and no bounce is lost.
notice_failed() {
    echo "graph-send: FAILURE NOTICE NOT SENT: failure-notice.sh failed, deferring" >&2
    exit 75
}
failure_notice() { bash "$(dirname "$0")/failure-notice.sh" "$@"; }
# write_notice <failure-notice.sh arguments>: replaces $msg with what it builds
# from the bounce, which stays in $msg.bounce for a second notice.
write_notice() {
    failure_notice "$@" < "$msg.bounce" > "$msg.notice" && mv -f "$msg.notice" "$msg"
}

log_prefix=""
attached=""
case "$sender" in
    MAILER-DAEMON|double-bounce@*)
        details=$(failure_notice details < "$msg") || notice_failed
        if [ "$sender" != MAILER-DAEMON ] || [ -z "${FAILURE_NOTICE_MAILBOX:-}" ]; then
            echo "graph-send: FAILURE NOTICE NOT SENT to $* (no mailbox to send it from): $details" >&2
            exit 69
        fi
        log_prefix="FAILURE NOTICE NOT SENT to $FAILURE_NOTICE_MAILBOX ($details): "
        sender=$FAILURE_NOTICE_SENDER
        set -- "$FAILURE_NOTICE_MAILBOX"
        mv -f "$msg" "$msg.bounce"
        if [ "${FAILURE_NOTICE_ATTACH_MESSAGE:-}" = yes ] && write_notice attached "$sender" "$1"; then
            attached=yes
        else
            write_notice plain "$sender" "$1" || notice_failed
        fi ;;
esac

if ! token=$(cat "$TOKEN_FILE" 2>/dev/null) || [ -z "$token" ]; then
    echo "graph-send: no access token at $TOKEN_FILE, deferring" >&2
    exit 75
fi
# From a file, as any user in the container can read curl's command line
printf 'Authorization: Bearer %s\n' "$token" > "$auth_header"

# Graph delivers to the recipients named in the MIME headers, not to the
# envelope. Envelope recipients missing from To/Cc (e.g. a printer's BCC) are
# put in one explicit Bcc header, which Graph honors and strips. Quoted display
# names and comments are removed first: an address in there is not a recipient.
listed=$(sed '/^\r\{0,1\}$/q' "$msg" | tr -d '\r' \
    | awk 'BEGIN { ORS = " " }
           /^[ \t]/ { if (keep) print; next }
           { keep = (tolower($0) ~ /^(to|cc):/); if (keep) print }' \
    | sed -E 's/"[^"]*"//g; s/\([^)]*\)//g' \
    | grep -oE '[^[:space:]<>,;:]+@[^[:space:]<>,;:]+')
bcc=""
for rcpt in "$@"; do
    printf '%s\n' "$listed" | grep -qixF -- "$rcpt" || bcc="${bcc:+$bcc, }$rcpt"
done
if [ -n "$bcc" ]; then
    {
        printf 'Bcc: %s\r\n' "$bcc"
        awk '!in_body && /^\r?$/ { in_body = 1 }
             !in_body && /^[ \t]/ { if (skip) next }
             !in_body && !/^[ \t]/ { skip = (tolower($0) ~ /^bcc:/); if (skip) next }
             { print }' "$msg"
    } > "$msg.bcc"
    mv -f "$msg.bcc" "$msg"
fi

post_message() {
    status=$(base64 -w0 < "$msg" | curl -s -o "$response" -w '%{http_code}' -X POST \
        "$GRAPH_ENDPOINT/users/$sender/sendMail" \
        -H "@$auth_header" \
        -H "Content-Type: text/plain" \
        --data-binary @-)
}
post_message

# A too-large message is the likeliest failure and also the one whose notice can't
# carry it, so a refused notice goes out once more without the attachment.
case "$status" in
    429) ;;
    4*)
        if [ -n "$attached" ]; then
            write_notice plain "$sender" "$1" "$status" || notice_failed
            post_message
        fi ;;
esac

# Exit codes are Postfix pipe(8) sysexits: 75 = defer and retry, 69 = bounce.
[ "${status#2}" != "$status" ] && exit 0

sizes="message $(wc -c < "$msg") bytes, request $(base64 -w0 < "$msg" | wc -c) bytes"
case "$status" in
    000|429|5*)
        echo "graph-send: ${log_prefix}HTTP $status from Graph, deferring ($sizes): $(cat "$response")" >&2
        exit 75 ;;
    413)
        echo "graph-send: ${log_prefix}MESSAGE TOO LARGE for Graph sendMail, HTTP 413, bouncing ($sizes): $(cat "$response")" >&2
        exit 69 ;;
    *)
        echo "graph-send: ${log_prefix}HTTP $status from Graph, bouncing ($sizes): $(cat "$response")" >&2
        exit 69 ;;
esac
