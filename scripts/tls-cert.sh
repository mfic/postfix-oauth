#!/bin/bash
# Chooses the certificate Postfix serves and keeps it current. In order:
#   1. /config/tls/cert.pem + key.pem, mounted by the operator
#   2. the Let's Encrypt sidecar's certificate, when its compose profile is on
#   3. a self-signed certificate, generated here
#
#   tls-cert.sh install   once at boot; config errors are FATAL
#   tls-cert.sh watch     forever; installs a changed certificate and reloads Postfix
set -u

CERT=/etc/postfix/cert.pem
KEY=/etc/postfix/key.pem
SOURCE_MARK=/etc/postfix/cert.source
MOUNT_DIR=/config/tls
LETSENCRYPT_DIR="/etc/letsencrypt/live/${POSTFIX_HOSTNAME:-}"
WATCH_SECONDS="${TLS_WATCH_SECONDS:-300}"
EXPIRY_WARNING_SECONDS=$((14 * 86400))

src_name=""; src_cert=""; src_key=""

# The same setting starts the sidecar, so the two can't disagree.
letsencrypt_on() {
    case ",${COMPOSE_PROFILES:-}," in *,letsencrypt,*) return 0 ;; esac
    return 1
}

find_source() { # sets src_*; fails when no operator or Let's Encrypt certificate exists
    if [ -f "$MOUNT_DIR/cert.pem" ] && [ -f "$MOUNT_DIR/key.pem" ]; then
        src_name="config/tls"; src_cert="$MOUNT_DIR/cert.pem"; src_key="$MOUNT_DIR/key.pem"
    elif letsencrypt_on && [ -f "$LETSENCRYPT_DIR/fullchain.pem" ] && [ -f "$LETSENCRYPT_DIR/privkey.pem" ]; then
        src_name="Let's Encrypt"; src_cert="$LETSENCRYPT_DIR/fullchain.pem"; src_key="$LETSENCRYPT_DIR/privkey.pem"
    else
        return 1
    fi
}

pair_matches() { # pair_matches <cert> <key>
    local from_cert from_key
    from_cert=$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null | sha256sum) || return 1
    from_key=$(openssl pkey -in "$2" -pubout 2>/dev/null | sha256sum) || return 1
    # sha256sum of nothing: a file that isn't a certificate or key
    [ "$from_cert" = "$from_key" ] && [ "$from_cert" != "$(printf '' | sha256sum)" ]
}

install_source() { # both files move into place, so a new smtpd never reads half a file
    install -m 644 "$src_cert" "$CERT.new" && install -m 600 "$src_key" "$KEY.new" \
        && mv "$KEY.new" "$KEY" && mv "$CERT.new" "$CERT" \
        && printf '%s\n' "$src_name" > "$SOURCE_MARK"
}

describe() { openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | sed 's/^notAfter=/expires /'; }

warn_if_expiring() {
    openssl x509 -in "$CERT" -noout -checkend "$EXPIRY_WARNING_SECONDS" >/dev/null 2>&1 && return 0
    echo "WARNING: the TLS certificate from $(cat "$SOURCE_MARK") $(describe), in less than 14 days." >&2
}

install_at_boot() {
    if { [ -f "$MOUNT_DIR/cert.pem" ] && [ ! -f "$MOUNT_DIR/key.pem" ]; } \
        || { [ ! -f "$MOUNT_DIR/cert.pem" ] && [ -f "$MOUNT_DIR/key.pem" ]; }; then
        echo "FATAL: /config/tls needs both cert.pem and key.pem." >&2
        exit 1
    fi
    if letsencrypt_on; then
        if [ -f "$MOUNT_DIR/cert.pem" ]; then
            echo "FATAL: /config/tls is set and so is the letsencrypt profile. Use one." >&2
            exit 1
        fi
        case "${POSTFIX_HOSTNAME:-}" in
            *.local|*.localdomain|*.internal|*.lan|"")
                bad_name=yes ;;
            *.*) bad_name=no ;;
            *) bad_name=yes ;;
        esac
        if [ "$bad_name" = yes ]; then
            echo "FATAL: the letsencrypt profile needs POSTFIX_HOSTNAME in a public domain, not '${POSTFIX_HOSTNAME:-}'." >&2
            exit 1
        fi
    fi

    if find_source; then
        if pair_matches "$src_cert" "$src_key"; then
            install_source || { echo "FATAL: could not install the certificate from $src_name." >&2; exit 1; }
            echo "TLS certificate: $src_name, $(describe)."
            warn_if_expiring
            return 0
        fi
        if [ "$src_name" = "config/tls" ]; then
            echo "FATAL: /config/tls/cert.pem and key.pem are unreadable or don't belong together." >&2
            exit 1
        fi
        echo "WARNING: the certificate from $src_name and its key don't belong together; not using them." >&2
    fi

    # A certificate left from another source would otherwise survive a restart.
    if [ ! -f "$CERT" ] || [ "$(cat "$SOURCE_MARK" 2>/dev/null)" != "self-signed" ]; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=${POSTFIX_HOSTNAME}" \
            -keyout "$KEY" -out "$CERT" 2>/dev/null
        chmod 600 "$KEY"
        printf 'self-signed\n' > "$SOURCE_MARK"
    fi
    if letsencrypt_on; then
        echo "TLS certificate: self-signed, until the Let's Encrypt sidecar has obtained one."
    else
        echo "TLS certificate: self-signed, $(describe)."
    fi
}

watch_forever() {
    local warned_on="" today
    while true; do
        sleep "$WATCH_SECONDS"
        if find_source && ! { cmp -s "$src_cert" "$CERT" && cmp -s "$src_key" "$KEY"; }; then
            if ! pair_matches "$src_cert" "$src_key"; then
                echo "WARNING: the certificate from $src_name and its key don't belong together; keeping the current one." >&2
            elif install_source && postfix reload >/dev/null 2>&1; then
                echo "TLS certificate: installed a new one from $src_name, $(describe)."
            else
                echo "WARNING: could not install the new certificate from $src_name." >&2
            fi
        fi
        today=$(date +%F)
        if [ "$today" != "$warned_on" ] && [ "$(cat "$SOURCE_MARK" 2>/dev/null)" != "self-signed" ]; then
            warn_if_expiring
            warned_on=$today
        fi
    done
}

case "${1:-}" in
    install) install_at_boot ;;
    watch) watch_forever ;;
    *) echo "usage: tls-cert.sh install|watch" >&2; exit 64 ;;
esac
