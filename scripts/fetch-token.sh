#!/bin/bash
# One-shot: fetch an app-only (client credentials) access token from Entra ID
# and write the sasl-xoauth2 token file atomically. On success prints the
# token lifetime in seconds on stdout and exits 0; on failure logs the error
# response (token redacted) to stderr and exits 1.
#
# TOKEN_ENDPOINT and TOKEN_FILE can be overridden, e.g. to test against a
# mock endpoint.
set -u

TOKEN_FILE="${TOKEN_FILE:-/etc/tokens/token}"
TOKEN_ENDPOINT="${TOKEN_ENDPOINT:-https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token}"

response=$(curl -s -X POST "$TOKEN_ENDPOINT" \
    -d grant_type=client_credentials \
    -d client_id="${CLIENT_ID}" \
    -d client_secret="${CLIENT_SECRET}" \
    -d scope=https://outlook.office365.com/.default)

access_token=$(printf '%s' "$response" | jq -r '.access_token // empty')
expires_in=$(printf '%s' "$response" | jq -r '.expires_in // 3600')

if [ -z "$access_token" ]; then
    echo "fetch-token: ERROR: $(printf '%s' "$response" | jq -c 'del(.access_token)' 2>/dev/null || echo "$response")" >&2
    exit 1
fi

umask 077
expiry=$(( $(date +%s) + expires_in ))
printf '{"access_token": "%s", "refresh_token": "client_credentials", "expiry": "%s"}\n' \
    "$access_token" "$expiry" > "${TOKEN_FILE}.tmp"
chown postfix:postfix "${TOKEN_FILE}.tmp" 2>/dev/null || true
mv -f "${TOKEN_FILE}.tmp" "$TOKEN_FILE"

echo "$expires_in"
