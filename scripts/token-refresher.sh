#!/bin/bash
# Keeps the sasl-xoauth2 token file fresh: calls the one-shot fetch-token.sh,
# sleeps until well before expiry, repeats. Retries every 60s on failure.
set -u

while true; do
    if expires_in=$(/usr/local/bin/fetch-token.sh); then
        echo "token-refresher: new access token, valid for ${expires_in}s"
        sleep_for=$(( expires_in - 600 ))
        [ "$sleep_for" -lt 60 ] && sleep_for=60
    else
        sleep_for=60
    fi
    sleep "$sleep_for"
done
