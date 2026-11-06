#!/bin/bash
# Postfix pipe command for clients with a mapped mailbox (config/client_senders).
# Called as: sender-rewrite.sh <mailbox> <recipient>... with the raw message on
# stdin. Replaces the From header, drops Sender, and re-injects the message with
# <mailbox> as envelope sender, so the outbound mode sees an ordinary message
# from that mailbox and needs no knowledge of the mapping.
#
# SENDMAIL can be overridden for tests.
set -u
set -o pipefail

SENDMAIL="${SENDMAIL:-/usr/sbin/sendmail}"

mailbox=$1
shift

awk -v mailbox="$mailbox" '
    in_body { print; next }
    /^\r?$/ {
        if (!from_done) print "From: " mailbox
        in_body = 1
        print
        next
    }
    /^[ \t]/ { if (!skip) print; next }   # folded continuation of the last header
    {
        skip = 0
        name = tolower($0)
        if (name ~ /^from:/) {
            if (!from_done) print "From: " mailbox
            from_done = 1
            skip = 1
            next
        }
        if (name ~ /^sender:/) { skip = 1; next }
        print
    }
' | "$SENDMAIL" -G -i -f "$mailbox" -- "$@"
status=$?

# Exit codes are Postfix pipe(8) sysexits. Anything else would bounce the
# message, so an unexpected failure defers it instead.
case "$status" in
    0) exit 0 ;;
    6[4-9]|7[0-8]) exit "$status" ;;
    *)
        echo "sender-rewrite: re-injection failed with status $status, deferring" >&2
        exit 75 ;;
esac
