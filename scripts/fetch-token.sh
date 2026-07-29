#!/bin/bash
# One-shot: fetch an app-only (client credentials) access token from Entra ID
# and hand it to the outbound-mode adapter, which owns the token store's
# format and ownership. On success prints the token lifetime in seconds on
# stdout and exits 0; on failure logs the error response (token redacted) to
# stderr and exits 1.
#
# TOKEN_ENDPOINT can be overridden, e.g. to test against a mock endpoint.
set -u

mode="${1:?usage: fetch-token.sh <outbound-mode>}"
adapter="/usr/local/bin/outbound-${mode}.sh"

TOKEN_ENDPOINT="${TOKEN_ENDPOINT:-https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token}"

response=$(curl -s -X POST "$TOKEN_ENDPOINT" \
    -d grant_type=client_credentials \
    -d client_id="${CLIENT_ID}" \
    -d client_secret="${CLIENT_SECRET}" \
    -d scope="$("$adapter" token-scope)")

access_token=$(printf '%s' "$response" | jq -r '.access_token // empty')
expires_in=$(printf '%s' "$response" | jq -r '.expires_in // 3600')

if [ -z "$access_token" ]; then
    echo "fetch-token: ERROR: $(printf '%s' "$response" | jq -c 'del(.access_token)' 2>/dev/null || echo "$response")" >&2
    exit 1
fi

"$adapter" write-token "$access_token" "$expires_in" || exit 1

echo "$expires_in"
