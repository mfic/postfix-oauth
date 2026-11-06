#!/bin/bash
# Graph mode: finds out which scan sizes Microsoft accepts. Sends one REAL mail
# per size straight through graph-send.sh, bypassing the Postfix queue, so a
# rejection shows up here instead of as a bounce.
#
#   graph-size-test.sh <sender-mailbox> <recipient> [attachment-MB ...]
#
# Sizes are attachment MB and default to 3 5 10. The attachment is base64-encoded
# in the MIME message, and the whole message is base64-encoded again for Graph,
# so the request is about 1.8x the attachment. Exits 0 only if every size is
# accepted. An accepted request is not proof of delivery: check the mailbox too.
#
# GRAPH_SEND can be overridden for tests.
set -u

GRAPH_SEND="${GRAPH_SEND:-/usr/local/bin/graph-send.sh}"

if [ "$#" -lt 2 ]; then
    echo "usage: graph-size-test.sh <sender-mailbox> <recipient> [attachment-MB ...]" >&2
    exit 64
fi
sender=$1
recipient=$2
shift 2
[ "$#" -gt 0 ] || set -- 3 5 10

msg=$(mktemp)
trap 'rm -f "$msg"' EXIT

failed=0
for mb in "$@"; do
    case "$mb" in
        ''|*[!0-9]*) echo "attachment size must be whole MB, got '$mb'" >&2; exit 64 ;;
    esac
    {
        printf 'From: %s\r\nTo: %s\r\n' "$sender" "$recipient"
        printf 'Subject: relay size test: %s MB attachment\r\n' "$mb"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: application/octet-stream; name="size-test.bin"\r\n'
        printf 'Content-Disposition: attachment; filename="size-test.bin"\r\n'
        printf 'Content-Transfer-Encoding: base64\r\n\r\n'
        head -c "$((mb * 1024 * 1024))" /dev/urandom | base64 -w 76 | sed 's/$/\r/'
    } > "$msg"
    message_bytes=$(wc -c < "$msg")
    request_bytes=$(base64 -w0 < "$msg" | wc -c)

    printf '%s MB attachment (message %s bytes, request %s bytes): ' \
        "$mb" "$message_bytes" "$request_bytes"
    if output=$("$GRAPH_SEND" "$sender" "$recipient" < "$msg" 2>&1); then
        echo "accepted by Graph"
    else
        echo "NOT ACCEPTED (exit $?)"
        printf '  %s\n' "$output"
        failed=1
    fi
done
exit "$failed"
