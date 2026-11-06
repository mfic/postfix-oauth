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

cleanup() { [ -n "$COMPOSE" ] && $COMPOSE down -v >/dev/null 2>&1; rm -rf test/.tls-fixtures; }
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

# smtp_dialogue_tls <port> <smtp-command>...
# The same dialogue over STARTTLS, from an IP that is NOT whitelisted. Uses the
# relay's own image, because busybox has no openssl.
smtp_dialogue_tls() {
    local port=$1; shift
    docker run --rm -i --network "${PROJECT}_default" -e SMTP_STARTTLS=1 --entrypoint sh \
        "$(docker inspect --format '{{.Image}}' "$RELAY")" \
        -s -- relay "$port" "$@" < test/smtp-dialogue.sh
}

boot_stack() { # boot_stack <mode> [fixture-dir, relative to test/]
    PROJECT="postfix-oauth-test-$1"
    COMPOSE="docker compose -p $PROJECT -f test/compose.$1.test.yml ${EXTRA_COMPOSE:-}"
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

    out=$(smtp_dialogue_tls 587 "AUTH PLAIN $auth" 'MAIL FROM:<printers@example.com>' 'RCPT TO:<user@example.org>')
    check "STARTTLS on 587: account authenticates inside TLS" '235 2\.7\.0' "$out"
    check "STARTTLS on 587: authenticated printer may relay" '250 2\.1\.5' "$out"

    out=$(smtp_dialogue_tls 25 "AUTH PLAIN $auth" 'MAIL FROM:<printers@example.com>' 'RCPT TO:<user@example.org>')
    check "STARTTLS on 25: authenticated printer may relay" '250 2\.1\.5' "$out"

    check_tls_logged 'postfix/smtpd' "the log shows TLS use on 25"
    check_tls_logged 'postfix/submission/smtpd' "the log shows TLS use on 587"

    local port
    for port in 25 587; do
        check "$port accepts TLS 1.2" '^accepted TLSv1\.2$' "$(tls_probe "$port" tls1_2)"
        check "$port accepts TLS 1.3" '^accepted TLSv1\.3$' "$(tls_probe "$port" tls1_3)"
        check "$port refuses TLS 1.0" '^refused$' "$(tls_probe "$port" tls1)"
        check "$port refuses TLS 1.1" '^refused$' "$(tls_probe "$port" tls1_1)"
    done
    # the client's own policy can't be what refused: see the TLS_MIN_VERSION=TLSv1 stack
    check "the relay itself logs the refusal" 'TLS library problem: .*unsupported protocol' "$(docker logs "$RELAY" 2>&1)"
}

# A handshake limited to one TLS version, giving "accepted <version>", "refused" or
# "no handshake". A refused handshake still prints the Protocol line, so "New," decides.
# The client's security level is lowered so that it will offer old versions, and the
# TLS_MIN_VERSION=TLSv1 stack shows it does.
tls_probe() { # tls_probe <port> <tls1|tls1_1|tls1_2|tls1_3>
    local out
    out=$(docker exec "$RELAY" sh -c "echo QUIT | timeout 15 openssl s_client -starttls smtp -crlf -connect 127.0.0.1:$1 -$2 -cipher ALL:@SECLEVEL=0 2>&1")
    case "$out" in
        *"New, (NONE)"*) echo refused ;;
        *"New, TLS"*) echo "accepted $(printf '%s\n' "$out" | sed -n 's/^ *Protocol *: *//p' | head -1 | tr -d '\r')" ;;
        *) echo "no handshake" ;;
    esac
}

