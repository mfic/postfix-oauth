#!/usr/bin/env bash
# Tests for scripts/config-tables.sh, the one reader of the config files. Each
# case writes its config inline, runs the module and checks the tables and
# FATALs. postmap, saslpasswd2 and Debian's mawk exist only in the image, so
# this file copies itself into a throwaway relay container and runs there. No
# stack, no network, nothing mounted.
#
#   ./test/config.test.sh
set -u

if [ "${1:-}" != --in-image ]; then
    cd "$(dirname "$0")/.." || exit 1
    docker compose -p postfix-oauth-test-graph -f test/compose.graph.test.yml build --quiet relay || exit 1
    MSYS_NO_PATHCONV=1 docker run --rm -i --entrypoint bash postfix-oauth-test-graph-relay \
        -c 'cat > /tmp/config.test.sh && exec bash /tmp/config.test.sh --in-image' < test/config.test.sh
    exit $?
fi

export POSTFIX_HOSTNAME=mailrelay.test
MODULE=/usr/local/bin/config-tables.sh
POSTFIX=/etc/postfix
CR=$'\r'
cp "$POSTFIX/main.cf" /tmp/main.cf.orig
DEFAULT_RESTRICTIONS=$(postconf -h smtpd_sender_restrictions)

pass=0; fail=0
check() { # check <name> <expected> <actual>
    if [ "$3" = "$2" ]; then
        echo "PASS: $1"; pass=$((pass+1))
    else
        echo "FAIL: $1"; echo "  expected: $(printf '%q' "$2")"; echo "  actual:   $(printf '%q' "$3")"; fail=$((fail+1))
    fi
}

# A new, valid minimum: one allowed sender and nothing else, as on a fresh container.
fresh() {
    rm -rf /config /etc/sasldb2 "$POSTFIX"/allowed_senders* "$POSTFIX"/client_sender_*
    cp /tmp/main.cf.orig "$POSTFIX/main.cf"
    mkdir /config
    printf 'printers@example.com\n' > /config/allowed_senders
}
config() { printf '%s' "$2" > "/config/$1"; } # config <file> <exact content>

# load: both steps, as the entrypoint runs them. Leaves MYNETWORKS, ERR and RC.
load() {
    RC=0
    MYNETWORKS=$("$MODULE" access "${1:-/config}" 2>/tmp/err) || RC=$?
    ERR=$(cat /tmp/err)
    if [ "$RC" -eq 0 ]; then
        "$MODULE" client-senders "${1:-/config}" >/tmp/out 2>/tmp/err || RC=$?
        ERR="$ERR"$'\n'"$(cat /tmp/out /tmp/err)"
    fi
}
refused() { # refused <name> <the exact FATAL line>
    if [ "$RC" -eq 1 ] && printf '%s\n' "$ERR" | grep -qxF -- "$2"; then
        check "$1" ok ok
    else
        check "$1" "exit 1, $2" "exit $RC, $ERR"
    fi
}
refused_like() { # refused_like <name> <regex for the whole FATAL line>
    if [ "$RC" -eq 1 ] && printf '%s\n' "$ERR" | grep -qxE -- "$2"; then
        check "$1" ok ok
    else
        check "$1" "exit 1, /$2/" "exit $RC, $ERR"
    fi
}
accepted() { check "$1: boots" "0" "$RC"; } # accepted <name>
logged() { # logged <name> <the exact line>
    if printf '%s\n' "$ERR" | grep -qxF -- "$2"; then check "$1" ok ok; else check "$1" "$2" "$ERR"; fi
}
not_logged() { # not_logged <name> <regex>
    if printf '%s\n' "$ERR" | grep -qE -- "$2"; then check "$1" "absent" "$ERR"; else check "$1" absent absent; fi
}
table() { cat "$POSTFIX/$1"; }
accounts() { sasldblistusers2 | sort; }
sasldb_exists() { if [ -e /etc/sasldb2 ]; then echo yes; else echo no; fi; }
in_sasldb() { if grep -qaF -- "$1" /etc/sasldb2; then echo yes; else echo no; fi; }
tables_absent() { # tables_absent <name>
    local found
    found=$(ls "$POSTFIX"/client_sender_* 2>/dev/null)
    check "$1" "" "$found"
}

