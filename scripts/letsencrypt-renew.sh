#!/bin/sh
# Runs in the certbot sidecar (compose profile "letsencrypt"). Obtains a certificate
# for POSTFIX_HOSTNAME through a Cloudflare DNS challenge and renews it when due. The
# relay notices a new certificate in the shared volume and loads it.
#
# RSA, because older printers may not handle ECDSA. A failed attempt retries after an
# hour: Let's Encrypt limits failed validations per hostname, and the relay keeps
# serving its current certificate in the meantime.
set -u

credentials=/run/cloudflare.ini
server="${LETSENCRYPT_SERVER:-https://acme-v02.api.letsencrypt.org/directory}"

if [ -z "${POSTFIX_HOSTNAME:-}" ]; then
    echo "FATAL: POSTFIX_HOSTNAME is not set." >&2
    exit 1
fi
if [ ! -f "$credentials" ]; then
    echo "FATAL: cloudflare.ini is missing. Copy cloudflare.ini.example and add the token." >&2
    exit 1
fi

while true; do
    if timeout 600 certbot certonly --non-interactive --agree-tos \
        --register-unsafely-without-email --server "$server" \
        --dns-cloudflare --dns-cloudflare-credentials "$credentials" \
        --dns-cloudflare-propagation-seconds 30 \
        --key-type rsa --rsa-key-size 2048 \
        --cert-name "$POSTFIX_HOSTNAME" -d "$POSTFIX_HOSTNAME" --keep-until-expiring; then
        sleep 43200
    else
        echo "WARNING: could not obtain or renew the certificate for $POSTFIX_HOSTNAME; retrying in an hour." >&2
        sleep 3600
    fi
done