check_tls_logged() { # check_tls_logged <syslog name> <check name>: log lines arrive a moment late
    local pattern="$1\[[0-9]+\]: .*TLS connection established from .*TLSv1" logs=""
    for _ in $(seq 1 10); do
        logs=$(docker logs "$RELAY" 2>&1)
        printf '%s\n' "$logs" | grep -qE "$pattern" && break
        sleep 1
    done
    check "$2" "$pattern" "$logs"
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
    PYTHONUTF8=1 python3 -c "import sys,json,base64;print(base64.b64decode(json.loads(sys.stdin.read())['body']).decode('utf-8','replace'))" 2>/dev/null
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
    out=$(FIXTURES=./fixtures FAILURE_NOTICE_ATTACH_MESSAGE=yes run_entrypoint)
    check "boot refuses an attachment setting without a mailbox" 'FATAL: FAILURE_NOTICE_ATTACH_MESSAGE needs' "$out"
    out=$(FIXTURES=./fixtures FAILURE_NOTICE_ATTACH_MESSAGE=maybe run_entrypoint)
    check "boot refuses an unknown attachment setting" 'FATAL: FAILURE_NOTICE_ATTACH_MESSAGE must be yes or no' "$out"
    out=$(FIXTURES=./fixtures TLS_MIN_VERSION=SSLv3 run_entrypoint)
    check "boot refuses an unknown TLS version" 'FATAL: TLS_MIN_VERSION must be' "$out"
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

# ------------------------------------------- graph mode, notice with attachment
export FAILURE_NOTICE_MAILBOX=notices@example.com FAILURE_NOTICE_SENDER=noreply@example.com FAILURE_NOTICE_ATTACH_MESSAGE=yes
boot_stack graph fixtures
unset FAILURE_NOTICE_MAILBOX FAILURE_NOTICE_SENDER FAILURE_NOTICE_ATTACH_MESSAGE

# about 120 KB, more than the 50 KB a bounce normally keeps. Submitted inside the
# container, because SMTP dialogue arguments can't carry a message this long.
docker exec "$MOCK" sh -c 'echo 403 > /state/status_once'
docker exec "$RELAY" sh -c '{
    printf "From: printers@example.com\nTo: user@example.org\nSubject: big scan\n\nFIRST LINE 5521\n"
    for n in $(seq 1 1600); do printf "%075d\n" "$n"; done
    printf "LAST LINE 5522\n"
} | /usr/sbin/sendmail -f printers@example.com user@example.org'
wait_sendmail 2
decoded=$(sendmail_requests | tail -1 | decoded_body)
check "attached notice is multipart/mixed" '^Content-Type: multipart/mixed' "$decoded"
check "attached notice gives the Graph failure" 'HTTP 403 from Graph' "$decoded"
check "attachment starts with the failed message" 'FIRST LINE 5521' "$decoded"
check "attachment is not cut off at 50 KB" 'LAST LINE 5522' "$decoded"

cleanup

# ---------------------------------------------- graph mode, trusted networks
# fixtures-trusted lists Docker's default address pools, so the "remote" helper
# counts as trusted. Runs in one mode: the setting has nothing mode-specific.
boot_stack graph fixtures-trusted

out=$(smtp_dialogue remote 25 'MAIL FROM:<printers@example.com>' 'RCPT TO:<user@example.org>')
check "client in trusted_networks relays without auth" '250 2\.1\.5' "$out"
out=$(smtp_dialogue remote 25 'MAIL FROM:<evil@nowhere.com>' 'RCPT TO:<user@example.org>')
check "trusted network stays bound by the whitelist" '554 5\.7\.1 .*Sender address rejected' "$out"
out=$(docker exec "$RELAY" postconf -h mynetworks)
check "IPv6 entry is written in brackets" '\[2001:db8::\]/32' "$out"
check "boot log counts the trusted networks" 'Loaded 5 trusted network\(s\)' "$(docker logs "$RELAY" 2>&1)"
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
    'DATA' 'From: wrong@nowhere.com' 'To: user@example.org' 'Subject: =?utf-8?Q?Pr=C3=BCfung_f=C3=A4llt_aus?=' '' 'SCAN MARKER 9931' '.' >/dev/null
wait_sendmail 2
sent=$(sendmail_requests | tail -1)
decoded=$(printf '%s' "$sent" | decoded_body)
check "failure notice is sent as the configured sender" '/v1.0/users/noreply@example.com/sendMail' "$sent"
check "failure notice goes to the configured mailbox" '^To: notices@example\.com' "$decoded"
check "failure notice is plain text" '^Content-Type: text/plain' "$decoded"
check "failure notice names the failed recipient" 'Recipient: user@example\.org' "$decoded"
check "failure notice gives the Graph failure" 'HTTP 403 from Graph' "$decoded"
check "failure notice gives the original subject, decoded" 'Subject:  Prüfung fällt aus' "$decoded"
if printf '%s\n' "$decoded" | grep -q 'SCAN MARKER 9931'; then
    check "failure notice leaves out the message content" 'absent' 'present'
else
    check "failure notice leaves out the message content" 'absent' 'absent'
fi

cleanup
unset FAILURE_NOTICE_MAILBOX FAILURE_NOTICE_SENDER

# ------------------------------------------------------- older TLS, on request
# Also the control for the refusals above: the same client, offering the same old
# versions, is accepted here, so those refusals came from the relay.
export TLS_MIN_VERSION=TLSv1
boot_stack graph
for port in 25 587; do
    check "with TLS_MIN_VERSION=TLSv1, $port accepts TLS 1.0" '^accepted TLSv1$' "$(tls_probe "$port" tls1)"
    check "with TLS_MIN_VERSION=TLSv1, $port accepts TLS 1.1" '^accepted TLSv1\.1$' "$(tls_probe "$port" tls1_1)"