# ------------------------------------------------------------ allowed_senders
fresh; rm /config/allowed_senders; load
refused "allowed_senders missing" "FATAL: /config/allowed_senders is missing or empty - no sender would be allowed."

fresh; config allowed_senders ''; load
refused "allowed_senders empty" "FATAL: /config/allowed_senders is missing or empty - no sender would be allowed."

COMMENT_ONLY="FATAL: /config/allowed_senders holds only comments or blank lines - no sender would be allowed."
fresh; config allowed_senders $'# only a comment\n'; load
refused "allowed_senders comment-only" "$COMMENT_ONLY"
fresh; config allowed_senders $'\n   \n\t\n'; load
refused "allowed_senders blank lines only" "$COMMENT_ONLY"
fresh; config allowed_senders $'  # indented\r\n\r\n'; load
refused "allowed_senders comment-only, CRLF" "$COMMENT_ONLY"
fresh; config allowed_senders '# no final newline'; load
refused "allowed_senders comment-only, no final newline" "$COMMENT_ONLY"

fresh
config allowed_senders $'# comment\n\nPrinters@Example.COM\n  indented@example.com\n\ttabbed@example.com\n  # indented comment\nnoted@example.com # a note\ntwo@example.com three@example.com\n'
load
accepted "allowed_senders"
check "allowed_senders: first field, lowercased, without comments" \
    $'printers@example.com OK\nindented@example.com OK\ntabbed@example.com OK\nnoted@example.com OK\ntwo@example.com OK' \
    "$(table allowed_senders)"
check "allowed_senders: postmap finds a lowercased address" "OK" "$(postmap -q printers@example.com hash:$POSTFIX/allowed_senders)"
check "allowed_senders: postmap finds an address with a note" "OK" "$(postmap -q noted@example.com hash:$POSTFIX/allowed_senders)"
check "allowed_senders: a second field is no address" "" "$(postmap -q three@example.com hash:$POSTFIX/allowed_senders)"

fresh; config allowed_senders $'# comment\r\nOne@example.com\r\n\r\nnoted@example.com # note\r\n'; load
accepted "allowed_senders CRLF"
check "allowed_senders CRLF: no CR in the table" $'one@example.com OK\nnoted@example.com OK' "$(table allowed_senders)"
check "allowed_senders CRLF: postmap finds the address" "OK" "$(postmap -q one@example.com hash:$POSTFIX/allowed_senders)"

fresh; config allowed_senders $'one@example.com\ntwo@example.com'; load
accepted "allowed_senders without final newline"
check "allowed_senders without final newline: last address kept" $'one@example.com OK\ntwo@example.com OK' "$(table allowed_senders)"

fresh; config allowed_senders $'\xc3\x84@EXAMPLE.com\n'; load
check "allowed_senders: lowercases ASCII only, other bytes stay" $'\xc3\x84@example.com OK' "$(table allowed_senders)"

# ------------------------------------------------------------ client_accounts
fresh; load
accepted "client_accounts missing"
check "client_accounts missing: no sasldb" no "$(sasldb_exists)"
not_logged "client_accounts missing: no count logged" 'SASL client account'

fresh; config client_accounts ''; load
accepted "client_accounts empty"
check "client_accounts empty: no sasldb" no "$(sasldb_exists)"
not_logged "client_accounts empty: no count logged" 'SASL client account'

fresh; config client_accounts $'# no accounts yet\n\n  # really none\n'; load
accepted "client_accounts comment-only"
check "client_accounts comment-only: no sasldb" no "$(sasldb_exists)"
not_logged "client_accounts comment-only: no count logged" 'SASL client account'

fresh; config client_accounts $'# no accounts yet\r\n\r\n'; load
accepted "client_accounts comment-only, CRLF"
check "client_accounts comment-only, CRLF: no sasldb" no "$(sasldb_exists)"

fresh; config client_accounts $'lobby pw-lobby\nhr pw-hr\n'; load
accepted "client_accounts"
check "client_accounts: accounts in the hostname's realm" \
    $'hr@mailrelay.test: userPassword\nlobby@mailrelay.test: userPassword' "$(accounts)"
