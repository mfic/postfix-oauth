#!/usr/bin/env bash
# Unit tests for scripts/failure-notice.sh - a Postfix bounce in, the log details
# or the notice's MIME out. Posting a notice is covered in graph-send.test.sh.
#
#   ./test/failure-notice.test.sh
set -u
cd "$(dirname "$0")/.." || exit 1

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # check <name> <expected> <actual>
    if [ "$3" = "$2" ]; then
        echo "PASS: $1"; pass=$((pass+1))
    else
        echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; fail=$((fail+1))
    fi
}
has_text() { # has_text <name> <text>: the last output contains it
    if grep -qF -- "$2" "$TMP/out"; then
        echo "PASS: $1"; pass=$((pass+1))
    else
        echo "FAIL: $1"; fail=$((fail+1))
    fi
}
lacks_text() { # lacks_text <name> <text>
    if grep -qF -- "$2" "$TMP/out"; then
        echo "FAIL: $1"; fail=$((fail+1))
    else
        echo "PASS: $1"; pass=$((pass+1))
    fi
}

BOUNCE=$'From: MAILER-DAEMON@relay (Mail Delivery System)\r\nTo: printers@example.com\r\nSubject: Undelivered Mail Returned to Sender\r\nDate: Fri, 06 Nov 2026 14:04:25 +0000\r\nMessage-Id: <bounce-1@relay>\r\nAuto-Submitted: auto-replied\r\nMIME-Version: 1.0\r\nContent-Type: multipart/report; report-type=delivery-status;\r\n\tboundary="B/relay"\r\n\r\nThis is a MIME-encapsulated message.\r\n\r\n--B/relay\r\nContent-Description: Notification\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nThis is the mail system at host relay.\r\n\r\n--B/relay\r\nContent-Description: Delivery report\r\nContent-Type: message/delivery-status\r\n\r\nReporting-MTA: dns; relay\r\nX-Postfix-Queue-ID: ABC123\r\nX-Postfix-Sender: rfc822; printers@example.com\r\n\r\nFinal-Recipient: rfc822; user@example.org\r\nAction: failed\r\nStatus: 5.3.0\r\nDiagnostic-Code: x-unix; graph-send: HTTP 403 from Graph, bouncing (message 358\r\n    bytes, request 480 bytes): {"error":{"code":"ErrorAccessDenied"}}\r\n\r\nFinal-Recipient: rfc822; second@example.org\r\nAction: failed\r\nStatus: 5.3.0\r\nDiagnostic-Code: x-unix; graph-send: HTTP 403 second\r\n\r\n--B/relay\r\nContent-Description: Undelivered Message\r\nContent-Type: message/rfc822\r\nContent-Transfer-Encoding: 8bit\r\n\r\nFrom: printers@example.com\r\nTo: user@example.org\r\nSubject: Scan from\r\n lobby printer\r\n\r\nSCAN CONTENT MARKER\r\nFinal-Recipient: rfc822; planted@example.org\r\nSubject: planted subject\r\n\r\n--B/relay--\r\n'

# notice <bounce> <arguments>: runs the module, leaving its output in $TMP/out and
# its exit code in $TMP/exit
notice() {
    local bounce=$1; shift
    printf '%s' "$bounce" | bash scripts/failure-notice.sh "$@" > "$TMP/out" 2>"$TMP/stderr"
    echo "$?" > "$TMP/exit"
}
plain() { notice "$1" plain noreply@example.com notices@example.com "${@:2}"; }
attached() { notice "$1" attached noreply@example.com notices@example.com; }

# --- what failed, for the log ---------------------------------------------------
notice "$BOUNCE" details
check "details name the queue ID and every failed recipient" \
    "original message ABC123, failed recipients user@example.org,second@example.org" "$(cat "$TMP/out")"
check "details exit 0" "0" "$(cat "$TMP/exit")"
notice $'Subject: no report here\r\n\r\nFinal-Recipient: rfc822; planted@example.org\r\n' details
check "details without a report say unknown" \
    "original message unknown, failed recipients unknown" "$(cat "$TMP/out")"

# --- the plain notice -----------------------------------------------------------
plain "$BOUNCE"
check "plain notice exits 0" "0" "$(cat "$TMP/exit")"
check "bounce gets the configured sender in From" "From: noreply@example.com" \
    "$(grep -i '^From:' "$TMP/out")"
check "bounce goes only to the configured mailbox" "To: notices@example.com" \
    "$(grep -i '^To:' "$TMP/out")"
check "notice is plain text, because Exchange drops a multipart/report" \
    "Content-Type: text/plain; charset=utf-8" "$(grep -i '^Content-Type:' "$TMP/out")"
check "notice subject names the queue ID" "Subject: Mail relay: delivery failed (ABC123)" \
    "$(grep -m1 '^Subject:' "$TMP/out")"
check "notice keeps the bounce's Message-Id" "Message-Id: <bounce-1@relay>" \
    "$(grep -i '^Message-Id:' "$TMP/out")"
for expected in 'Queue ID: ABC123' 'Sender:   printers@example.com' 'Subject:  Scan from lobby printer' \
    'Recipient: user@example.org' 'Recipient: second@example.org' 'Status:    5.3.0' \
    'HTTP 403 from Graph' 'ErrorAccessDenied'; do
    has_text "notice states '$expected'" "$expected"
done
for leak in 'SCAN CONTENT MARKER' 'planted' 'multipart' 'Mail Delivery System'; do
    lacks_text "notice does not contain '$leak'" "$leak"
done
has_text "notice says the content is not included" "The message's content is not included."

