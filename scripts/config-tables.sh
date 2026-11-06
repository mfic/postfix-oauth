#!/bin/bash
# The one reader of the config files: every line of config/ goes through
# read_entries here and comes out as a Postfix table, SASL account or setting.
# Any bad entry is a FATAL and a non-zero exit. Run the two steps in this order:
#
#   access <config-dir>          allowed_senders and client_accounts into their
#                                tables, trusted_networks checked. Prints the
#                                value for mynetworks; logs go to stderr.
#   client-senders <config-dir>  client_senders into its tables and the sender
#                                policy. Changes main.cf, so run it once that is
#                                rendered. Needs POSTFIX_HOSTNAME, as does access.
#   is-mailbox <value>           exit 0 if the value is a mailbox address
set -eu

fatal() { echo "FATAL: $1" >&2; exit 1; }

# read_entries <file>: fills ENTRIES with the lines that hold something, without
# their line endings. A missing file has no entries. Comments are whole lines
# only: an inline '#' means something different in each file, and in a password
# it is a '#'. Runs in the calling shell, so that a FATAL can stop it.
read_entries() {
    local line
    ENTRIES=()
    [ -f "$1" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        while [[ "$line" == *$'\r' ]]; do line=${line%$'\r'}; done
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] || ENTRIES+=("$line")
    done < "$1"
}

is_mailbox() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]; }
looks_like_ip() { [[ "$1" =~ ^[0-9]+(\.[0-9]+){3}(/[0-9]+)?$ || "$1" == *:* ]]; }

# cidr_errors <table>: Postfix only warns about a bad cidr line and then ignores
# it, so this prints those warnings, and succeeds if there are any.
cidr_errors() { postmap -q 0.0.0.0 "cidr:$1" 2>&1 | grep -E 'warning|fatal'; }

# One address per line, first field, lowercased. Anything not on the list is
# rejected at MAIL FROM time.
load_allowed_senders() { # load_allowed_senders <config-dir>
    local file=$1/allowed_senders entry address
    [ -s "$file" ] || fatal "$file is missing or empty - no sender would be allowed."
    read_entries "$file"
    [ "${#ENTRIES[@]}" -gt 0 ] || fatal "$file holds only comments or blank lines - no sender would be allowed."
    for entry in "${ENTRIES[@]}"; do
        read -r address _ <<< "$entry"
        printf '%s OK\n' "${address,,}"
    done > /etc/postfix/allowed_senders
    postmap hash:/etc/postfix/allowed_senders
}

# Lines of "username password" become SASL logins. Passwords may hold '#', and
# anything after the password is ignored.
load_client_accounts() { # load_client_accounts <config-dir>
    local entry user pass
    rm -f /etc/sasldb2
    read_entries "$1/client_accounts"
    [ "${#ENTRIES[@]}" -gt 0 ] || return 0
    for entry in "${ENTRIES[@]}"; do
        read -r user pass _ <<< "$entry"
        printf '%s' "$pass" | saslpasswd2 -p -c -u "$POSTFIX_HOSTNAME" "$user"
    done
    chown postfix:sasl /etc/sasldb2 2>/dev/null || chown postfix /etc/sasldb2
    chmod 640 /etc/sasldb2
    echo "Loaded $(sasldblistusers2 | wc -l) SASL client account(s)." >&2
}

# One IP or CIDR per line, with inline comments. These clients may relay without
# authentication. Postfix accepts a bad entry at boot without complaint, so each
# one is checked here. Prints the value for mynetworks.
trusted_networks() { # trusted_networks <config-dir>
    local file=$1/trusted_networks networks="" line entry extra check_table table_errors
    read_entries "$file"
    check_table=$(mktemp)
    for line in "${ENTRIES[@]}"; do
        line=${line%%#*}
        read -r entry extra <<< "${line//$'\r'/}"
        [ -z "$extra" ] || fatal "$file: expected one IP or CIDR per line, got '$entry $extra'"
        looks_like_ip "$entry" || fatal "$file: '$entry' is not an IP or CIDR"
        # Postfix reads /00 as /0 too
        [[ ! "$entry" =~ /0+$ ]] || fatal "$file: '$entry' would trust every address (open relay)"
        printf '%s OK\n' "$entry" > "$check_table"
        if table_errors=$(cidr_errors "$check_table"); then
            fatal "$file: invalid entry '$entry': $table_errors"
        fi
        # mynetworks writes IPv6 addresses in brackets
        case "$entry" in
            *:*/*) entry="[${entry%/*}]/${entry##*/}" ;;
            *:*) entry="[$entry]" ;;
        esac
        networks="$networks $entry"
    done
    rm -f "$check_table"
    echo "Loaded $(printf '%s' "$networks" | wc -w) trusted network(s)." >&2
    printf '%s\n' "$networks"
}

