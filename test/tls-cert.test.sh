#!/usr/bin/env bash
# Unit tests for scripts/tls-cert.sh - which certificate is chosen, what stops a
# boot, and what the watcher does on each pass. Runs on the host with real openssl
# and a stub postfix, no Docker. That a real client is served the certificate, and
# that a real reload picks it up, is shown in smoke.sh.
#
#   bash test/tls-cert.test.sh
set -u
cd "$(dirname "$0")/.." || exit 1

# git-bash's openssl is a native Windows program. MSYS_NO_PATHCONV stops the -subj
# value being rewritten, but also the paths, so those are C:/... there. That form
# can't go in PATH, because of its colon.
STUB_ROOT=$(mktemp -d)
TMP=$STUB_ROOT
if command -v cygpath >/dev/null; then TMP=$(cygpath -m "$STUB_ROOT"); fi
trap 'rm -rf "$TMP"' EXIT

mkdir "$TMP/bin" "$TMP/watch-bin" "$TMP/certs"
PATH="$STUB_ROOT/bin:$PATH"

cat > "$TMP/bin/postfix" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$TMP/postfix-calls"
exit \$(cat "$TMP/postfix-status")
EOF
# For the real watch loop: sleep counts the passes and ends the loop after the last
# one, date gives each pass its line of $TMP/days.
cat > "$TMP/watch-bin/sleep" <<EOF
#!/bin/bash
echo "\$1" > "$TMP/sleep-arg"
pass=\$((\$(cat "$TMP/passes") + 1))
echo "\$pass" > "$TMP/passes"
if [ "\$pass" -gt "\$(cat "$TMP/last-pass")" ]; then kill "\$PPID"; fi
EOF
cat > "$TMP/watch-bin/date" <<EOF
#!/bin/bash
sed -n "\$(cat "$TMP/passes")p" "$TMP/days"
EOF
chmod +x "$TMP/bin/postfix" "$TMP/watch-bin/sleep" "$TMP/watch-bin/date"

pass=0; fail=0
check() { # check <name> <expected> <actual>
    if [ "$3" = "$2" ]; then
        echo "PASS: $1"; pass=$((pass+1))
    else
        echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; fail=$((fail+1))
    fi
}
logged() { # logged <name> <stream: out|err> <regex>
    if grep -qE -- "$3" "$TMP/$2"; then
        echo "PASS: $1"; pass=$((pass+1))
    else
        echo "FAIL: $1"; echo "  expected /$3/ in std$2:"; sed 's/^/  | /' "$TMP/$2"; fail=$((fail+1))
    fi
}

make_cert() { # make_cert <name> <days>: leaves $TMP/certs/<name>/cert.pem and key.pem
    mkdir -p "$TMP/certs/$1"
    MSYS_NO_PATHCONV=1 openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -days "$2" -subj "/CN=$1.example.test" \
        -keyout "$TMP/certs/$1/key.pem" -out "$TMP/certs/$1/cert.pem" 2>/dev/null
}
# The warning is for less than 14 days, so these two sit on either side of it.
make_cert good 15
make_cert renewed 15
make_cert soon 13
GOOD=$TMP/certs/good; RENEWED=$TMP/certs/renewed; SOON=$TMP/certs/soon

R=$TMP/run
export TLS_CERT_FILE=$R/etc/cert.pem TLS_KEY_FILE=$R/etc/key.pem TLS_SOURCE_MARK=$R/etc/cert.source
export TLS_MOUNT_DIR=$R/mount TLS_LETSENCRYPT_LIVE=$R/live
LE=$R/live/relay.example.com
CERT=$TLS_CERT_FILE; KEY=$TLS_KEY_FILE; MARK=$TLS_SOURCE_MARK

fresh() { # a new container, with the operator's and the sidecar's directories empty
    rm -rf "$R"
    mkdir -p "$R/etc" "$R/mount" "$LE"
    : > "$TMP/postfix-calls"
    echo 0 > "$TMP/postfix-status"
    unset COMPOSE_PROFILES TLS_WATCH_SECONDS
    export POSTFIX_HOSTNAME=relay.example.com
}
letsencrypt_profile() { export COMPOSE_PROFILES=letsencrypt; }
mount_pair() { cp "$1/cert.pem" "$1/key.pem" "$R/mount/"; } # mount_pair <cert dir>
sidecar_pair() { cp "$1/cert.pem" "$LE/fullchain.pem"; cp "$1/key.pem" "$LE/privkey.pem"; } # sidecar_pair <cert dir>
plant_current() { # plant_current <cert dir> <source>: as if an earlier boot installed it
    cp "$1/cert.pem" "$CERT"; cp "$1/key.pem" "$KEY"; echo "$2" > "$MARK"
}

