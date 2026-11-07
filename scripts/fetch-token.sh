#!/bin/bash
# One-shot: fetch an app-only (client credentials) access token from Entra ID
# and hand it to the outbound-mode adapter, which owns the token store's
# format and ownership. On success prints the token lifetime in seconds on
# stdout and exits 0; on failure logs the HTTP status and Entra's error fields
# to stderr and exits 1.
#
# Any user in the container can read a process's command line, so the client
# secret and the token only travel over stdin. A reply that isn't an error from
# Entra may hold the token in any shape, so only its size is logged.
#
# TOKEN_ENDPOINT and OUTBOUND_ADAPTER_DIR can be overridden, e.g. for tests.
set -u

mode="${1:?usage: fetch-token.sh <outbound-mode>}"
adapter="${OUTBOUND_ADAPTER_DIR:-/usr/local/bin}/outbound-${mode}.sh"

TOKEN_ENDPOINT="${TOKEN_ENDPOINT:-https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token}"

scope=$("$adapter" token-scope)
response=$(printf '%s' "$CLIENT_SECRET" | curl -s -X POST -w '\n%{http_code}' "$TOKEN_ENDPOINT" \
    -d grant_type=client_credentials \
    -d client_id="${CLIENT_ID}" \
    --data-urlencode client_secret@- \
    -d scope="$scope")
status=${response##*$'\n'}
response=${response%$'\n'*}

access_token=$(printf '%s' "$response" | jq -r '.access_token // empty' 2>/dev/null)
expires_in=$(printf '%s' "$response" | jq -r '.expires_in // 3600' 2>/dev/null)

if [ -z "$access_token" ]; then
    reason=$(printf '%s' "$response" | jq -ce \
        'select(type == "object" and (.error or .error_description)) | {error, error_description}' 2>/dev/null) \
        || reason="no error from Entra, $(printf '%s' "$response" | wc -c) bytes"
    echo "fetch-token: ERROR: HTTP $status: $reason" >&2
    exit 1
fi

# The token is good, and the callers do arithmetic with this. Nine digits and no
# leading zero is all a lifetime needs, and all that bash reads as a plain number.
if ! [[ "$expires_in" =~ ^[1-9][0-9]{0,8}$ ]]; then
    echo "fetch-token: WARNING: unusable expires_in in the token response, assuming 3600s" >&2
    expires_in=3600
fi

printf '%s' "$access_token" | "$adapter" write-token "$expires_in" || exit 1

echo "$expires_in"