is_account() { # is_account <config-dir> <name>
    local entry user
    read_entries "$1/client_accounts"
    for entry in "${ENTRIES[@]}"; do
        read -r user _ <<< "$entry"
        [ "$user" != "$2" ] || return 0
    done
    return 1
}

# Lines of "<ip-or-cidr|account> <mailbox>". A mapped client always sends as its
# mailbox, whatever it puts in MAIL FROM or From. Without entries the policy in
# main.cf stays untouched. A bad entry is fatal: skipping it would silently let
# that client pick its own sender.
load_client_senders() { # load_client_senders <config-dir>
    local file=$1/client_senders line client mailbox extra cidr_problem
    read_entries "$file"
    [ "${#ENTRIES[@]}" -gt 0 ] || return 0
    local -a mappings=("${ENTRIES[@]}")
    : > /etc/postfix/client_sender_filter.cidr
    : > /etc/postfix/client_sender_accept.cidr
    : > /etc/postfix/client_sender_filter_accounts
    : > /etc/postfix/client_sender_accept_accounts
    for line in "${mappings[@]}"; do
        read -r client mailbox extra <<< "${line//$'\r'/}"
        [ -n "$mailbox" ] && [ -z "$extra" ] \
            || fatal "$file: expected '<ip-or-cidr|account> <mailbox>' for '$client'"
        is_mailbox "$mailbox" || fatal "$file: '$mailbox' is not a mailbox address"
        mailbox=${mailbox,,}
        grep -qxF -- "$mailbox OK" /etc/postfix/allowed_senders \
            || fatal "$file: '$mailbox' (for '$client') is not in allowed_senders"

        if looks_like_ip "$client"; then
            printf '%s FILTER sender-rewrite:%s\n' "$client" "$mailbox" >> /etc/postfix/client_sender_filter.cidr
            printf '%s OK\n' "$client" >> /etc/postfix/client_sender_accept.cidr
        else
            is_account "$1" "$client" || fatal "$file: account '$client' is not in client_accounts"
            # smtpd_sasl_local_domain makes Postfix see the login as user@hostname
            printf '%s@%s FILTER sender-rewrite:%s\n' "$client" "$POSTFIX_HOSTNAME" "$mailbox" >> /etc/postfix/client_sender_filter_accounts
            printf '%s@%s OK\n' "$client" "$POSTFIX_HOSTNAME" >> /etc/postfix/client_sender_accept_accounts
        fi
    done

    if cidr_problem=$(cidr_errors /etc/postfix/client_sender_filter.cidr); then
        fatal "$file: invalid IP entry: $cidr_problem"
    fi
    postmap hash:/etc/postfix/client_sender_filter_accounts
    postmap hash:/etc/postfix/client_sender_accept_accounts

    # FILTER does not end the restriction list, so a second pass accepts the
    # mapped client. On a double match the last FILTER wins: account over IP.
    postconf -e "smtpd_sender_restrictions = \
check_client_access cidr:/etc/postfix/client_sender_filter.cidr, \
check_sasl_access hash:/etc/postfix/client_sender_filter_accounts, \
check_client_access cidr:/etc/postfix/client_sender_accept.cidr, \
check_sasl_access hash:/etc/postfix/client_sender_accept_accounts, \
check_sender_access hash:/etc/postfix/allowed_senders, reject"
    # one pipe call per message, or Graph would deliver to the header recipients twice
    postconf -e "sender-rewrite_destination_recipient_limit = 1000"
    echo "Loaded ${#mappings[@]} client sender mapping(s)." >&2
}

case "${1:?usage: config-tables.sh access|client-senders <config-dir>, or is-mailbox <value>}" in

access)
    load_allowed_senders "${2:?config directory}"
    load_client_accounts "$2"
    trusted_networks "$2"
    ;;

client-senders)
    load_client_senders "${2:?config directory}"
    ;;

is-mailbox)
    is_mailbox "${2-}"
    ;;

*)
    echo "config-tables: unknown command '$1'" >&2
    exit 64
    ;;
esac
