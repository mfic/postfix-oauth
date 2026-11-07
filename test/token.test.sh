#!/usr/bin/env bash
# Unit tests for scripts/fetch-token.sh and scripts/token-refresher.sh: what each
# failure does, and that no secret reaches the log. Runs on the host against a
# local mock token endpoint (test/mock-graph.py), with a stub adapter and a stub
# sleep. Needs bash, curl, python3 and jq.
#
#   bash test/token.test.sh
set -u
cd "$(dirname "$0")/.." || exit 1

# Without jq, fetch-token.sh takes its error path for every response
command -v jq >/dev/null || { echo "FAIL: this test needs jq, as the relay image has"; exit 1; }

PORT=18322
SECRET=fake-client-secret-do-not-log
TOKEN=fake-access-token-do-not-log
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

mkdir "$TMP/adapters"
cat > "$TMP/adapters/outbound-stub.sh" <<EOF
#!/bin/bash
case "\$1" in
token-scope) echo "stub-scope/.default" ;;
write-token)
    printf '%s\n' "\$*" >> "$TMP/adapter-argv"
    printf '%s %s\n' "\$(cat)" "\$2" >> "$TMP/written"
    exit \$(cat "$TMP/write-status")
    ;;
esac
EOF
chmod +x "$TMP/adapters/outbound-stub.sh"
echo 0 > "$TMP/write-status"

# A stand-in curl records its command line, which any user in the container can read
real_curl=$(command -v curl)
mkdir "$TMP/spy"
cat > "$TMP/spy/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$TMP/curl-argv"
exec "$real_curl" "\$@"
EOF
chmod +x "$TMP/spy/curl"

pass=0; fail=0
check() { # check <name> <expected> <actual>
    if [ "$3" = "$2" ]; then
        echo "PASS: $1"; pass=$((pass+1))
    else
        echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; fail=$((fail+1))
    fi
}
# A native Windows jq ends its lines in CRLF, which $(...) only half removes
text() { tr -d '\r' < "$1"; }
logged() { grep -qF -- "$1" "$TMP/out" "$TMP/err"; } # logged <text>: on stdout or stderr
logs() { # logs <name> <text>
    if logged "$2"; then
        echo "PASS: $1"; pass=$((pass+1))
    else
        echo "FAIL: $1: $(cat "$TMP/out" "$TMP/err")"; fail=$((fail+1))
    fi
}
keeps_out() { # keeps_out <name> <text>
    if logged "$2"; then
        echo "FAIL: $1: $(cat "$TMP/out" "$TMP/err")"; fail=$((fail+1))
    else
        echo "PASS: $1"; pass=$((pass+1))
    fi
}

off_command_line() { # off_command_line <name> <text> <argv file>
    if [ ! -s "$3" ]; then
        echo "FAIL: $1: nothing recorded in $3"; fail=$((fail+1))
    elif grep -qF -- "$2" "$3"; then
        echo "FAIL: $1: $(cat "$3")"; fail=$((fail+1))
    else
        echo "PASS: $1"; pass=$((pass+1))
    fi
}

respond() { printf '%s\n%s' "$1" "$2" > "$TMP/token_response"; } # respond <status> <body>
fetch() { # fetch [<endpoint>]; leaves $TMP/out, err, exit and written
    : > "$TMP/written"
    PATH="$TMP/spy:$PATH" TENANT_ID=fake-tenant CLIENT_ID=fake-client-id CLIENT_SECRET="$SECRET" \
        TOKEN_ENDPOINT="${1:-http://127.0.0.1:$PORT/token}" OUTBOUND_ADAPTER_DIR="$TMP/adapters" \
        bash scripts/fetch-token.sh "${MODE:-stub}" > "$TMP/out" 2> "$TMP/err"
    echo "$?" > "$TMP/exit"
}
fails_cleanly() { # fails_cleanly <case>: the last fetch failed, before the adapter's write-token
    check "$1: exits 1" "1" "$(text "$TMP/exit")"
    check "$1: prints no lifetime" "" "$(text "$TMP/out")"
    check "$1: adapter gets no token" "" "$(text "$TMP/written")"
    logs "$1: logs an error" "fetch-token: ERROR"
    keeps_out "$1: client secret stays out of the log" "$SECRET"
}

# --- success: the adapter gets the token, the caller the lifetime -------------
respond 200 "{\"access_token\": \"$TOKEN\", \"expires_in\": 4242}"
fetch
check "success exits 0" "0" "$(text "$TMP/exit")"
check "success prints the lifetime" "4242" "$(text "$TMP/out")"
check "adapter gets the token and lifetime" "$TOKEN 4242" "$(text "$TMP/written")"
keeps_out "success: client secret stays out of the log" "$SECRET"
keeps_out "success: token stays out of the log" "$TOKEN"
# The checks above and below mean something only if curl really had the secret
request=$(tail -n 1 "$TMP/requests.jsonl")
case "$request" in
    *"client_secret=$SECRET"*) echo "PASS: the secret was sent to the endpoint"; pass=$((pass+1)) ;;
    *) echo "FAIL: the secret was sent to the endpoint: $request"; fail=$((fail+1)) ;;