# tls_cert <command>: leaves stdout in $TMP/out, stderr in $TMP/err, exit code in $TMP/exit.
# A watcher that waits or loops where it shouldn't runs into the timeout.
tls_cert() {
    timeout 60 bash scripts/tls-cert.sh "$@" > "$TMP/out" 2> "$TMP/err"
    echo "$?" > "$TMP/exit"
}
out() { cat "$TMP/out"; }
err() { cat "$TMP/err"; }
exit_code() { cat "$TMP/exit"; }
mark() { cat "$MARK" 2>/dev/null; }
reloads() { grep -c '^reload$' "$TMP/postfix-calls"; }
subject() { openssl x509 -in "$CERT" -noout -subject | tr -d ' \r'; }
is_current() { # is_current <cert dir>: prints yes when the cert and key are installed
    if cmp -s "$1/cert.pem" "$CERT" && cmp -s "$1/key.pem" "$KEY"; then echo yes; else echo no; fi
}
pair_valid() { # the installed key belongs to the installed cert
    if [ "$(openssl x509 -in "$CERT" -noout -pubkey | sha256sum)" = "$(openssl pkey -in "$KEY" -pubout | sha256sum)" ]; then
        echo yes
    else
        echo no
    fi
}
expect_fatal() { # expect_fatal <name> <message>: the last boot stopped there, installing nothing
    check "$1: says so" "$2" "$(err)"
    check "$1: stops the boot" 1 "$(exit_code)"
    if [ -e "$CERT" ]; then check "$1: installs nothing" absent present; else check "$1: installs nothing" absent absent; fi
}
EXPIRY_WARNING='^WARNING: the TLS certificate from config/tls expires .* in less than 14 days\.'

# --- which source wins at boot ----------------------------------------------------
fresh; mount_pair "$GOOD"
tls_cert install
check "config/tls is used when mounted" yes "$(is_current "$GOOD")"
check "and is marked as the source" "config/tls" "$(mark)"
check "and the boot succeeds" 0 "$(exit_code)"
logged "and the log names it" out '^TLS certificate: config/tls, expires '

fresh; letsencrypt_profile; sidecar_pair "$GOOD"
tls_cert install
check "Let's Encrypt is used with the profile" yes "$(is_current "$GOOD")"
check "and is marked as the source" "Let's Encrypt" "$(mark)"
logged "and the log names it" out "^TLS certificate: Let's Encrypt, expires "

fresh; export COMPOSE_PROFILES=other,letsencrypt,more; sidecar_pair "$GOOD"
tls_cert install
check "the profile is found in a list" "Let's Encrypt" "$(mark)"

fresh; sidecar_pair "$GOOD"
tls_cert install
check "Let's Encrypt is ignored without the profile" self-signed "$(mark)"
logged "and the log says self-signed" out '^TLS certificate: self-signed, expires '

fresh; export COMPOSE_PROFILES=letsencrypt-old; sidecar_pair "$GOOD"
tls_cert install
check "a profile that only starts the same isn't the profile" self-signed "$(mark)"

fresh; letsencrypt_profile; mkdir -p "$R/live/other.example.com"
cp "$GOOD/cert.pem" "$R/live/other.example.com/fullchain.pem"
cp "$GOOD/key.pem" "$R/live/other.example.com/privkey.pem"
tls_cert install
check "a certificate for another hostname isn't used" self-signed "$(mark)"
check "the log says it waits for the sidecar" \
    "TLS certificate: self-signed, until the Let's Encrypt sidecar has obtained one." "$(out)"
export POSTFIX_HOSTNAME=other.example.com
tls_cert install
check "the sidecar's directory is the one for POSTFIX_HOSTNAME" "Let's Encrypt" "$(mark)"

fresh; letsencrypt_profile; cp "$GOOD/cert.pem" "$LE/fullchain.pem"
tls_cert install
check "half a Let's Encrypt pair isn't used" self-signed "$(mark)"
check "and doesn't stop the boot" 0 "$(exit_code)"