# --- a line inside a scan can't pose as part of the report ------------------------
SCAN=$'Content-Type: message/delivery-status\r\n\r\nX-Postfix-Queue-ID: planted\r\nFinal-Recipient: rfc822; planted@example.org\r\nStatus: planted\r\nDiagnostic-Code: x-unix; planted\r\nContent-Type: message/rfc822\r\n\r\nSubject: planted subject\r\n'
POLLUTED=${BOUNCE//SCAN CONTENT MARKER$'\r\n'/$SCAN}
plain "$POLLUTED"
lacks_text "report lookalikes in a scan don't reach the notice" 'planted'
notice "$POLLUTED" details
check "report lookalikes in a scan don't reach the log" \
    "original message ABC123, failed recipients user@example.org,second@example.org" "$(cat "$TMP/out")"

# --- a failed message that is itself a message/rfc822 ----------------------------
# Its own Content-Type must not pass for the report's part, on either side of its Subject
EMBEDDED=$'Content-Type: message/rfc822\r\n\r\nSubject: planted subject\r\n\r\nSCAN\r\n'
plain "${BOUNCE//$'\r\n\r\nSCAN CONTENT MARKER\r\n'/$'\r\n'$EMBEDDED}"
has_text "own type after the Subject: the top-level Subject is shown" 'Subject:  Scan from lobby printer'
lacks_text "own type after the Subject: the embedded one isn't" 'planted'
AFTER_TO=${BOUNCE//$'To: user@example.org\r\nSubject: Scan from'/$'To: user@example.org\r\nContent-Type: message/rfc822\r\nSubject: Scan from'}
plain "${AFTER_TO//$'\r\n\r\nSCAN CONTENT MARKER\r\n'/$'\r\n\r\nSubject: planted subject\r\n\r\nSCAN\r\n'}"
has_text "own type before the Subject: the top-level Subject is shown" 'Subject:  Scan from lobby printer'
lacks_text "own type before the Subject: the embedded one isn't" 'planted'

# --- optionally the failed message is attached --------------------------------
attached "$BOUNCE"
check "attached notice exits 0" "0" "$(cat "$TMP/exit")"
has_text "attached notice is multipart/mixed" 'Content-Type: multipart/mixed'
lacks_text "attached notice is not a multipart/report" 'multipart/report'
has_text "attached notice names the attachment" 'filename="failed-message.eml"'
has_text "attachment holds the failed message" 'SCAN CONTENT MARKER'
has_text "attachment keeps the failed message's headers" 'Subject: Scan from'
lacks_text "attachment leaves out the delivery report" 'Reporting-MTA'
has_text "attached notice still gives the failure" 'HTTP 403 from Graph'
check "attached notice has one top-level recipient" "To: notices@example.com" \
    "$(sed '/^$/q' "$TMP/out" | grep -i '^To:')"
has_text "attached notice says the message is attached" 'The failed message is attached.'

attached $'Subject: no report here\r\n\r\nno message part\r\n'
check "a bounce holding no message can't be attached" "1" "$(cat "$TMP/exit")"
check "and prints nothing" "" "$(cat "$TMP/out")"

# --- the notice sent again after Graph refused it with its attachment -------------
plain "$BOUNCE" 413
check "the retry exits 0" "0" "$(cat "$TMP/exit")"
check "the retry is plain text" "Content-Type: text/plain; charset=utf-8" \
    "$(grep -i '^Content-Type:' "$TMP/out")"
has_text "the retry says why" 'could not be attached: Graph refused the notice with it,'
has_text "the retry gives Graph's status" 'HTTP 413'
has_text "the retry still gives the failure" 'HTTP 403 from Graph'
lacks_text "the retry drops the attachment" 'SCAN CONTENT MARKER'

# --- encoded subjects are shown decoded ----------------------------------------
subject_shown() { # subject_shown <Subject header value>: the Subject line in the notice
    plain "${BOUNCE//Subject: Scan from$'\r\n' lobby printer/Subject: $1}"
    sed -n 's/^Subject:  //p' "$TMP/out"
}
check "decodes quoted-printable UTF-8" 'relay-test 10 Prüfung äöü' \
    "$(subject_shown '=?utf-8?Q?relay-test_10_Pr=C3=BCfung_=C3=A4=C3=B6=C3=BC?=')"
check "decodes base64 UTF-8" 'Prüfung' "$(subject_shown '=?UTF-8?B?UHLDvGZ1bmc=?=')"
check "decodes Latin-1" 'Prüfung' "$(subject_shown '=?iso-8859-1?Q?Pr=FCfung?=')"
check "joins adjacent encoded words" 'Prüfung äöü' \
    "$(subject_shown '=?utf-8?Q?Pr=C3=BCfung_?= =?utf-8?Q?=C3=A4=C3=B6=C3=BC?=')"
check "keeps text around an encoded word" 'Scan für Empfang (2)' \
    "$(subject_shown 'Scan =?utf-8?Q?f=C3=BCr?= Empfang (2)')"
check "leaves a plain subject alone" 'Scan 100% = done_now' "$(subject_shown 'Scan 100% = done_now')"
check "keeps a word in an unknown charset" '=?no-such-charset?Q?abc?=' \
    "$(subject_shown '=?no-such-charset?Q?abc?=')"
check "keeps a word that is invalid in its charset" '=?utf-8?Q?=FF?=' "$(subject_shown '=?utf-8?Q?=FF?=')"
check "control characters can't add lines to the notice" 'a b' "$(subject_shown '=?utf-8?Q?a=0Ab?=')"

# --- wrong use ------------------------------------------------------------------
notice "$BOUNCE" plain noreply@example.com
check "a missing argument is refused" "64" "$(cat "$TMP/exit")"
notice "$BOUNCE" nonsense
check "an unknown command is refused" "64" "$(cat "$TMP/exit")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