logged "client_accounts: count logged" "Loaded 2 SASL client account(s)."
check "client_accounts: sasldb owner and mode" "postfix:sasl 640" "$(stat -c '%U:%G %a' /etc/sasldb2)"
check "client_accounts: password stored" yes "$(in_sasldb pw-lobby)"

fresh; config client_accounts $'lobby pw-lobby\nhr pw-last'; load
accepted "client_accounts without final newline"
check "client_accounts without final newline: last account kept" \
    $'hr@mailrelay.test: userPassword\nlobby@mailrelay.test: userPassword' "$(accounts)"
logged "client_accounts without final newline: count" "Loaded 2 SASL client account(s)."
check "client_accounts without final newline: last password stored" yes "$(in_sasldb pw-last)"

fresh; config client_accounts $'# comment\r\nlobby pw-lobby\r\n\r\nhr pw-hr\r\n'; load
accepted "client_accounts CRLF"
check "client_accounts CRLF: both accounts" \
    $'hr@mailrelay.test: userPassword\nlobby@mailrelay.test: userPassword' "$(accounts)"
check "client_accounts CRLF: the password is stored" yes "$(in_sasldb pw-lobby)"
check "client_accounts CRLF: the CR is not part of the password" no "$(in_sasldb "pw-lobby$CR")"
check "client_accounts CRLF: not in the last one either" no "$(in_sasldb "pw-hr$CR")"

fresh; config client_accounts $'lobby pw-lobby\r\nhr pw-hr'; load
check "client_accounts mixed endings: CR removed" no "$(in_sasldb "pw-lobby$CR")"
check "client_accounts mixed endings: last account kept" yes "$(in_sasldb pw-hr)"

fresh; config client_accounts $'lobby Pw#with#hash\nhr #starts-with-hash\nhome ends-with-hash#\r\n'; load
accepted "client_accounts passwords with #"
check "client_accounts: # inside a password is kept" yes "$(in_sasldb 'Pw#with#hash')"
check "client_accounts: # opening a password is kept" yes "$(in_sasldb '#starts-with-hash')"
check "client_accounts: # closing a password is kept" yes "$(in_sasldb 'ends-with-hash#')"
check "client_accounts: and its CR is gone" no "$(in_sasldb "ends-with-hash#$CR")"
logged "client_accounts passwords with #: count" "Loaded 3 SASL client account(s)."

fresh; config client_accounts $'#off pw-off\n   # off-too pw-off-too\n  on pw-on\n'; load
check "client_accounts: comment lines make no account, indented ones work" "on@mailrelay.test: userPassword" "$(accounts)"

fresh; config client_accounts $'lobby pw-lobby third-field # and more\nhr\tpw-hr\tthird-too\r\n'; load
accepted "client_accounts third field"
check "client_accounts: third field is ignored" no "$(in_sasldb third-field)"
check "client_accounts: password before a third field is stored" yes "$(in_sasldb pw-lobby)"
check "client_accounts: third field with CRLF is ignored" no "$(in_sasldb third-too)"

fresh; config client_accounts $'lobby pa\rss\n'; load
check "client_accounts: a CR inside a password stays" yes "$(in_sasldb $'pa\rss')"

fresh; config client_accounts $'lobby back\\slash\n'; load
check "client_accounts: backslash in a password stays" yes "$(in_sasldb 'back\slash')"

fresh; config client_accounts $'lobby\n'; load
if [ "$RC" -ne 0 ] && printf '%s\n' "$ERR" | grep -q saslpasswd2; then
    check "client_accounts: an account without a password stops the boot" ok ok
else
    check "client_accounts: an account without a password stops the boot" "saslpasswd2 error" "exit $RC, $ERR"
fi

fresh; config client_accounts $'gone pw-gone\n'; load; config client_accounts $'# gone\n'; load
check "client_accounts: a restart forgets a removed account" no "$(sasldb_exists)"
fresh; config client_accounts $'gone pw-gone\n'; load; rm /config/client_accounts; load
check "client_accounts: a restart without the file drops the sasldb" no "$(sasldb_exists)"

# ----------------------------------------------------------- trusted_networks
fresh; load
accepted "trusted_networks missing"
check "trusted_networks missing: empty mynetworks part" "" "$MYNETWORKS"
logged "trusted_networks missing: count" "Loaded 0 trusted network(s)."

