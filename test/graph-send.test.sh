#!/usr/bin/env bash
# Unit tests for scripts/graph-send.sh - the Postfix pipe command that posts
# queued MIME messages to Microsoft Graph sendMail. Runs on the host against
# a local mock Graph endpoint (test/mock-graph.py).
#
#   ./test/graph-send.test.sh
set -u
cd "$(dirname "$0")/.."

PORT=18321
TMP=$(mktemp -d)
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

python3 test/mock-graph.py "$PORT" "$TMP" &
SERVER_PID=$!
up=""
for _ in $(seq 1 50); do
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/health"; then up=1; break; fi
    sleep 0.1
done
[ -n "$up" ] || { echo "FAIL: mock server did not start"; exit 1; }

pass=0; fail=0
check() { # check <name> <expected> <actual>
    if [ "$3" = "$2" ]; then
        echo "PASS: $1"; pass=$((pass+1))
    else
        echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; fail=$((fail+1))
    fi
}

# run_send <sender> <recipient>... - feeds $MIME on stdin, captures exit code
run_send() {
    printf '%s' "$MIME" | \
        TOKEN_FILE="$TMP/token" GRAPH_ENDPOINT="http://127.0.0.1:$PORT/v1.0" \
        bash scripts/graph-send.sh "$@" 2>"$TMP/stderr"
    echo "$?" > "$TMP/exit"
}
last_request() { tail -n 1 "$TMP/requests.jsonl" 2>/dev/null || echo '{}'; }
# sys.stdout.reconfigure(newline='') stops Windows Python from turning \n
# into \r\n, which would corrupt the base64 payload before decoding.
req_field() {
    last_request | python3 -c "import sys,json
sys.stdout.reconfigure(newline='')
sys.stdout.write(json.load(sys.stdin).get('$1',''))"
}

printf '%s' "test-token-123" > "$TMP/token"
MIME=$'From: printers@example.com\r\nTo: user@example.org\r\nSubject: scan\r\n\r\nhello scan\r\n'

# --- accepted message is posted to Graph as the envelope sender -------------
run_send printers@example.com user@example.org
check "happy path exits 0" "0" "$(cat "$TMP/exit")"
check "posts to the sender's sendMail endpoint" \
    "/v1.0/users/printers@example.com/sendMail" "$(req_field path)"
check "authenticates with the bearer token" \
    "Bearer test-token-123" "$(req_field authorization)"
check "sends MIME as text/plain" "text/plain" "$(req_field content_type)"
# byte-exact comparison ($(...) would strip trailing newlines)
req_field body | base64 -d > "$TMP/decoded" 2>/dev/null
if printf '%s' "$MIME" | cmp -s - "$TMP/decoded"; then
    echo "PASS: body is the base64-encoded MIME message"; pass=$((pass+1))
else
    echo "FAIL: body is the base64-encoded MIME message"; fail=$((fail+1))
fi

# --- Graph errors map to Postfix pipe exit codes ----------------------------
# transient (throttling, outage) -> EX_TEMPFAIL(75): Postfix keeps retrying;
# permanent (denied, bad request) -> EX_UNAVAILABLE(69): bounce to the printer
echo 503 > "$TMP/status"
run_send printers@example.com user@example.org
check "503 defers (exit 75)" "75" "$(cat "$TMP/exit")"

echo 429 > "$TMP/status"
run_send printers@example.com user@example.org
check "429 throttling defers (exit 75)" "75" "$(cat "$TMP/exit")"

echo 403 > "$TMP/status"
run_send printers@example.com user@example.org
check "403 access denied bounces (exit 69)" "69" "$(cat "$TMP/exit")"
echo 202 > "$TMP/status"

# --- availability problems defer, never bounce ------------------------------
# (the token refresher / Graph will recover; the printer's mail must survive)
rm -f "$TMP/token"
run_send printers@example.com user@example.org
check "missing token file defers (exit 75)" "75" "$(cat "$TMP/exit")"
printf '%s' "test-token-123" > "$TMP/token"

printf '%s' "$MIME" | \
    TOKEN_FILE="$TMP/token" GRAPH_ENDPOINT="http://127.0.0.1:1" \
    bash scripts/graph-send.sh printers@example.com user@example.org 2>/dev/null
check "unreachable endpoint defers (exit 75)" "75" "$?"

# --- envelope recipients absent from To/Cc are delivered via Bcc ------------
# Graph sendMail takes recipients from the MIME headers only; an envelope-only
# recipient (e.g. a printer's BCC) would otherwise be silently dropped.
run_send printers@example.com user@example.org hidden@example.org
check "exit 0 with envelope-only recipient" "0" "$(cat "$TMP/exit")"
req_field body | base64 -d > "$TMP/decoded" 2>/dev/null
bcc=$(grep -i '^Bcc:' "$TMP/decoded" | tr -d '\r')
case "$bcc" in
    *hidden@example.org*) echo "PASS: envelope-only recipient added as Bcc"; pass=$((pass+1)) ;;
    *) echo "FAIL: envelope-only recipient added as Bcc - Bcc header: '$bcc'"; fail=$((fail+1)) ;;
esac
case "$bcc" in
    *user@example.org*) echo "FAIL: header recipient must not be duplicated into Bcc"; fail=$((fail+1)) ;;
    *) echo "PASS: header recipient must not be duplicated into Bcc"; pass=$((pass+1)) ;;
esac
if grep -q 'hello scan' "$TMP/decoded"; then
    echo "PASS: original body preserved when Bcc is added"; pass=$((pass+1))
else
    echo "FAIL: original body preserved when Bcc is added"; fail=$((fail+1))
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
