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

if ! token=$(cat "$TOKEN_FILE" 2>/dev/null) || [ -z "$token" ]; then
    echo "graph-send: no access token at $TOKEN_FILE, deferring" >&2
    exit 75
fi

msg=$(mktemp)
response=$(mktemp)
trap 'rm -f "$msg" "$response"' EXIT
cat > "$msg"

# Graph delivers to the recipients named in the MIME headers, not to the
# envelope. Envelope recipients missing from the headers (e.g. a printer's
# BCC) are added as an explicit Bcc header, which Graph honors and strips.
headers=$(sed '/^\r\{0,1\}$/q' "$msg")
bcc=""
for rcpt in "$@"; do
    printf '%s' "$headers" | grep -qiF "$rcpt" || bcc="${bcc:+$bcc, }$rcpt"
done
if [ -n "$bcc" ]; then
    { printf 'Bcc: %s\r\n' "$bcc"; cat "$msg"; } > "$msg.bcc"
    mv -f "$msg.bcc" "$msg"
fi

status=$(base64 -w0 < "$msg" | curl -s -o "$response" -w '%{http_code}' -X POST \
    "$GRAPH_ENDPOINT/users/$sender/sendMail" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: text/plain" \
    --data-binary @-)

# Exit codes are Postfix pipe(8) sysexits: 75 = defer and retry, 69 = bounce.
case "$status" in
    2*) exit 0 ;;
    000|429|5*)
        echo "graph-send: HTTP $status from Graph, deferring: $(cat "$response")" >&2
        exit 75 ;;
    *)
        echo "graph-send: HTTP $status from Graph, bouncing: $(cat "$response")" >&2
        exit 69 ;;
esac
