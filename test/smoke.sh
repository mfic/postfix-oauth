#!/usr/bin/env bash
# Smoke test: exercises the relay's access policy through its real interface,
# the SMTP dialogue on ports 25/587, in BOTH outbound modes (graph and smtp).
# Each mode boots an isolated stack with fixture config and mock Entra/Graph
# endpoints. In graph mode an accepted message is followed end-to-end to the
# mock Graph sendMail endpoint; the real smtp.office365.com leg of smtp mode
# needs real credentials and is not covered.
#
#   ./test/smoke.sh
set -u
cd "$(dirname "$0")/.."

RELAY=postfix-oauth-test-relay
MOCK=postfix-oauth-test-mockgraph
PROJECT=""
COMPOSE=""

cleanup() { [ -n "$COMPOSE" ] && $COMPOSE down -v >/dev/null 2>&1; }
trap cleanup EXIT

pass=0; fail=0
check() { # check <name> <expected-regex> <output>
    if printf '%s\n' "$3" | grep -qE "$2"; then
        echo "PASS: $1"; pass=$((pass+1))
    else
        echo "FAIL: $1 - expected /$2/, got:"; printf '%s\n' "$3" | sed 's/^/  | /'; fail=$((fail+1))
    fi
}

# smtp_dialogue <local|remote> <port> <smtp-command>...
# Sends each command with a 1s pause (postfix rejects blind pipelining).
# "local" runs inside the relay container (127.0.0.1 = trusted mynetworks IP);
# "remote" runs from a helper container whose IP is NOT whitelisted.
smtp_dialogue() {
    local where=$1 port=$2; shift 2
    local script="{ sleep 1; printf 'EHLO smoketest\r\n';"
    local cmd
    for cmd in "$@"; do script="$script sleep 1; printf '$cmd\r\n';"; done
    script="$script sleep 1; printf 'QUIT\r\n'; }"
    if [ "$where" = local ]; then
        docker exec "$RELAY" sh -c "$script | nc -w 15 127.0.0.1 $port"
    else
        docker run --rm --network "${PROJECT}_default" busybox \
            sh -c "$script | nc -w 15 relay $port"
    fi
}

boot_stack() { # boot_stack <mode>
    PROJECT="postfix-oauth-test-$1"
    COMPOSE="docker compose -p $PROJECT -f test/compose.$1.test.yml"
    echo
    echo "=== OUTBOUND_MODE=$1 ==="
    $COMPOSE up -d --build --quiet-pull || { echo "FAIL: $1 stack did not start"; exit 1; }
    echo -n "Waiting for smtpd"
    local up=""
    for _ in $(seq 1 60); do
        if docker exec "$RELAY" sh -c 'nc -z 127.0.0.1 25' 2>/dev/null; then up=1; break; fi
        echo -n .; sleep 1
    done
    echo
    [ -n "$up" ] || { echo "FAIL: smtpd did not come up"; docker logs "$RELAY" | tail -20; exit 1; }
}

inbound_suite() { # the access policy must hold identically in both modes
    local out auth
    out=$(smtp_dialogue local 25 'MAIL FROM:<evil@nowhere.com>' 'RCPT TO:<user@example.org>')
    check "non-whitelisted sender rejected" '554 5\.7\.1 .*Sender address rejected' "$out"

    out=$(smtp_dialogue local 25 'MAIL FROM:<printers@example.com>' 'RCPT TO:<user@example.org>')
    check "whitelisted sender from trusted IP accepted" '250 2\.1\.5' "$out"

    out=$(smtp_dialogue remote 25 'MAIL FROM:<printers@example.com>' 'RCPT TO:<user@example.org>')
    check "untrusted IP without auth denied relay" '554 5\.7\.1 .*Recipient address rejected' "$out"

    auth=$(docker exec "$RELAY" sh -c "printf '\0printer-test\0TestSecret123!' | base64 -w0")
    out=$(smtp_dialogue remote 587 "AUTH PLAIN $auth" 'MAIL FROM:<printers@example.com>' 'RCPT TO:<user@example.org>')
    check "printer account authenticates" '235 2\.7\.0' "$out"
    check "authenticated printer may relay" '250 2\.1\.5' "$out"

    out=$(smtp_dialogue remote 587 "AUTH PLAIN $auth" 'MAIL FROM:<evil@nowhere.com>' 'RCPT TO:<user@example.org>')
    check "whitelist also binds authenticated clients" '554 5\.7\.1 .*Sender address rejected' "$out"
}

# --------------------------------------------------------------- graph mode
boot_stack graph
inbound_suite

# end to end: an accepted message reaches Graph sendMail
out=$(smtp_dialogue local 25 'MAIL FROM:<printers@example.com>' 'RCPT TO:<user@example.org>' \
    'DATA' 'From: printers@example.com' 'To: user@example.org' 'Subject: smoke' '' \
    'SMOKE MARKER 4213' '.')
check "message accepted for delivery" '250 2\.0\.0 Ok: queued' "$out"

sent=""
for _ in $(seq 1 20); do
    sent=$(docker exec "$MOCK" sh -c 'grep sendMail /state/requests.jsonl 2>/dev/null | tail -1')
    [ -n "$sent" ] && break
    sleep 1
done
check "delivered to the sender's Graph sendMail endpoint" \
    '/v1.0/users/printers@example.com/sendMail' "$sent"
check "delivery used the token from the mock Entra endpoint" \
    'Bearer test-token-123' "$sent"
decoded=$(printf '%s' "$sent" \
    | python3 -c "import sys,json,base64;print(base64.b64decode(json.loads(sys.stdin.read())['body']).decode('utf-8','replace'))" 2>/dev/null)
check "Graph received the original message body" 'SMOKE MARKER 4213' "$decoded"

cleanup

# ---------------------------------------------------------------- smtp mode
boot_stack smtp
inbound_suite

# the token chain must produce the sasl-xoauth2 JSON token store
token=$(docker exec "$RELAY" sh -c 'cat /etc/tokens/token 2>/dev/null')
check "token file is in sasl-xoauth2 format" '"refresh_token": "client_credentials"' "$token"
out=$(docker exec "$RELAY" postconf -h relayhost)
check "outbound relayhost is smtp.office365.com" '\[smtp\.office365\.com\]:587' "$out"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
