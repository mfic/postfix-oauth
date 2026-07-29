#!/usr/bin/env bash
# Smoke test: exercises the relay's access policy through its real interface,
# the SMTP dialogue on ports 25/587. Boots an isolated stack with fixture
# config (dummy Entra credentials - the outbound OAuth leg is not tested here).
#
#   ./test/smoke.sh
set -u
cd "$(dirname "$0")/.."

PROJECT=postfix-oauth-test
RELAY=postfix-oauth-test-relay
COMPOSE="docker compose -p $PROJECT -f test/compose.test.yml"

cleanup() { $COMPOSE down -v >/dev/null 2>&1; }
trap cleanup EXIT

echo "Building and starting test stack..."
$COMPOSE up -d --build --quiet-pull || { echo "FAIL: stack did not start"; exit 1; }

echo -n "Waiting for smtpd"
up=""
for _ in $(seq 1 60); do
    if docker exec "$RELAY" sh -c 'nc -z 127.0.0.1 25' 2>/dev/null; then up=1; break; fi
    echo -n .; sleep 1
done
echo
[ -n "$up" ] || { echo "FAIL: smtpd did not come up"; docker logs "$RELAY" | tail -20; exit 1; }

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

echo
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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