fresh; config trusted_networks ''; load
check "trusted_networks empty: empty mynetworks part" "" "$MYNETWORKS"
logged "trusted_networks empty: count" "Loaded 0 trusted network(s)."

fresh; config trusted_networks $'# only a comment\n\n   # another\n'; load
accepted "trusted_networks comment-only"
check "trusted_networks comment-only: empty mynetworks part" "" "$MYNETWORKS"
logged "trusted_networks comment-only: count" "Loaded 0 trusted network(s)."

fresh; config trusted_networks $'# heading\n192.0.2.1\n10.0.0.0/8      # subnet\n192.168.1.5/32#tight\n  172.16.0.0/12\n2001:db8::1\n2001:db8::/32 # six\n\n'; load
accepted "trusted_networks"
check "trusted_networks: comments gone, IPv6 in brackets" \
    " 192.0.2.1 10.0.0.0/8 192.168.1.5/32 172.16.0.0/12 [2001:db8::1] [2001:db8::]/32" "$MYNETWORKS"
logged "trusted_networks: count" "Loaded 6 trusted network(s)."

fresh; config client_accounts $'lobby pw-lobby\n'; config trusted_networks $'192.0.2.1\n'; load
check "trusted_networks: accounts leave the printed value alone" " 192.0.2.1" "$MYNETWORKS"

fresh; config trusted_networks $'# heading\r\n192.0.2.1\r\n\r\n10.0.0.0/8 # subnet\r\n2001:db8::/32\r\n'; load
accepted "trusted_networks CRLF"
check "trusted_networks CRLF: no CR" " 192.0.2.1 10.0.0.0/8 [2001:db8::]/32" "$MYNETWORKS"

fresh; config trusted_networks $'192.0.2.1\r # CR before the comment\n'; load
check "trusted_networks: a CR before a comment is dropped too" " 192.0.2.1" "$MYNETWORKS"

fresh; config trusted_networks $'192.0.2.1\n10.0.0.0/8 # subnet'; load
accepted "trusted_networks without final newline"
check "trusted_networks without final newline: last entry kept" " 192.0.2.1 10.0.0.0/8" "$MYNETWORKS"

BAD="FATAL: /config/trusted_networks:"
fresh; config trusted_networks $'192.0.2.1 192.0.2.2\n'; load
refused "trusted_networks: extra field" "$BAD expected one IP or CIDR per line, got '192.0.2.1 192.0.2.2'"
fresh; config trusted_networks $'192.0.2.1 192.0.2.2 # note\r\n'; load
refused "trusted_networks: extra field, comment and CR stripped" "$BAD expected one IP or CIDR per line, got '192.0.2.1 192.0.2.2'"
fresh; config trusted_networks $'printer.example.com\n'; load
refused "trusted_networks: a name" "$BAD 'printer.example.com' is not an IP or CIDR"
fresh; config trusted_networks $'192.0.2\n'; load
refused "trusted_networks: too few octets" "$BAD '192.0.2' is not an IP or CIDR"
fresh; config trusted_networks $'printer.example.com\r\n'; load
refused "trusted_networks: a name, CRLF" "$BAD 'printer.example.com' is not an IP or CIDR"
fresh; config trusted_networks $'0.0.0.0/0\n'; load
refused "trusted_networks: IPv4 /0" "$BAD '0.0.0.0/0' would trust every address (open relay)"
fresh; config trusted_networks $'10.0.0.0/0 # everything\n'; load
refused "trusted_networks: any /0" "$BAD '10.0.0.0/0' would trust every address (open relay)"
fresh; config trusted_networks $'::/0\n'; load
refused "trusted_networks: IPv6 /0" "$BAD '::/0' would trust every address (open relay)"
fresh; config trusted_networks $'0.0.0.0/00
'; load
refused "trusted_networks: IPv4 /00, which Postfix reads as /0" "$BAD '0.0.0.0/00' would trust every address (open relay)"
fresh; config trusted_networks $'::/000
'; load
refused "trusted_networks: IPv6 /000" "$BAD '::/000' would trust every address (open relay)"
fresh; config trusted_networks $'10.0.0.0/10
'; load
check "trusted_networks: a prefix ending in 0 is fine" "exit 0" "exit $RC"
fresh; config trusted_networks $'192.168.10.21/24\n'; load
refused_like "trusted_networks: CIDR with host bits" "$BAD invalid entry '192\.168\.10\.21/24': .*(warning|fatal).*"
fresh; config trusted_networks $'999.1.1.1\n'; load
refused_like "trusted_networks: bad IP" "$BAD invalid entry '999\.1\.1\.1': .*(warning|fatal).*"
fresh; config trusted_networks $'192.0.2.1/33\n'; load
refused_like "trusted_networks: prefix too long" "$BAD invalid entry '192\.0\.2\.1/33': .*(warning|fatal).*"
fresh; config trusted_networks $'2001:zz8::1\n'; load
refused_like "trusted_networks: bad IPv6" "$BAD invalid entry '2001:zz8::1': .*(warning|fatal).*"
fresh; config trusted_networks $'192.0.2.1\nnope'; load
refused "trusted_networks: a bad last line without newline" "$BAD 'nope' is not an IP or CIDR"