fresh
tls_cert install
check "self-signed comes last" self-signed "$(mark)"
check "it's for POSTFIX_HOSTNAME" "subject=CN=relay.example.com" "$(subject)"
check "its key belongs to it" yes "$(pair_valid)"
check "the boot succeeds" 0 "$(exit_code)"
logged "the log says self-signed" out '^TLS certificate: self-signed, expires '

# --- what stops a boot ------------------------------------------------------------
fresh; cp "$GOOD/cert.pem" "$R/mount/"
tls_cert install
expect_fatal "a certificate without its key" "FATAL: /config/tls needs both cert.pem and key.pem."

fresh; cp "$GOOD/key.pem" "$R/mount/"
tls_cert install
expect_fatal "a key without its certificate" "FATAL: /config/tls needs both cert.pem and key.pem."

MISMATCH="FATAL: /config/tls/cert.pem and key.pem are unreadable or don't belong together."
fresh; cp "$GOOD/cert.pem" "$R/mount/"; cp "$RENEWED/key.pem" "$R/mount/"
tls_cert install
expect_fatal "a mounted key from another certificate" "$MISMATCH"

fresh; echo "not a certificate" > "$R/mount/cert.pem"; echo "not a key" > "$R/mount/key.pem"
tls_cert install
expect_fatal "mounted files that aren't a certificate or key" "$MISMATCH"

fresh; letsencrypt_profile; mount_pair "$GOOD"
tls_cert install
expect_fatal "config/tls with the profile" "FATAL: /config/tls is set and so is the letsencrypt profile. Use one."

for hostname in relay.local relay.localdomain relay.internal relay.lan relay ""; do
    fresh; letsencrypt_profile; export POSTFIX_HOSTNAME=$hostname
    tls_cert install
    expect_fatal "the profile with hostname '$hostname'" \
        "FATAL: the letsencrypt profile needs POSTFIX_HOSTNAME in a public domain, not '$hostname'."
done

fresh; mount_pair "$GOOD"; rm -r "${R:?}/etc"
tls_cert install
logged "a certificate that can't be installed: says so" err '^FATAL: could not install the certificate from config/tls\.$'
check "a certificate that can't be installed: stops the boot" 1 "$(exit_code)"

# --- a private hostname is only a problem with the profile ------------------------
fresh; export POSTFIX_HOSTNAME=relay.local
tls_cert install
check "a private hostname boots without the profile" 0 "$(exit_code)"
check "and gets a certificate" "subject=CN=relay.local" "$(subject)"

# --- a mismatched Let's Encrypt pair at boot only warns --------------------------
fresh; letsencrypt_profile; plant_current "$GOOD" "Let's Encrypt"
cp "$GOOD/cert.pem" "$LE/fullchain.pem"; cp "$RENEWED/key.pem" "$LE/privkey.pem"
tls_cert install
check "a mismatched Let's Encrypt pair doesn't stop the boot" 0 "$(exit_code)"
check "and is warned about" \
    "WARNING: the certificate from Let's Encrypt and its key don't belong together; not using them." "$(err)"
check "and self-signed is used instead" self-signed "$(mark)"
check "with its own key" yes "$(pair_valid)"
check "for POSTFIX_HOSTNAME" "subject=CN=relay.example.com" "$(subject)"

# --- a tick: nothing changed ------------------------------------------------------
fresh; mount_pair "$GOOD"
tls_cert install
tls_cert tick
check "a tick with no change doesn't reload" 0 "$(reloads)"
check "and logs nothing" "" "$(out)$(err)"

# --- a tick: the source changed ---------------------------------------------------
fresh; mount_pair "$GOOD"
tls_cert install
mount_pair "$RENEWED"
tls_cert tick
check "a renewed certificate is installed" yes "$(is_current "$RENEWED")"
check "and Postfix is reloaded once" "reload" "$(cat "$TMP/postfix-calls")"
logged "and the log says so" out '^TLS certificate: installed a new one from config/tls, expires '
tls_cert tick
check "and the next tick has nothing to do" 1 "$(reloads)"

fresh; letsencrypt_profile
tls_cert install
sidecar_pair "$GOOD"
tls_cert tick
check "the sidecar's first certificate replaces self-signed" yes "$(is_current "$GOOD")"
check "and is marked as the source" "Let's Encrypt" "$(mark)"
check "and Postfix is reloaded" 1 "$(reloads)"
logged "and the log says so" out "^TLS certificate: installed a new one from Let's Encrypt, expires "