esac
case "$request" in
    *"scope=stub-scope/.default"*) echo "PASS: the request asks for the adapter's scope"; pass=$((pass+1)) ;;
    *) echo "FAIL: the request asks for the adapter's scope: $request"; fail=$((fail+1)) ;;
esac

off_command_line "client secret stays off curl's command line" "$SECRET" "$TMP/curl-argv"
off_command_line "token stays off the adapter's command line" "$TOKEN" "$TMP/adapter-argv"

# A secret is one value, whatever characters Entra gave it
ordinary_secret=$SECRET
SECRET='a+b&c=d%e f~g'
fetch
request=$(tail -n 1 "$TMP/requests.jsonl")
case "$request" in
    *'client_secret=a%2Bb%26c%3Dd%25e%20f~g&'*|*'client_secret=a%2Bb%26c%3Dd%25e+f~g&'*)
        echo "PASS: the secret is URL-encoded, with nothing added"; pass=$((pass+1)) ;;
    *) echo "FAIL: the secret is URL-encoded, with nothing added: $request"; fail=$((fail+1)) ;;
esac
SECRET=$ordinary_secret

# --- Entra refuses ------------------------------------------------------------
respond 401 '{"error": "invalid_client", "error_description": "AADSTS7000215: fake refusal"}'
fetch
fails_cleanly "error response"
logs "error response: logs Entra's description" "AADSTS7000215: fake refusal"
logs "error response: logs the status" "HTTP 401"

respond 400 '{"error": "invalid_request", "debug": "UNEXPECTED-FIELD"}'
fetch
fails_cleanly "error response with other fields"
logs "error response with other fields: logs the error" "invalid_request"
keeps_out "error response with other fields: logs nothing else" "UNEXPECTED-FIELD"

# --- responses that aren't a token, and no response ---------------------------
respond 502 '<html>502 Bad Gateway</html>'
fetch
fails_cleanly "non-JSON response"
logs "non-JSON response: logs the status" "HTTP 502"
logs "non-JSON response: logs the size" "28 bytes"
keeps_out "non-JSON response: logs none of it" "Bad Gateway"

respond 200 ''
fetch
fails_cleanly "empty response"

fetch "http://127.0.0.1:1/token"
fails_cleanly "nothing listening"
logs "nothing listening: logs that there was no status" "HTTP 000"

# --- a reply that holds the token, but not usably: it must stay out of the log --
for body in "{\"access_token\": \"$TOKEN\", \"expires_in\": 36" \
    "{\"access_token\": \"$TOKEN" \
    "{\"token\": \"$TOKEN\"}" \
    "\"$TOKEN\"" \
    "[\"$TOKEN\"]"; do
    respond 200 "$body"
    fetch
    fails_cleanly "reply <$body>"
    keeps_out "reply <$body>: token stays out of the log" "$TOKEN"
done

# --- an unusable lifetime: the token is good, and the refresher must survive ----
for lifetime in '"soon"' '""' '-1' '0' '"0100"' '1.5' '99999999999999' 'true'; do
    respond 200 "{\"access_token\": \"$TOKEN\", \"expires_in\": $lifetime}"
    fetch
    check "expires_in $lifetime: exits 0" "0" "$(text "$TMP/exit")"
    check "expires_in $lifetime: assumes an hour" "3600" "$(text "$TMP/out")"
    check "expires_in $lifetime: adapter gets the token" "$TOKEN 3600" "$(text "$TMP/written")"
    logs "expires_in $lifetime: warns" "fetch-token: WARNING"
done
respond 200 "{\"access_token\": \"$TOKEN\", \"expires_in\": \"4242\"}"
fetch
check "expires_in as a numeric string is used" "4242" "$(text "$TMP/out")"
keeps_out "and isn't warned about" "WARNING"

# --- a token arrives, and storing it fails ------------------------------------
respond 200 "{\"access_token\": \"$TOKEN\", \"expires_in\": 4242}"
echo 1 > "$TMP/write-status"
fetch
check "write-token failure exits 1" "1" "$(text "$TMP/exit")"
check "write-token failure prints no lifetime" "" "$(text "$TMP/out")"
check "write-token was tried" "$TOKEN 4242" "$(text "$TMP/written")"
keeps_out "write-token failure: token stays out of the log" "$TOKEN"
keeps_out "write-token failure: client secret stays out of the log" "$SECRET"
echo 0 > "$TMP/write-status"

