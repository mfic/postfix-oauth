#!/usr/bin/env bash
# Unit tests for scripts/graph-send.sh - the Postfix pipe command that posts
# queued MIME messages to Microsoft Graph sendMail. Runs on the host against
# a local mock Graph endpoint (test/mock-graph.py).
#
#   ./test/graph-send.test.sh
set -u
cd "$(dirname "$0")/.." || exit 1

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

# bcc_of <mime> <recipient>... - the Bcc header Graph receives for this message
bcc_of() {
    MIME=$1; shift
    run_send printers@example.com "$@"
    req_field body | base64 -d 2>/dev/null | sed '/^\r\{0,1\}$/q' | grep -i '^Bcc:' | tr -d '\r'
}
FROM=$'From: printers@example.com\r\n'
BODY=$'Subject: scan\r\n\r\nhello\r\n'

# --- only a whole address in To/Cc counts as present ----------------------
check "address that is a substring of a To address stays in Bcc" \
    "Bcc: a@x.de" "$(bcc_of "${FROM}To: aa@x.de"$'\r\n'"$BODY" aa@x.de a@x.de)"
check "address found only in From stays in Bcc" \
    "Bcc: printers@example.com" \
    "$(bcc_of "${FROM}To: user@example.org"$'\r\n'"$BODY" user@example.org printers@example.com)"
check "address found only in Subject stays in Bcc" \
    "Bcc: a@x.de" \
    "$(bcc_of "${FROM}To: user@example.org"$'\r\n'$'Subject: for a@x.de\r\n\r\nhello\r\n' user@example.org a@x.de)"
check "address found only in a display name stays in Bcc" \
    "Bcc: a@x.de" \
    "$(bcc_of "${FROM}To: \"a@x.de\" <user@example.org>"$'\r\n'"$BODY" user@example.org a@x.de)"
check "To match ignores case" "" \
    "$(bcc_of "${FROM}To: User@Example.ORG"$'\r\n'"$BODY" user@example.org)"
check "folded To and Cc addresses count as present" "" \
    "$(bcc_of "${FROM}To: Some One <one@x.de>,"$'\r\n'$' two@x.de\r\nCc: three@x.de\r\n'"$BODY" one@x.de two@x.de three@x.de)"
check "an existing Bcc header is replaced by one complete header" \
    "Bcc: old@x.de, new@x.de" \
    "$(bcc_of "${FROM}To: user@example.org"$'\r\nBcc: old@x.de\r\n'"$BODY" user@example.org old@x.de new@x.de)"
MIME=$'From: printers@example.com\r\nTo: user@example.org\r\nSubject: scan\r\n\r\nhello scan\r\n'

# --- oversized messages fail visibly ---------------------------------------
echo 413 > "$TMP/status"
run_send printers@example.com user@example.org
check "413 bounces (exit 69)" "69" "$(cat "$TMP/exit")"
if grep -q 'MESSAGE TOO LARGE.*message [0-9]* bytes, request [0-9]* bytes' "$TMP/stderr"; then
    echo "PASS: 413 is logged as too large, with the sizes"; pass=$((pass+1))
else
    echo "FAIL: 413 is logged as too large, with the sizes: $(cat "$TMP/stderr")"; fail=$((fail+1))
fi
echo 202 > "$TMP/status"

# --- Postfix's own notices are reported, never posted to Graph -------------
before=$(grep -c sendMail "$TMP/requests.jsonl")
NOTICE=$'From: MAILER-DAEMON@relay\r\nTo: printers@example.com\r\nSubject: Undelivered\r\n\r\nX-Postfix-Queue-ID: ABC123\r\nFinal-Recipient: rfc822; user@example.org\r\n'
for notice_sender in MAILER-DAEMON double-bounce@relay.example.com; do
    MIME=$NOTICE
    run_send "$notice_sender" printers@example.com
    check "$notice_sender notice exits 69 so that Postfix logs it" "69" "$(cat "$TMP/exit")"
    if grep -q 'FAILURE NOTICE NOT SENT to printers@example.com.*ABC123.*user@example.org' "$TMP/stderr"; then
        echo "PASS: $notice_sender notice is logged with what failed"; pass=$((pass+1))
    else
        echo "FAIL: $notice_sender notice is logged with what failed: $(cat "$TMP/stderr")"; fail=$((fail+1))
    fi