done
cleanup
unset TLS_MIN_VERSION

# ------------------------------------------------------- certificate handling
# What a client on 587 is served: subject, issuer, serial, key type and name
served_cert() {
    docker exec "$RELAY" sh -c 'echo QUIT | timeout 15 openssl s_client -starttls smtp -crlf -connect 127.0.0.1:587 2>/dev/null | openssl x509 -noout -subject -issuer -serial -text 2>&1'
}
served_serial() { served_cert | sed -n 's/^serial=//p'; }
wait_served() { # wait_served <check name> <regex> [tries]: the relay switches by itself
    local out=""
    for _ in $(seq 1 "${3:-30}"); do
        out=$(served_cert)
        printf '%s\n' "$out" | grep -qE "$2" && break
        sleep 2
    done
    check "$1" "$2" "$out"
}
restart_relay() {
    docker restart "$RELAY" >/dev/null
    sleep 2
    for _ in $(seq 1 60); do docker exec "$RELAY" sh -c 'nc -z 127.0.0.1 25' 2>/dev/null && break; sleep 1; done
}
absent() { # absent <check name> <regex> <output>
    if printf '%s\n' "$3" | grep -qE "$2"; then check "$1" 'absent' "found /$2/"; else check "$1" 'absent' 'absent'; fi
}
make_cert() { # make_cert <dir> <name> [days]
    mkdir -p "$1"
    MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days "${3:-30}" -subj "/CN=$2" \
        -keyout "$1/key.pem" -out "$1/cert.pem" 2>/dev/null
}