fresh; letsencrypt_profile; sidecar_pair "$GOOD"
tls_cert install
mount_pair "$RENEWED"
tls_cert tick
check "at a tick, too, config/tls comes before Let's Encrypt" yes "$(is_current "$RENEWED")"
check "and is marked as the source" "config/tls" "$(mark)"

fresh; sidecar_pair "$GOOD"; plant_current "$RENEWED" self-signed
tls_cert tick
check "at a tick, Let's Encrypt is ignored without the profile" yes "$(is_current "$RENEWED")"
check "and nothing is reloaded" 0 "$(reloads)"

# --- a tick: a mismatch keeps the current certificate -----------------------------
fresh; mount_pair "$GOOD"
tls_cert install
cp "$RENEWED/key.pem" "$R/mount/key.pem"
tls_cert tick
check "a mismatch at a tick keeps the current certificate" yes "$(is_current "$GOOD")"
check "and doesn't reload" 0 "$(reloads)"
check "and is warned about" \
    "WARNING: the certificate from config/tls and its key don't belong together; keeping the current one." "$(err)"
mount_pair "$RENEWED"
tls_cert tick
check "and once the pair is fixed it's installed" yes "$(is_current "$RENEWED")"

fresh; letsencrypt_profile; sidecar_pair "$GOOD"
tls_cert install
cp "$RENEWED/key.pem" "$LE/privkey.pem"
tls_cert tick
check "the same for Let's Encrypt" yes "$(is_current "$GOOD")"
check "with a warning" \
    "WARNING: the certificate from Let's Encrypt and its key don't belong together; keeping the current one." "$(err)"

# --- a tick: the install or the reload fails --------------------------------------
fresh; mount_pair "$GOOD"
tls_cert install
mount_pair "$RENEWED"; echo 1 > "$TMP/postfix-status"
tls_cert tick
RELOAD_WARNING="WARNING: the new certificate from config/tls is in place, but Postfix did not reload; trying again."
check "a failed reload is warned about" "$RELOAD_WARNING" "$(err)"
check "and not logged as installed" "" "$(out)"
tls_cert tick
check "the next tick tries again" 2 "$(reloads)"
check "and warns again" "$RELOAD_WARNING" "$(err)"
echo 0 > "$TMP/postfix-status"
tls_cert tick
check "the tick after a reload that works" 3 "$(reloads)"
logged "logs the certificate as installed" out '^TLS certificate: installed a new one from config/tls, expires '
check "and warns no more" "" "$(err)"
tls_cert tick
check "and the next tick has nothing to do" 3 "$(reloads)"

fresh; mount_pair "$GOOD"
tls_cert install
mount_pair "$RENEWED"; echo 1 > "$TMP/postfix-status"
tls_cert tick
echo 0 > "$TMP/postfix-status"
tls_cert install
tls_cert tick
check "a restart settles a reload still owed" 1 "$(reloads)"

fresh; mount_pair "$GOOD"; rm -r "${R:?}/etc"
tls_cert tick
logged "a failed install is warned about" err '^WARNING: could not install the new certificate from config/tls\.$'
check "and doesn't reload" 0 "$(reloads)"

# --- a tick: the source is gone ---------------------------------------------------
fresh; mount_pair "$GOOD"
tls_cert install
rm "$R/mount/cert.pem" "$R/mount/key.pem"
tls_cert tick
check "a removed mount leaves the current certificate" yes "$(is_current "$GOOD")"
check "and its source mark" "config/tls" "$(mark)"
check "and doesn't reload" 0 "$(reloads)"
check "and logs nothing" "" "$(out)$(err)"

fresh; mount_pair "$GOOD"
tls_cert install
rm "$R/mount/key.pem"
tls_cert tick
check "half a mount at a tick leaves the current certificate" yes "$(is_current "$GOOD")"
check "and doesn't reload" 0 "$(reloads)"

fresh; letsencrypt_profile; sidecar_pair "$GOOD"
tls_cert install
rm -r "$LE"
tls_cert tick
check "a removed Let's Encrypt directory leaves the current certificate" yes "$(is_current "$GOOD")"
check "and its source mark" "Let's Encrypt" "$(mark)"
check "and doesn't reload" 0 "$(reloads)"

# --- expiry warnings --------------------------------------------------------------
fresh; mount_pair "$SOON"
tls_cert install
logged "a boot warns within 14 days" err "$EXPIRY_WARNING"
check "and still succeeds" 0 "$(exit_code)"
tls_cert tick
logged "a tick warns within 14 days" err "$EXPIRY_WARNING"