# ------------------------------------------------------------- client_senders
MAPPED_ALLOWED=$'printers@example.com\nscanner@example.com\nlobby@example.com\n'
RESTRICTIONS="check_client_access cidr:$POSTFIX/client_sender_filter.cidr, check_sasl_access hash:$POSTFIX/client_sender_filter_accounts, check_client_access cidr:$POSTFIX/client_sender_accept.cidr, check_sasl_access hash:$POSTFIX/client_sender_accept_accounts, check_sender_access hash:$POSTFIX/allowed_senders, reject"

fresh; load
accepted "client_senders missing"
tables_absent "client_senders missing: no tables"
check "client_senders missing: policy untouched" "$DEFAULT_RESTRICTIONS" "$(postconf -h smtpd_sender_restrictions)"
not_logged "client_senders missing: no count logged" 'client sender mapping'

fresh; config client_senders ''; load
accepted "client_senders empty"
tables_absent "client_senders empty: no tables"
check "client_senders empty: policy untouched" "$DEFAULT_RESTRICTIONS" "$(postconf -h smtpd_sender_restrictions)"

fresh; config client_senders $'# only a comment\n\n'; load
accepted "client_senders comment-only"
tables_absent "client_senders comment-only: no tables"
check "client_senders comment-only: policy untouched" "$DEFAULT_RESTRICTIONS" "$(postconf -h smtpd_sender_restrictions)"
not_logged "client_senders comment-only: no count logged" 'client sender mapping'

fresh; config client_senders $'# only a comment\r\n\r\n'; load
accepted "client_senders comment-only, CRLF"
tables_absent "client_senders comment-only, CRLF: no tables"

fresh
config allowed_senders "$MAPPED_ALLOWED"
config client_accounts $'printer-lobby pw-lobby\n'
config client_senders $'# heading\n192.0.2.21    Scanner@Example.COM\n\n  10.20.30.0/28\tscanner@example.com\n2001:db8::1 lobby@example.com\nprinter-lobby lobby@example.com\n'
load
accepted "client_senders"
check "client_senders: IP filter table" \
    $'192.0.2.21 FILTER sender-rewrite:scanner@example.com\n10.20.30.0/28 FILTER sender-rewrite:scanner@example.com\n2001:db8::1 FILTER sender-rewrite:lobby@example.com' \
    "$(table client_sender_filter.cidr)"
check "client_senders: IP accept table" $'192.0.2.21 OK\n10.20.30.0/28 OK\n2001:db8::1 OK' "$(table client_sender_accept.cidr)"
check "client_senders: account filter table, login seen as user@hostname" \
    "printer-lobby@mailrelay.test FILTER sender-rewrite:lobby@example.com" "$(table client_sender_filter_accounts)"
check "client_senders: account accept table" "printer-lobby@mailrelay.test OK" "$(table client_sender_accept_accounts)"
check "client_senders: postmap finds an IP" "FILTER sender-rewrite:scanner@example.com" \
    "$(postmap -q 192.0.2.21 cidr:$POSTFIX/client_sender_filter.cidr)"