done
check "notices never reach Graph" "$before" "$(grep -c sendMail "$TMP/requests.jsonl")"
rm -f "$TMP/token"
run_send MAILER-DAEMON printers@example.com
check "notice is reported even without a token" "69" "$(cat "$TMP/exit")"
printf '%s' "test-token-123" > "$TMP/token"

# --- with a configured mailbox, a bounce goes there as the configured sender --
run_notice() { # run_notice <sender>
    MIME=$'From: MAILER-DAEMON@relay (Mail Delivery System)\r\nTo: printers@example.com\r\nSubject: Undelivered\r\n\r\nTo: body line\r\nX-Postfix-Queue-ID: ABC123\r\nFinal-Recipient: rfc822; user@example.org\r\n'
    printf '%s' "$MIME" | \
        TOKEN_FILE="$TMP/token" GRAPH_ENDPOINT="http://127.0.0.1:$PORT/v1.0" \
        FAILURE_NOTICE_MAILBOX=notices@example.com FAILURE_NOTICE_SENDER=noreply@example.com \
        bash scripts/graph-send.sh "$1" printers@example.com 2>"$TMP/stderr"
    echo "$?" > "$TMP/exit"
}
run_notice MAILER-DAEMON
check "bounce with a configured mailbox exits 0" "0" "$(cat "$TMP/exit")"
check "bounce is sent as the configured sender" \
    "/v1.0/users/noreply@example.com/sendMail" "$(req_field path)"
req_field body | base64 -d > "$TMP/decoded" 2>/dev/null
check "bounce gets the configured sender in From" "From: noreply@example.com" \
    "$(grep -i '^From:' "$TMP/decoded" | tr -d '\r')"
check "bounce goes only to the configured mailbox" $'To: notices@example.com\nTo: body line' \
    "$(grep -i '^To:' "$TMP/decoded" | tr -d '\r')"
if grep -qi '^Bcc:' "$TMP/decoded"; then
    echo "FAIL: original sender is not added as Bcc"; fail=$((fail+1))
else
    echo "PASS: original sender is not added as Bcc"; pass=$((pass+1))
fi

echo 403 > "$TMP/status"
run_notice MAILER-DAEMON
check "refused notice exits 69" "69" "$(cat "$TMP/exit")"
if grep -q 'FAILURE NOTICE NOT SENT to notices@example.com.*ABC123.*HTTP 403' "$TMP/stderr"; then
    echo "PASS: refused notice is logged with what failed"; pass=$((pass+1))
else
    echo "FAIL: refused notice is logged with what failed: $(cat "$TMP/stderr")"; fail=$((fail+1))
fi
echo 503 > "$TMP/status"
run_notice MAILER-DAEMON
check "notice is retried during a Graph outage" "75" "$(cat "$TMP/exit")"
echo 202 > "$TMP/status"

before=$(grep -c sendMail "$TMP/requests.jsonl")
run_notice double-bounce@relay.example.com
check "postmaster notice is never mailed" "$before" "$(grep -c sendMail "$TMP/requests.jsonl")"
check "postmaster notice exits 69" "69" "$(cat "$TMP/exit")"
MIME=$'From: printers@example.com\r\nTo: user@example.org\r\nSubject: scan\r\n\r\nhello scan\r\n'

# --- graph-size-test.sh reports what Graph accepts --------------------------
printf '#!/bin/bash\nexec bash scripts/graph-send.sh "$@"\n' > "$TMP/graph-send"
chmod +x "$TMP/graph-send"
size_test() {
    TOKEN_FILE="$TMP/token" GRAPH_ENDPOINT="http://127.0.0.1:$PORT/v1.0" \
    GRAPH_SEND="$TMP/graph-send" \
        bash scripts/graph-size-test.sh printers@example.com user@example.org 1 2 2>&1
}
echo 2500000 > "$TMP/max_body"   # 1 MB attachment fits, 2 MB does not
out=$(size_test); code=$?
check "size test fails when a size is refused" "1" "$code"
case "$out" in
    *"1 MB attachment"*"accepted by Graph"*"2 MB attachment"*"NOT ACCEPTED"*"MESSAGE TOO LARGE"*)
        echo "PASS: size test reports each size and the reason"; pass=$((pass+1)) ;;
    *) echo "FAIL: size test reports each size and the reason:"; printf '%s\n' "$out"; fail=$((fail+1)) ;;
esac
rm -f "$TMP/max_body"
out=$(size_test); code=$?
check "size test passes when every size is accepted" "0" "$code"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
