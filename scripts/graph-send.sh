#!/bin/bash
# Postfix pipe command: delivers one queued message to Microsoft 365 via the
# Graph sendMail API. Called as: graph-send.sh <envelope-sender> <recipient>...
# with the raw MIME message on stdin.
#
# TOKEN_FILE and GRAPH_ENDPOINT can be overridden, e.g. for tests. Postfix
# runs pipe commands with a scrubbed environment, so in the container these
# come from the env file rendered by entrypoint.sh.
set -u

[ -f /etc/postfix-relay/graph-send.env ] && . /etc/postfix-relay/graph-send.env

TOKEN_FILE="${TOKEN_FILE:-/etc/tokens/token}"
GRAPH_ENDPOINT="${GRAPH_ENDPOINT:-https://graph.microsoft.com/v1.0}"

sender=$1
shift

msg=$(mktemp)
response=$(mktemp)
trap 'rm -f "$msg" "$msg.bcc" "$msg.notice" "$response"' EXIT
cat > "$msg"

# Postfix's own notices have no mailbox to send from: bounces arrive with the
# null sender, which pipe(8) expands to MAILER-DAEMON, and postmaster notices
# with double_bounce_sender. A bounce becomes a plain text notice to
# FAILURE_NOTICE_MAILBOX, sent as FAILURE_NOTICE_SENDER, if those are set. Everything else is only logged, since
# posting it would just fail at Graph; postmaster notices can quote printer
# credentials from the SMTP transcript, so they are never mailed. pipe(8) logs
# command output only on failure, hence exit 69; Postfix discards an
# undeliverable notice without generating another one.
log_prefix=""
case "$sender" in
    MAILER-DAEMON|double-bounce@*)
        # Only the delivery-status part and the failed message's headers are read,
        # so nothing from the message's content can reach the log or the notice.
        report=$(tr -d '\r' < "$msg" | awk '
            /^Content-Type: message\/delivery-status/ { inside = 1; next }
            inside && /^--/ { exit }
            inside && /^[ \t]/ { sub(/^[ \t]+/, " "); line = line $0; next }
            inside { if (line != "") print line; line = $0 }
            END { if (line != "") print line }')
        failed=$(printf '%s\n' "$report" | sed -n 's/^Final-Recipient: *rfc822; *//p' | paste -sd, -)
        original=$(printf '%s\n' "$report" | sed -n 's/^X-Postfix-Queue-ID: *//p' | head -n 1)
        details="original message ${original:-unknown}, failed recipients ${failed:-unknown}"
        if [ "$sender" != MAILER-DAEMON ] || [ -z "${FAILURE_NOTICE_MAILBOX:-}" ]; then
            echo "graph-send: FAILURE NOTICE NOT SENT to $* (no mailbox to send it from): $details" >&2
            exit 69
        fi
        log_prefix="FAILURE NOTICE NOT SENT to $FAILURE_NOTICE_MAILBOX ($details): "
        sender=$FAILURE_NOTICE_SENDER
        set -- "$FAILURE_NOTICE_MAILBOX"

        # Plain text, because Graph accepts a multipart/report with a 2xx but Exchange
        # does not deliver it (tested live). Graph takes sender and recipients from
        # these headers.
        original_sender=$(printf '%s\n' "$report" | sed -n 's/^X-Postfix-Sender: *rfc822; *//p' | head -n 1)
        original_subject=$(tr -d '\r' < "$msg" | awk '
            /^Content-Type: (message\/rfc822|text\/rfc822-headers)/ { part = 1; next }
            part == 1 && /^$/ { part = 2; next }
            part == 2 && /^$/ { exit }
            part == 2 && /^[ \t]/ { if (found) { sub(/^[ \t]+/, " "); subject = subject $0 } next }
            part == 2 { found = (tolower($0) ~ /^subject:/); if (found) subject = substr($0, 9) }
            END { sub(/^[ \t]+/, "", subject); print subject }')
        {
            tr -d '\r' < "$msg" | sed '/^$/q' | grep -iE '^(date|message-id):'
            printf 'From: %s\nTo: %s\n' "$sender" "$1"
            printf 'Subject: Mail relay: delivery failed (%s)\n' "${original:-unknown}"
            printf 'Auto-Submitted: auto-replied\nMIME-Version: 1.0\n'
            printf 'Content-Type: text/plain; charset=utf-8\n\n'
            printf 'A message sent through the mail relay could not be delivered, and the\n'
            printf 'relay will not retry it.\n\n'
            printf 'Queue ID: %s\n' "${original:-unknown}"
            printf 'Sender:   %s\n' "${original_sender:-unknown}"
            printf 'Subject:  %s\n\n' "${original_subject:-unknown}"
            printf '%s\n' "$report" | awk '
                /^Final-Recipient:/ { sub(/^[^;]*; */, ""); print "Recipient: " $0 }
                /^Status:/ { sub(/^[^:]*: */, ""); print "Status:    " $0 }
                /^Diagnostic-Code:/ { sub(/^[^;]*; */, ""); print "Reason:    " $0; print "" }'
            printf "The message's content is not included. The relay's log has more under the\n"
            printf 'queue ID.\n'
        } > "$msg.notice"
        mv -f "$msg.notice" "$msg" ;;
esac

if ! token=$(cat "$TOKEN_FILE" 2>/dev/null) || [ -z "$token" ]; then
    echo "graph-send: no access token at $TOKEN_FILE, deferring" >&2
    exit 75
fi

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

status=$(base64 -w0 < "$msg" | curl -s -o "$response" -w '%{http_code}' -X POST \
    "$GRAPH_ENDPOINT/users/$sender/sendMail" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: text/plain" \
    --data-binary @-)

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