# The real adapters too, whose failure comes with the shell's own error message.
# A checkout may have no executable bit, so they run from a copy.
cp scripts/outbound-graph.sh scripts/outbound-smtp.sh "$TMP/adapters/"
chmod +x "$TMP/adapters/"outbound-*.sh
for MODE in graph smtp; do
    TOKEN_FILE="$TMP/no-such-dir/token" fetch
    check "$MODE adapter that can't store the token: exits 1" "1" "$(text "$TMP/exit")"
    keeps_out "$MODE adapter that can't store the token: token stays out of the log" "$TOKEN"
done
unset MODE

# Both adapters store the token they get on stdin, in their own format
respond 200 "{\"access_token\": \"$TOKEN\", \"expires_in\": 4242}"
MODE=graph TOKEN_FILE="$TMP/store-graph" fetch
check "graph adapter stores the raw token" "$TOKEN" "$(cat "$TMP/store-graph" 2>/dev/null)"
MODE=smtp TOKEN_FILE="$TMP/store-smtp" fetch
check "smtp adapter stores the token as JSON" "$TOKEN" "$(jq -r .access_token "$TMP/store-smtp" 2>/dev/null | tr -d '\r')"

# An adapter given no token keeps the store it has
printf 'older' > "$TMP/store-graph"
printf '' | TOKEN_FILE="$TMP/store-graph" bash "$TMP/adapters/outbound-graph.sh" write-token 4242 2>/dev/null
check "graph adapter refuses an empty token" "1 older" "$? $(cat "$TMP/store-graph")"
printf 'older' > "$TMP/store-smtp"
printf '' | TOKEN_FILE="$TMP/store-smtp" bash "$TMP/adapters/outbound-smtp.sh" write-token 4242 2>/dev/null
check "smtp adapter refuses an empty token" "1 older" "$? $(cat "$TMP/store-smtp")"

# --- token-refresher.sh -------------------------------------------------------
# Each stub fetch-token call takes the next line of the plan. The stub sleep
# records its argument and, once the plan is used up, ends the loop. timeout only
# guards against a loop that doesn't end, which leaves too few sleeps recorded.
cat > "$TMP/fetch-token" <<EOF
#!/bin/bash
echo "\$1" > "$TMP/refresher-mode"
next=\$(head -n 1 "$TMP/plan")
sed -i 1d "$TMP/plan"
[ "\$next" != fail ] || exit 1
echo "\$next"
EOF
mkdir "$TMP/bin"
cat > "$TMP/bin/sleep" <<EOF
#!/bin/bash
echo "\$1" >> "$TMP/slept"
[ -s "$TMP/plan" ] || kill "\$PPID"
EOF
chmod +x "$TMP/fetch-token" "$TMP/bin/sleep"

refresh() { # refresh <lifetime or "fail">...; leaves the sleeps in $TMP/slept
    printf '%s\n' "$@" > "$TMP/plan"
    : > "$TMP/slept"
    # The subshell's stderr is where bash reports the killed loop as "Terminated"
    (PATH="$TMP/bin:$PATH" FETCH_TOKEN="$TMP/fetch-token" \
        timeout 20 bash scripts/token-refresher.sh stub > "$TMP/out" 2> "$TMP/err" || :) 2>/dev/null
}
slept() { tr -d '\r' < "$TMP/slept" | tr '\n' ' '; }

refresh fail fail 3600
check "refresher retries after 60s, then sleeps until 600s before expiry" "60 60 3000 " "$(slept)"
check "refresher passes on the mode" "stub" "$(text "$TMP/refresher-mode")"
logs "refresher logs the new token's lifetime" "new access token, valid for 3600s"

refresh 300
check "refresher sleeps at least 60s, even for a short lifetime" "60 " "$(slept)"

# With the real fetch-token.sh: an unusable lifetime used to end the refresher
cat > "$TMP/real-fetch-token" <<'EOF'
#!/bin/bash
exec bash scripts/fetch-token.sh "$@"
EOF
chmod +x "$TMP/real-fetch-token"
respond 200 "{\"access_token\": \"$TOKEN\", \"expires_in\": \"soon\"}"
: > "$TMP/plan"; : > "$TMP/slept"; : > "$TMP/written"
(PATH="$TMP/bin:$PATH" FETCH_TOKEN="$TMP/real-fetch-token" OUTBOUND_ADAPTER_DIR="$TMP/adapters" \
    TENANT_ID=fake-tenant CLIENT_ID=fake-client-id CLIENT_SECRET="$SECRET" TOKEN_ENDPOINT="http://127.0.0.1:$PORT/token" \
    timeout 20 bash scripts/token-refresher.sh stub > "$TMP/out" 2> "$TMP/err" || :) 2>/dev/null
check "refresher survives an unusable lifetime" "3000 " "$(slept)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