TLSFX=test/.tls-fixtures
rm -rf "$TLSFX"
for dir in live half mismatch; do mkdir -p "$TLSFX/$dir"; cp test/fixtures/* "$TLSFX/$dir/"; done

make_cert "$TLSFX/half/tls" half.example.test
rm "$TLSFX/half/tls/key.pem"
out=$(FIXTURES=./.tls-fixtures/half run_entrypoint)
check "boot refuses a certificate without its key" 'FATAL: /config/tls needs both' "$out"

make_cert "$TLSFX/mismatch/tls" one.example.test
make_cert "$TLSFX/other" two.example.test
cp "$TLSFX/other/key.pem" "$TLSFX/mismatch/tls/key.pem"
out=$(FIXTURES=./.tls-fixtures/mismatch run_entrypoint)
check "boot refuses a key that belongs to another certificate" "FATAL: /config/tls/cert.pem and key.pem .*don't belong together" "$out"

out=$(FIXTURES=./.tls-fixtures/mismatch COMPOSE_PROFILES=letsencrypt run_entrypoint)
check "boot refuses config/tls together with Let's Encrypt" 'FATAL: /config/tls is set and so is the letsencrypt profile' "$out"
out=$(FIXTURES=./fixtures COMPOSE_PROFILES=letsencrypt run_entrypoint)
check "boot refuses Let's Encrypt for a private hostname" 'FATAL: the letsencrypt profile needs POSTFIX_HOSTNAME' "$out"
docker compose -p postfix-oauth-test-bad -f test/compose.graph.test.yml down -v --remove-orphans >/dev/null 2>&1

# a mounted certificate, renewed on disk, with no restart
make_cert "$TLSFX/live/tls" first.example.test 1
export TLS_WATCH_SECONDS=2
boot_stack graph .tls-fixtures/live
wait_served "a mounted certificate is served" 'subject=CN *= *first\.example\.test'
check "boot log names the certificate's source" 'TLS certificate: config/tls' "$(docker logs "$RELAY" 2>&1)"
check "a certificate near its expiry is warned about" 'WARNING: the TLS certificate from config/tls .*less than 14 days' "$(docker logs "$RELAY" 2>&1)"
make_cert "$TLSFX/live/tls" renewed.example.test
wait_served "a renewed certificate is served without a restart" 'subject=CN *= *renewed\.example\.test'

cp "$TLSFX/other/key.pem" "$TLSFX/live/tls/key.pem"
sleep 5
check "a mismatched key is logged" "WARNING: the certificate from config/tls and its key don't belong together" "$(docker logs "$RELAY" 2>&1)"
wait_served "a mismatched key leaves the working certificate in place" 'subject=CN *= *renewed\.example\.test' 1

rm -rf "$TLSFX/live/tls"
restart_relay
wait_served "a removed certificate doesn't survive a restart" 'subject=CN *= *mailrelay\.test\.local'
out=$(smtp_dialogue_tls 587 'MAIL FROM:<printers@example.com>')
check "the self-signed certificate works for STARTTLS" '250 2\.1\.0' "$out"
cleanup
unset TLS_WATCH_SECONDS

# ------------------------------------------------------------- Let's Encrypt
# The real sidecar definition against Pebble, with a mock Cloudflare API. The mock
# only knows example.com, so a wrong name or zone lookup fails the issuance.
cloudflare_state() {
    docker exec postfix-oauth-test-mockcloudflare python3 -c \
        "import urllib.request as u;print(u.urlopen('http://127.0.0.1:8081/_state').read().decode())"
}
CERTBOT=postfix-oauth-test-certbot
EXTRA_COMPOSE="-f test/compose.letsencrypt.test.yml" boot_stack graph
check "boot log says the relay is waiting for the sidecar" 'self-signed, until the Let.s Encrypt sidecar' "$(docker logs "$RELAY" 2>&1)"
wait_served "the relay switches to the sidecar's certificate by itself" 'issuer=.*Pebble' 60
served=$(served_cert)
check "the certificate is for POSTFIX_HOSTNAME" 'DNS:relay\.example\.com' "$served"
check "the certificate is RSA, for older printers" 'Public Key Algorithm: rsaEncryption' "$served"
state=$(cloudflare_state)
check "the DNS challenge used the token from cloudflare.ini" 'Bearer test-token-for-mock-cloudflare' "$state"
check "the DNS challenge record was cleaned up" '"present": 0' "$state"
absent "the relay has no Cloudflare token" 'test-token-for-mock-cloudflare|cloudflare\.ini' \
    "$(docker exec "$RELAY" sh -c 'env; ls /run/cloudflare.ini 2>/dev/null; grep -rl test-token-for-mock /config /etc/postfix /etc/postfix-relay 2>/dev/null')"
out=$(smtp_dialogue_tls 587 "AUTH PLAIN $(auth_plain printer-test)" 'MAIL FROM:<printers@example.com>' 'RCPT TO:<user@example.org>')
check "a client can log in over STARTTLS with this certificate" '250 2\.1\.5' "$out"

serial=$(served_serial)
out=$(docker exec "$CERTBOT" certbot renew --force-renewal --no-random-sleep-on-renew 2>&1)
check "the sidecar renews" 'renewals succeeded' "$out"
added=$(cloudflare_state)
renewed=""
for _ in $(seq 1 30); do
    renewed=$(served_serial)
    [ -n "$renewed" ] && [ "$renewed" != "$serial" ] && break
    sleep 2
done
if [ -n "$renewed" ] && [ "$renewed" != "$serial" ]; then
    check "the relay serves the renewed certificate without a restart" 'ok' 'ok'
else
    check "the relay serves the renewed certificate without a restart" 'ok' "still serial $renewed"
fi
check "the relay logs the new certificate" "TLS certificate: installed a new one from Let's Encrypt" "$(docker logs "$RELAY" 2>&1)"

docker restart "$CERTBOT" >/dev/null
not_due=""
for _ in $(seq 1 30); do
    not_due=$(docker logs "$CERTBOT" 2>&1)
    printf '%s\n' "$not_due" | grep -q 'not yet due for renewal' && break
    sleep 2
done
check "a restarted sidecar leaves a certificate that isn't due" 'not yet due for renewal' "$not_due"
if [ "$added" = "$(cloudflare_state)" ]; then
    check "and creates no new DNS challenge" 'ok' 'ok'
else
    check "and creates no new DNS challenge" 'ok' "before: $added"
fi

$COMPOSE up -d --force-recreate --no-deps relay >/dev/null 2>&1
sleep 2
for _ in $(seq 1 60); do docker exec "$RELAY" sh -c 'nc -z 127.0.0.1 25' 2>/dev/null && break; sleep 1; done
check "a recreated relay starts with the certificate" "TLS certificate: Let's Encrypt" "$(docker logs "$RELAY" 2>&1)"
check "and it's the same one" "^$renewed\$" "$(served_serial)"

# README step 4a, moving from staging to production: delete, then the sidecar starts over
docker exec "$CERTBOT" certbot delete --non-interactive --cert-name relay.example.com >/dev/null 2>&1
docker restart "$CERTBOT" >/dev/null
fresh=""
for _ in $(seq 1 60); do
    fresh=$(served_serial)
    [ -n "$fresh" ] && [ "$fresh" != "$renewed" ] && break
    sleep 2
done
if [ -n "$fresh" ] && [ "$fresh" != "$renewed" ]; then
    check "a deleted certificate is obtained again, with no restart of the relay" 'ok' 'ok'
else
    check "a deleted certificate is obtained again, with no restart of the relay" 'ok' "still serial $fresh"
fi
cleanup

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
