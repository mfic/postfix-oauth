#!/bin/bash
# Turns a Postfix bounce into a failure notice for graph-send.sh. Reads the bounce
# on stdin and prints the result. Whether a notice goes out, and to whom, is the
# caller's decision:
#
#   details                       print what failed, for one log line
#   plain <from> <to> [<status>]  print the notice as plain text. <status> is the
#                                 HTTP status that refused it with its attachment.
#   attached <from> <to>          print the notice with the failed message attached.
#                                 Prints nothing and exits 1 if the bounce holds none.
#
# Only the delivery-status part and the failed message's headers are read, so
# nothing from the message's content can reach the log or a notice, apart from
# what attached is asked to attach.
set -u

# Decodes MIME encoded words (=?charset?Q|B?text?=) to UTF-8, for showing a subject
# in a notice. A word that can't be decoded stays as it is, so a strange subject can
# never cost the notice. Control characters become spaces, keeping it on one line.
decode_subject() {
    local rest=$1 out="" word charset encoding text before decoded previous_word=""
    local pattern='=\?([^?[:space:]]+)\?([BbQq])\?([^?[:space:]]*)\?='
    while [[ "$rest" =~ $pattern ]]; do
        word=${BASH_REMATCH[0]}
        charset=${BASH_REMATCH[1]%%\**}
        encoding=${BASH_REMATCH[2]}
        text=${BASH_REMATCH[3]}
        before=${rest%%"$word"*}
        rest=${rest#*"$word"}
        # whitespace between two encoded words is not part of the subject
        if [ -z "$previous_word" ] || [ -n "${before//[[:space:]]/}" ]; then
            out+=$before
        fi
        case "$encoding" in
            [Bb]) decoded=$(printf '%s' "$text" | base64 -d 2>/dev/null | iconv -f "$charset" -t UTF-8 2>/dev/null) ;;
            *)
                text=${text//\\/\\\\}
                text=${text//_/ }
                decoded=$(printf '%b' "$(printf '%s' "$text" | sed -E 's/=([0-9A-Fa-f]{2})/\\x\1/g')" \
                    | iconv -f "$charset" -t UTF-8 2>/dev/null)
                ;;
        esac
        # shellcheck disable=SC2181
        if [ "$?" -eq 0 ] && [ -n "$decoded" ]; then
            out+=$decoded
        else
            out+=$word
        fi
        previous_word=yes
    done
    printf '%s' "$out$rest" | tr '\000-\037\177' ' '
}

usage="usage: failure-notice.sh details | plain <from> <to> [<status>] | attached <from> <to>"
case "${1:-}" in
    details) ;;
    plain|attached) [ "$#" -ge 3 ] || { echo "$usage" >&2; exit 64; } ;;
    *) echo "$usage" >&2; exit 64 ;;
esac

attachment=""
bounce=$(mktemp) || exit 1
trap 'rm -f "$bounce" "$attachment"' EXIT
tr -d '\r' > "$bounce" || exit 1

report=$(awk '
    /^Content-Type: message\/delivery-status/ { inside = 1; next }
    inside && /^--/ { exit }
    inside && /^[ \t]/ { sub(/^[ \t]+/, " "); line = line $0; next }
    inside { if (line != "") print line; line = $0 }
    END { if (line != "") print line }' "$bounce")
original=$(printf '%s\n' "$report" | sed -n 's/^X-Postfix-Queue-ID: *//p' | head -n 1)

if [ "$1" = details ]; then
    failed=$(printf '%s\n' "$report" | sed -n 's/^Final-Recipient: *rfc822; *//p' | paste -sd, -)
    printf 'original message %s, failed recipients %s\n' "${original:-unknown}" "${failed:-unknown}"
    exit 0
fi

# Plain text, because Graph accepts a multipart/report with a 2xx but Exchange
# does not deliver it (tested live). Graph takes sender and recipients from
# these headers.
original_sender=$(printf '%s\n' "$report" | sed -n 's/^X-Postfix-Sender: *rfc822; *//p' | head -n 1)
original_subject=$(awk '
    /^Content-Type: (message\/rfc822|text\/rfc822-headers)/ { part = 1; next }
    part == 1 && /^$/ { part = 2; next }
    part == 2 && /^$/ { exit }
    part == 2 && /^[ \t]/ { if (found) { sub(/^[ \t]+/, " "); subject = subject $0 } next }
    part == 2 { found = (tolower($0) ~ /^subject:/); if (found) subject = substr($0, 9) }
    END { sub(/^[ \t]+/, "", subject); print subject }' "$bounce")
original_subject=$(decode_subject "$original_subject")
notice_headers=$(
    sed '/^$/q' "$bounce" | grep -iE '^(date|message-id):'
    printf 'From: %s\nTo: %s\n' "$2" "$3"
    printf 'Subject: Mail relay: delivery failed (%s)\n' "${original:-unknown}"
    printf 'Auto-Submitted: auto-replied\nMIME-Version: 1.0'
)
notice_text() { # notice_text <how to describe the message's content>
    printf 'A message sent through the mail relay could not be delivered, and the\n'
    printf 'relay will not retry it.\n\n'
    printf 'Queue ID: %s\n' "${original:-unknown}"
    printf 'Sender:   %s\n' "${original_sender:-unknown}"
    printf 'Subject:  %s\n\n' "${original_subject:-unknown}"
    printf '%s\n' "$report" | awk '
        /^Final-Recipient:/ { sub(/^[^;]*; */, ""); print "Recipient: " $0 }
        /^Status:/ { sub(/^[^:]*: */, ""); print "Status:    " $0 }
        /^Diagnostic-Code:/ { sub(/^[^;]*; */, ""); print "Reason:    " $0; print "" }'
    printf '%s\n' "$1"
}

if [ "$1" = plain ]; then
    if [ -n "${4:-}" ]; then
        content="The failed message could not be attached: Graph refused the notice with it,
HTTP $4. The relay's log has more under the queue ID."
    else
        content="The message's content is not included. The relay's log has more under the
queue ID."
    fi
    printf '%s\nContent-Type: text/plain; charset=utf-8\n\n' "$notice_headers"
    notice_text "$content"
    exit
fi

# The attachment comes from the report's message/rfc822 part. An attachment is
# only safe outside a multipart/report, which Exchange does not deliver.
attachment=$(mktemp) || exit 1
report_boundary=$(sed '/^$/q' "$bounce" | sed -n 's/.*boundary="\([^"]*\)".*/\1/p' | head -n 1)
awk -v end="--$report_boundary--" '
    part == 2 && $0 == end { exit }
    part == 2 { print; next }
    part == 1 && /^$/ { part = 2; next }
    /^Content-Type: message\/rfc822/ { part = 1 }' "$bounce" > "$attachment"
[ -s "$attachment" ] || exit 1
boundary="relay-notice-${original:-unknown}-$$"
printf '%s\nContent-Type: multipart/mixed; boundary="%s"\n\n' "$notice_headers" "$boundary"
printf -- '--%s\nContent-Type: text/plain; charset=utf-8\n\n' "$boundary"
notice_text "The failed message is attached. The relay's log has more under the queue ID."
printf -- '\n--%s\nContent-Type: message/rfc822\n' "$boundary"
printf 'Content-Disposition: attachment; filename="failed-message.eml"\n\n'
cat "$attachment"
printf -- '\n--%s--\n' "$boundary"
