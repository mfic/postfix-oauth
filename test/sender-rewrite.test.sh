#!/usr/bin/env bash
# Unit tests for scripts/sender-rewrite.sh - the Postfix pipe command that gives
# a mapped client its mailbox. Runs on the host with a stub sendmail.
#
#   ./test/sender-rewrite.test.sh
set -u
cd "$(dirname "$0")/.." || exit 1

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/sendmail" <<EOF
#!/bin/bash
printf '%s\n' "\$*" > "$TMP/args"
cat > "$TMP/out"
exit \$(cat "$TMP/sendmail-status")
EOF
chmod +x "$TMP/sendmail"
echo 0 > "$TMP/sendmail-status"

pass=0; fail=0
check() { # check <name> <expected> <actual>
    if [ "$3" = "$2" ]; then
        echo "PASS: $1"; pass=$((pass+1))
    else
        echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; fail=$((fail+1))
    fi
}

rewrite() { # rewrite <message>; leaves the result in $TMP/out, exit code in $TMP/exit
    printf '%s' "$1" | SENDMAIL="$TMP/sendmail" \
        bash scripts/sender-rewrite.sh box@example.com user@example.org hidden@example.org 2>/dev/null
    echo "$?" > "$TMP/exit"
}

rewrite $'From: "Lobby Printer"\n <wrong@nowhere.com>\nSender: wrong@nowhere.com\n via folded\nTo: user@example.org\nSubject: scan\n\nFrom: body line\nSender: body line\n'
expected=$'From: box@example.com\nTo: user@example.org\nSubject: scan\n\nFrom: body line\nSender: body line'
check "replaces a folded From, drops Sender, leaves the body alone" "$expected" "$(cat "$TMP/out")"
check "re-injects with the mailbox as envelope sender and all recipients" \
    "-G -i -f box@example.com -- user@example.org hidden@example.org" "$(cat "$TMP/args")"
check "exits 0 on success" "0" "$(cat "$TMP/exit")"

rewrite $'To: user@example.org\n\nbody\n'
check "adds a From when the printer sent none" \
    $'To: user@example.org\nFrom: box@example.com\n\nbody' "$(cat "$TMP/out")"

rewrite $'FROM: a@nowhere.com\nFrom: b@nowhere.com\nTo: user@example.org\n\nbody\n'
check "replaces every From, whatever its case, with a single one" \
    $'From: box@example.com\nTo: user@example.org\n\nbody' "$(cat "$TMP/out")"

echo 75 > "$TMP/sendmail-status"
rewrite $'From: a@nowhere.com\n\nbody\n'
check "passes on a sendmail tempfail" "75" "$(cat "$TMP/exit")"

echo 1 > "$TMP/sendmail-status"
rewrite $'From: a@nowhere.com\n\nbody\n'
check "defers on an unexpected sendmail failure" "75" "$(cat "$TMP/exit")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
