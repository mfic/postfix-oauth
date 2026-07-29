#!/bin/bash
# Keeps the outbound mode's token store fresh: calls the one-shot
# fetch-token.sh, sleeps until well before expiry, repeats. Retries every
# 60s on failure.
#
#   token-refresher.sh <outbound-mode>
set -u

mode="${1:?usage: token-refresher.sh <outbound-mode>}"

while true; do
    if expires_in=$(/usr/local/bin/fetch-token.sh "$mode"); then
        echo "token-refresher: new access token, valid for ${expires_in}s"
        sleep_for=$(( expires_in - 600 ))
        [ "$sleep_for" -lt 60 ] && sleep_for=60
    else
        sleep_for=60
    fi
    sleep "$sleep_for"
done