fresh; letsencrypt_profile; sidecar_pair "$SOON"
tls_cert install
logged "the warning names the source" err "^WARNING: the TLS certificate from Let's Encrypt expires "

fresh; mount_pair "$GOOD"
tls_cert install
check "a boot doesn't warn with more than 14 days left" "" "$(err)"
tls_cert tick
check "nor does a tick" "" "$(err)"

fresh; plant_current "$SOON" self-signed
tls_cert install
check "a boot never warns about self-signed" "" "$(err)"
tls_cert tick
check "nor does a tick" "" "$(err)"

# --- the real watch loop: its wait, and one warning a day -------------------------
# run_watch <last pass> <day>...: the loop, with a stub sleep and date
run_watch() {
    local last=$1; shift
    echo 0 > "$TMP/passes"
    echo "$last" > "$TMP/last-pass"
    printf '%s\n' "$@" "$@" > "$TMP/days" # twice, as a stopping loop may start one more pass
    # the 2>: bash's "Terminated" notice, as the stub ends the loop
    PATH="$STUB_ROOT/watch-bin:$PATH" tls_cert watch 2>/dev/null
    check "the watcher ran its $last passes" "$((last + 1))" "$(cat "$TMP/passes")"
}
warnings() { grep -c '^WARNING: the TLS certificate from ' "$TMP/err"; }

fresh; plant_current "$SOON" config/tls; mount_pair "$SOON"
run_watch 3 2026-03-01 2026-03-01 2026-03-01
check "three passes on one day give one warning" 1 "$(warnings)"
check "the wait defaults to 300 seconds" 300 "$(cat "$TMP/sleep-arg")"

fresh; plant_current "$SOON" config/tls; mount_pair "$SOON"
run_watch 4 2026-03-01 2026-03-01 2026-03-02 2026-03-02
check "a new day gives one more warning" 2 "$(warnings)"

fresh; plant_current "$SOON" self-signed
export TLS_WATCH_SECONDS=7
run_watch 2 2026-03-01 2026-03-02
check "the watcher never warns about self-signed" 0 "$(warnings)"
check "the wait comes from TLS_WATCH_SECONDS" 7 "$(cat "$TMP/sleep-arg")"

fresh; plant_current "$GOOD" config/tls; mount_pair "$RENEWED"
run_watch 3 2026-03-01 2026-03-01 2026-03-01
check "the watcher installs a change" yes "$(is_current "$RENEWED")"
check "and reloads once in three passes" 1 "$(reloads)"

# --- self-signed across restarts --------------------------------------------------
fresh
tls_cert install
cp "$CERT" "$TMP/first-cert"
tls_cert install
if cmp -s "$TMP/first-cert" "$CERT"; then same=yes; else same=no; fi
check "self-signed stays across a restart" yes "$same"
logged "and the log still says self-signed" out '^TLS certificate: self-signed, expires '

fresh; mount_pair "$GOOD"
tls_cert install
rm "$R/mount/cert.pem" "$R/mount/key.pem"
tls_cert install
check "a certificate from config/tls doesn't survive a restart" self-signed "$(mark)"
check "the new one is for POSTFIX_HOSTNAME" "subject=CN=relay.example.com" "$(subject)"
check "with its own key" yes "$(pair_valid)"

fresh; letsencrypt_profile; sidecar_pair "$GOOD"
tls_cert install
rm -r "$LE"; unset COMPOSE_PROFILES
tls_cert install
check "a certificate from Let's Encrypt doesn't survive a restart" self-signed "$(mark)"
check "the new one is for POSTFIX_HOSTNAME" "subject=CN=relay.example.com" "$(subject)"

fresh; cp "$GOOD/cert.pem" "$CERT"; cp "$GOOD/key.pem" "$KEY"
tls_cert install
check "a certificate with no source mark doesn't survive a restart" "subject=CN=relay.example.com" "$(subject)"

fresh
tls_cert install
mount_pair "$GOOD"
tls_cert install
check "a mount added before a restart replaces self-signed" yes "$(is_current "$GOOD")"

# --- wrong use --------------------------------------------------------------------
fresh
tls_cert
check "no command is refused" 64 "$(exit_code)"
tls_cert nonsense
check "an unknown command is refused" 64 "$(exit_code)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
