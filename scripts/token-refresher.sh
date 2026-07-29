#!/bin/bash
# Fetches app-only (client credentials) access tokens from Entra ID and keeps
# the sasl-xoauth2 token file fresh. sasl-xoauth2 itself only knows how to use
# refresh tokens, so we refresh externally and it just consumes the token.
set -u

TOKEN_FILE=/etc/tokens/token
TOKEN_ENDPOINT="https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"

while true; do
    response=$(curl -s -X POST "$TOKEN_ENDPOINT" \
        -d grant_type=client_credentials \
        -d client_id="${CLIENT_ID}" \
        -d client_secret="${CLIENT_SECRET}" \
        -d scope=https://outlook.office365.com/.default)

    access_token=$(printf '%s' "$response" | jq -r '.access_token // empty')
    expires_in=$(printf '%s' "$response" | jq -r '.expires_in // 3600')

    if [ -n "$access_token" ]; then
        expiry=$(( $(date +%s) + expires_in ))
        umask 077
        printf '{"access_token": "%s", "refresh_token": "client_credentials", "expiry": "%s"}\n' \
            "$access_token" "$expiry" > "${TOKEN_FILE}.tmp"
        chown postfix:postfix "${TOKEN_FILE}.tmp"
        mv -f "${TOKEN_FILE}.tmp" "$TOKEN_FILE"
        echo "token-refresher: new access token, valid for ${expires_in}s"
        # refresh well before expiry
        sleep_for=$(( expires_in - 600 ))
        [ "$sleep_for" -lt 60 ] && sleep_for=60
    else
        echo "token-refresher: ERROR fetching token: $(printf '%s' "$response" | jq -c 'del(.access_token)' 2>/dev/null || echo "$response")" >&2
        sleep_for=60
    fi

    sleep "$sleep_for"
done