check "client_senders: postmap finds an IP in a network" "FILTER sender-rewrite:scanner@example.com" \
    "$(postmap -q 10.20.30.5 cidr:$POSTFIX/client_sender_filter.cidr)"
check "client_senders: postmap finds an account" "FILTER sender-rewrite:lobby@example.com" \
    "$(postmap -q printer-lobby@mailrelay.test hash:$POSTFIX/client_sender_filter_accounts)"
check "client_senders: postmap accepts an account" "OK" \
    "$(postmap -q printer-lobby@mailrelay.test hash:$POSTFIX/client_sender_accept_accounts)"
# the order is the rule "account beats IP": on a double match the last FILTER wins
check "client_senders: exact sender policy, account filter after IP filter" \
    "$RESTRICTIONS" "$(postconf -h smtpd_sender_restrictions)"
check "client_senders: one pipe call per message" "1000" "$(postconf -h sender-rewrite_destination_recipient_limit)"
logged "client_senders: count" "Loaded 4 client sender mapping(s)."

fresh
config allowed_senders "$MAPPED_ALLOWED"
config client_senders $'192.0.2.21 scanner@example.com\n'
load
check "client_senders with IPs only: empty account tables" "" "$(table client_sender_filter_accounts)"
check "client_senders with IPs only: account tables built" yes "$(if [ -f "$POSTFIX/client_sender_filter_accounts.db" ]; then echo yes; else echo no; fi)"
check "client_senders with IPs only: same policy" "$RESTRICTIONS" "$(postconf -h smtpd_sender_restrictions)"

fresh
config allowed_senders $'# whitelist\r\nprinters@example.com\r\nLobby@example.com\r\n'
config client_accounts $'# accounts\r\nprinter-lobby pw-lobby\r\n'
config client_senders $'# mappings\r\n192.0.2.21 lobby@example.com\r\n\r\nprinter-lobby lobby@example.com\r\n'
config trusted_networks $'# networks\r\n192.0.2.21\r\n'
load
accepted "CRLF in every file"
check "client_senders CRLF: no CR in the IP table" "192.0.2.21 FILTER sender-rewrite:lobby@example.com" "$(table client_sender_filter.cidr)"
check "client_senders CRLF: no CR in the account table" \
    "printer-lobby@mailrelay.test FILTER sender-rewrite:lobby@example.com" "$(table client_sender_filter_accounts)"
logged "client_senders CRLF: count" "Loaded 2 client sender mapping(s)."

fresh
config allowed_senders $'printers@example.com\nlobby@example.com'
config client_accounts $'other pw-other\nprinter-lobby pw-lobby'
config client_senders $'192.0.2.21 lobby@example.com\nprinter-lobby lobby@example.com'
config trusted_networks '192.0.2.21'
load
accepted "no final newline in any file"
check "client_senders without final newline: last mapping kept" \
    "printer-lobby@mailrelay.test FILTER sender-rewrite:lobby@example.com" "$(table client_sender_filter_accounts)"
logged "client_senders without final newline: count" "Loaded 2 client sender mapping(s)."

