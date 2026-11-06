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
cd "$(dirname "$0")/.." || exit 1

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
# Runs the response-driven driver (test/smtp-dialogue.sh): each command is
# sent only after the previous reply completes - no fixed sleeps.
# "local" runs inside the relay container (127.0.0.1 = trusted mynetworks IP);
# "remote" runs from a helper container whose IP is NOT whitelisted.
smtp_dialogue() {
    local where=$1 port=$2; shift 2
    if [ "$where" = local ]; then
        docker exec -i "$RELAY" sh -s -- 127.0.0.1 "$port" "$@" < test/smtp-dialogue.sh
    else
        docker run --rm -i --network "${PROJECT}_default" busybox \
            sh -s -- relay "$port" "$@" < test/smtp-dialogue.sh
    fi
}

boot_stack() { # boot_stack <mode> [fixture-dir, relative to test/]
    PROJECT="postfix-oauth-test-$1"
    COMPOSE="docker compose -p $PROJECT -f test/compose.$1.test.yml"
    export FIXTURES="./${2:-fixtures}"
    echo
    echo "=== OUTBOUND_MODE=$1, config from test/${2:-fixtures} ==="
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

auth_plain() { # auth_plain <account>: base64 credentials for AUTH PLAIN
    docker exec "$RELAY" sh -c "printf '\0$1\0TestSecret123!' | base64 -w0"
}

# Requests the mock Graph received. wait_sendmail <count> polls until that many
# sendMail requests arrived. decoded_body turns one request into its MIME text.
sendmail_requests() { docker exec "$MOCK" sh -c 'grep sendMail /state/requests.jsonl 2>/dev/null'; }
reset_requests() { docker exec "$MOCK" sh -c ': > /state/requests.jsonl'; }
wait_sendmail() {
    for _ in $(seq 1 20); do
        [ "$(sendmail_requests | wc -l)" -ge "$1" ] && return 0
        sleep 1
    done
    return 1
}
decoded_body() {
    python3 -c "import sys,json,base64;print(base64.b64decode(json.loads(sys.stdin.read())['body']).decode('utf-8','replace'))" 2>/dev/null
}

# Runs the real healthcheck command from the production compose file.
healthcheck_suite() { # healthcheck_suite <mode>
    local cmd
    cmd=$(sed -n 's/.*"CMD-SHELL", "\(.*\)"\].*/\1/p' "docker-compose.$1.yml")
    if [ -n "$cmd" ] && docker exec "$RELAY" sh -c "$cmd"; then
        check "$1 compose healthcheck passes on a healthy relay" 'ok' 'ok'
    else
        check "$1 compose healthcheck passes on a healthy relay" 'ok' "failed: '$cmd'"
    fi
}

# The policy for clients with a mapped mailbox, identical in both modes.
# fixtures-mapped maps 127.0.0.1 ("local") and the account printer-lobby.
mapped_policy_suite() {
    local out free
    free=$(auth_plain printer-free)

    out=$(smtp_dialogue remote 25 'MAIL FROM:<printers@example.com>' 'RCPT TO:<user@example.org>')
    check "mapping grants no relay access to an untrusted IP" '554 5\.7\.1 .*Recipient address rejected' "$out"

    out=$(smtp_dialogue remote 587 "AUTH PLAIN $free" 'MAIL FROM:<evil@nowhere.com>' 'RCPT TO:<user@example.org>')
    check "unmapped account stays bound by the whitelist" '554 5\.7\.1 .*Sender address rejected' "$out"

    out=$(smtp_dialogue remote 587 "AUTH PLAIN $free" 'MAIL FROM:<scanner@example.com>' 'RCPT TO:<user@example.org>')
    check "unmapped account may choose a whitelisted sender" '250 2\.1\.5' "$out"
}

# A bad config line must stop the relay: skipped, it would let the client choose
# its own sender. Runs the entrypoint only, so no stack needs to be up.
run_entrypoint() {
    timeout 180 docker compose -p postfix-oauth-test-bad -f test/compose.graph.test.yml \
        run --build -T --rm --no-deps relay 2>&1
}
bad_config_suite() {
    local name expected out
    for name in bad-mailbox:'client_senders: .*not in allowed_senders' \
        bad-account:'client_senders: .*not in client_accounts' \
        bad-ip:'client_senders: invalid IP entry' \
        bad-network:'trusted_networks: invalid entry' \
        bad-network-name:'trusted_networks: .*not an IP or CIDR' \
        bad-network-all:'trusted_networks: .*would trust every address'; do
        expected=${name#*:}
        out=$(FIXTURES="./fixtures-${name%%:*}" run_entrypoint)
        check "boot refuses ${name%%:*}" "FATAL: /config/$expected" "$out"
    done
    out=$(FIXTURES=./fixtures FAILURE_NOTICE_MAILBOX=notices@example.com run_entrypoint)
    check "boot refuses a notice mailbox without a sender" 'FATAL: set FAILURE_NOTICE_MAILBOX and FAILURE_NOTICE_SENDER together' "$out"
    docker compose -p postfix-oauth-test-bad -f test/compose.graph.test.yml down -v --remove-orphans >/dev/null 2>&1
}

# --------------------------------------------------------------- graph mode
boot_stack graph
inbound_suite
healthcheck_suite graph

out=$(docker exec "$RELAY" postconf -h smtpd_sender_restrictions)
check "boot log shows when no network is trusted" 'Loaded 0 trusted network\(s\)' "$(docker logs "$RELAY" 2>&1)"
check "without a mapping the sender policy is the plain whitelist" \
    '^check_sender_access hash:/etc/postfix/allowed_senders, reject$' "$out"

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
check "without a mapping the printer's From is passed on" '^From: printers@example\.com' "$decoded"

# a failure notice has no mailbox to go out from: logged, never posted to Graph
reset_requests
docker exec "$MOCK" sh -c 'echo 403 > /state/status'
smtp_dialogue local 25 'MAIL FROM:<printers@example.com>' 'RCPT TO:<user@example.org>' \
    'DATA' 'From: printers@example.com' 'To: user@example.org' 'Subject: fails' '' 'x' '.' >/dev/null
notice=""
for _ in $(seq 1 20); do
    notice=$(docker logs "$RELAY" 2>&1 | grep 'FAILURE NOTICE NOT SENT')
    [ -n "$notice" ] && break
    sleep 1
done
check "failed delivery logs the notice that could not be sent" \
    'FAILURE NOTICE NOT SENT to printers@example\.com.*failed recipients user@example\.org' "$notice"
check "failure notice is not posted to Graph" '^1$' "$(sendmail_requests | wc -l)"
docker exec "$MOCK" sh -c 'rm -f /state/status'

cleanup

# ---------------------------------------------- graph mode, trusted networks
# fixtures-trusted lists Docker's default address pools, so the "remote" helper
# counts as trusted. Runs in one mode: the setting has nothing mode-specific.
export PRINTER_NETWORKS=198.51.100.0/24
boot_stack graph fixtures-trusted
unset PRINTER_NETWORKS

out=$(smtp_dialogue remote 25 'MAIL FROM:<printers@example.com>' 'RCPT TO:<user@example.org>')
check "client in trusted_networks relays without auth" '250 2\.1\.5' "$out"
out=$(smtp_dialogue remote 25 'MAIL FROM:<evil@nowhere.com>' 'RCPT TO:<user@example.org>')
check "trusted network stays bound by the whitelist" '554 5\.7\.1 .*Sender address rejected' "$out"
out=$(smtp_dialogue remote 587 "AUTH PLAIN $(auth_plain printer-test)")
check "older printer_accounts file still counts" '235 2\.7\.0' "$out"
out=$(docker exec "$RELAY" postconf -h mynetworks)
check "IPv6 entry is written in brackets" '\[2001:db8::\]/32' "$out"
check "older PRINTER_NETWORKS still counts" '198\.51\.100\.0/24' "$out"
check "boot log counts file and PRINTER_NETWORKS entries" 'Loaded 6 trusted network\(s\)' "$(docker logs "$RELAY" 2>&1)"
if printf '%s\n' "$out" | grep -q 'printer\|#'; then
    check "comments stay out of mynetworks" 'absent' 'present'
else
    check "comments stay out of mynetworks" 'absent' 'absent'
fi

cleanup

# ------------------------------------------------ graph mode, mapped mailboxes
bad_config_suite
export FAILURE_NOTICE_MAILBOX=notices@example.com FAILURE_NOTICE_SENDER=noreply@example.com
boot_stack graph fixtures-mapped
mapped_policy_suite

lobby=$(auth_plain printer-lobby)

reset_requests
out=$(smtp_dialogue local 25 'MAIL FROM:<wrong@nowhere.com>' 'RCPT TO:<user@example.org>' 'RCPT TO:<hidden@example.org>' \
    'DATA' 'From: Lobby <wrong@nowhere.com>' 'Sender: wrong@nowhere.com' 'To: user@example.org' 'Subject: ip' '' 'IP MARKER' '.')
check "mapped IP may use any MAIL FROM" '250 2\.0\.0 Ok: queued' "$out"
wait_sendmail 1
sent=$(sendmail_requests | tail -1)
decoded=$(printf '%s' "$sent" | decoded_body)
check "mapped IP is sent from its mailbox" '/v1.0/users/ip@example.com/sendMail' "$sent"
check "mapped IP gets its mailbox in From" '^From: ip@example\.com' "$decoded"
if printf '%s\n' "$decoded" | grep -q 'nowhere\.com'; then
    check "printer's sender is gone from the headers" 'absent' 'still present'
else
    check "printer's sender is gone from the headers" 'absent' 'absent'
fi
check "body survives the rewrite" 'IP MARKER' "$decoded"
check "envelope-only recipient survives the rewrite" '^Bcc: hidden@example\.org' "$decoded"

reset_requests
smtp_dialogue remote 587 "AUTH PLAIN $lobby" 'MAIL FROM:<scanner@example.com>' 'RCPT TO:<user@example.org>' \
    'DATA' 'From: scanner@example.com' 'To: user@example.org' 'Subject: account' '' 'x' '.' >/dev/null
wait_sendmail 1
sent=$(sendmail_requests | tail -1)
check "mapped account is sent from its mailbox, even with a whitelisted sender" \
    '/v1.0/users/lobby@example.com/sendMail' "$sent"
check "mapped account gets its mailbox in From" '^From: lobby@example\.com' "$(printf '%s' "$sent" | decoded_body)"

reset_requests
smtp_dialogue local 587 "AUTH PLAIN $lobby" 'MAIL FROM:<wrong@nowhere.com>' 'RCPT TO:<user@example.org>' \
    'DATA' 'From: wrong@nowhere.com' 'To: user@example.org' 'Subject: both' '' 'x' '.' >/dev/null
wait_sendmail 1
check "account mapping wins over IP mapping" \
    '/v1.0/users/lobby@example.com/sendMail' "$(sendmail_requests | tail -1)"

reset_requests
smtp_dialogue remote 587 "AUTH PLAIN $(auth_plain printer-free)" 'MAIL FROM:<scanner@example.com>' 'RCPT TO:<user@example.org>' \
    'DATA' 'From: scanner@example.com' 'To: user@example.org' 'Subject: free' '' 'x' '.' >/dev/null
wait_sendmail 1
sent=$(sendmail_requests | tail -1)
check "unmapped account keeps its chosen sender" '/v1.0/users/scanner@example.com/sendMail' "$sent"
check "unmapped account keeps its From" '^From: scanner@example\.com' "$(printf '%s' "$sent" | decoded_body)"

# more recipients than Postfix's default limit of 50 per pipe call: a split
# would send the same message twice, once per call, to the header recipients
reset_requests
rcpts=()
for n in $(seq 1 60); do rcpts+=("RCPT TO:<user$n@example.org>"); done
smtp_dialogue local 25 'MAIL FROM:<wrong@nowhere.com>' "${rcpts[@]}" \
    'DATA' 'From: wrong@nowhere.com' 'To: list@example.org' 'Subject: many' '' 'x' '.' >/dev/null
wait_sendmail 1
sleep 2
check "a message for 60 recipients stays one Graph request" '^1$' "$(sendmail_requests | wc -l)"

# a real Postfix bounce reaches the configured mailbox through the pipe transport
reset_requests
docker exec "$MOCK" sh -c 'echo 403 > /state/status_once'
smtp_dialogue local 25 'MAIL FROM:<wrong@nowhere.com>' 'RCPT TO:<user@example.org>' \
    'DATA' 'From: wrong@nowhere.com' 'To: user@example.org' 'Subject: fails' '' 'x' '.' >/dev/null
wait_sendmail 2
sent=$(sendmail_requests | tail -1)
decoded=$(printf '%s' "$sent" | decoded_body)
check "failure notice is sent as the configured sender" '/v1.0/users/noreply@example.com/sendMail' "$sent"
check "failure notice goes to the configured mailbox" '^To: notices@example\.com' "$decoded"

cleanup
unset FAILURE_NOTICE_MAILBOX FAILURE_NOTICE_SENDER

# ---------------------------------------------------------------- smtp mode
boot_stack smtp
inbound_suite
healthcheck_suite smtp

# the token chain must produce the sasl-xoauth2 JSON token store
token=$(docker exec "$RELAY" sh -c 'cat /etc/tokens/token 2>/dev/null')
check "token file is in sasl-xoauth2 format" '"refresh_token": "client_credentials"' "$token"
out=$(docker exec "$RELAY" postconf -h relayhost)
check "outbound relayhost is smtp.office365.com" '\[smtp\.office365\.com\]:587' "$out"

cleanup

# ------------------------------------------------- smtp mode, mapped mailboxes
boot_stack smtp fixtures-mapped
mapped_policy_suite

# Delivery is held so that nothing reaches smtp.office365.com; the queue shows
# what would be handed to Microsoft.
docker exec "$RELAY" sh -c 'postconf -e defer_transports=smtp && postfix reload' >/dev/null 2>&1
sleep 1
smtp_dialogue remote 587 "AUTH PLAIN $(auth_plain printer-lobby)" 'MAIL FROM:<wrong@nowhere.com>' 'RCPT TO:<user@example.org>' \
    'DATA' 'From: wrong@nowhere.com' 'To: user@example.org' 'Subject: account' '' 'x' '.' >/dev/null
smtp_dialogue local 25 'MAIL FROM:<wrong@nowhere.com>' 'RCPT TO:<user@example.org>' \
    'DATA' 'From: wrong@nowhere.com' 'To: user@example.org' 'Subject: ip' '' 'x' '.' >/dev/null
queue=""
for _ in $(seq 1 20); do
    queue=$(docker exec "$RELAY" postqueue -j)
    case "$queue" in *lobby@example.com*ip@example.com*|*ip@example.com*lobby@example.com*) break ;; esac
    sleep 1
done
check "mapped account is queued with its mailbox as envelope sender" '"sender": "lobby@example\.com"' "$queue"
check "mapped IP is queued with its mailbox as envelope sender" '"sender": "ip@example\.com"' "$queue"
queued_id=$(printf '%s\n' "$queue" | grep 'lobby@example\.com' | sed -E 's/.*"queue_id": "([^"]+)".*/\1/')
check "mapped account's queued message has its mailbox in From" '^From: lobby@example\.com' \
    "$(docker exec "$RELAY" postcat -hq "$queued_id")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