BAD="FATAL: /config/client_senders:"
fresh; config allowed_senders "$MAPPED_ALLOWED"; config client_senders $'192.0.2.21\n'; load
refused "client_senders: no mailbox" "$BAD expected '<ip-or-cidr|account> <mailbox>' for '192.0.2.21'"
fresh; config allowed_senders "$MAPPED_ALLOWED"; config client_senders $'192.0.2.21\r\nnext lobby@example.com\n'; load
refused "client_senders: no mailbox, CRLF" "$BAD expected '<ip-or-cidr|account> <mailbox>' for '192.0.2.21'"
fresh; config allowed_senders "$MAPPED_ALLOWED"; config client_senders $'192.0.2.21 lobby@example.com extra\n'; load
refused "client_senders: extra field" "$BAD expected '<ip-or-cidr|account> <mailbox>' for '192.0.2.21'"
fresh; config allowed_senders "$MAPPED_ALLOWED"; config client_senders $'192.0.2.21 lobby@example.com # note\n'; load
refused "client_senders: no inline comments" "$BAD expected '<ip-or-cidr|account> <mailbox>' for '192.0.2.21'"
fresh; config allowed_senders "$MAPPED_ALLOWED"; config client_senders $'192.0.2.21 not-a-mailbox\n'; load
refused "client_senders: not a mailbox" "$BAD 'not-a-mailbox' is not a mailbox address"
fresh; config allowed_senders "$MAPPED_ALLOWED"; config client_senders $'192.0.2.21 not-listed@example.com\n'; load
refused "client_senders: mailbox not in allowed_senders" "$BAD 'not-listed@example.com' (for '192.0.2.21') is not in allowed_senders"
fresh; config allowed_senders "$MAPPED_ALLOWED"; config client_senders $'printer-typo lobby@example.com\n'; load
refused "client_senders: account without client_accounts" "$BAD account 'printer-typo' is not in client_accounts"
fresh; config allowed_senders "$MAPPED_ALLOWED"; config client_accounts $'printer-lobby pw\n'; config client_senders $'printer-typo lobby@example.com\n'; load
refused "client_senders: account not in client_accounts" "$BAD account 'printer-typo' is not in client_accounts"
fresh; config allowed_senders "$MAPPED_ALLOWED"; config client_accounts $'other printer-lobby\n'; config client_senders $'printer-lobby lobby@example.com\n'; load
refused "client_senders: a password is no account" "$BAD account 'printer-lobby' is not in client_accounts"
fresh; config allowed_senders "$MAPPED_ALLOWED"; config client_accounts $'other pw\n#printer-lobby pw\n'; config client_senders $'printer-lobby lobby@example.com\n'; load
refused "client_senders: a commented account is no account" "$BAD account 'printer-lobby' is not in client_accounts"
fresh; config allowed_senders "$MAPPED_ALLOWED"; config client_senders $'999.1.1.1 lobby@example.com\n'; load
refused_like "client_senders: bad IP" "$BAD invalid IP entry: .*(warning|fatal).*"
fresh; config allowed_senders "$MAPPED_ALLOWED"; config client_senders $'192.168.10.21/24 lobby@example.com\n'; load
refused_like "client_senders: CIDR with host bits" "$BAD invalid IP entry: .*(warning|fatal).*"
fresh; config allowed_senders "$MAPPED_ALLOWED"; config client_senders $'2001:zz8::1 lobby@example.com\n'; load
refused_like "client_senders: bad IPv6" "$BAD invalid IP entry: .*(warning|fatal).*"

# ------------------------------------------------------------- the interface
fresh; mkdir /tmp/elsewhere; printf 'one@example.com\n' > /tmp/elsewhere/allowed_senders; load /tmp/elsewhere
check "the config directory is an argument" "one@example.com OK" "$(table allowed_senders)"
rm /tmp/elsewhere/allowed_senders; load /tmp/elsewhere
refused "a FATAL names the directory it was given" "FATAL: /tmp/elsewhere/allowed_senders is missing or empty - no sender would be allowed."

for value in printers@example.com A.b_c%d+e-f@Sub.Example-1.com; do
    "$MODULE" is-mailbox "$value"
    check "is-mailbox accepts $value" 0 "$?"
done
for value in '' printers example.com @example.com printers@ 'a b@example.com' 'a@b@c.com' $'a@b.com\n'; do
    "$MODULE" is-mailbox "$value"
    RC=$?
    check "is-mailbox refuses $(printf '%q' "$value")" 1 "$RC"
done

# outbound-graph.sh shares the rule, and it still decides there
fresh
FAILURE_NOTICE_MAILBOX=not-a-mailbox FAILURE_NOTICE_SENDER=noreply@example.com /usr/local/bin/outbound-graph.sh setup >/dev/null 2>/tmp/err
RC=$?; ERR=$(cat /tmp/err)
refused "outbound-graph refuses a malformed notice mailbox" "FATAL: set FAILURE_NOTICE_MAILBOX and FAILURE_NOTICE_SENDER together, as mailbox addresses"
fresh
FAILURE_NOTICE_MAILBOX=notices@example.com FAILURE_NOTICE_SENDER=noreply@example.com /usr/local/bin/outbound-graph.sh setup >/dev/null 2>/tmp/err
check "outbound-graph accepts well-formed notice mailboxes" 0 "$?"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
