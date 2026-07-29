#!/bin/sh
# Response-driven SMTP dialogue driver. Sends EHLO, each argument command,
# and QUIT - each only after the server's previous reply is complete - and
# prints the full transcript (server replies) to stdout. No fixed sleeps:
# a hung server is bounded by nc's -w idle timeout instead.
#
# Inside a DATA phase (server replied 354) lines are message content and get
# no reply until the lone "." terminator.
#
# POSIX sh + nc only, so it runs unchanged in the relay container (bash,
# netcat-openbsd) and the busybox helper. smoke.sh pipes it into `sh -s`:
#
#   sh -s -- <host> <port> <smtp-command>... < smtp-dialogue.sh
set -u

host=$1; port=$2; shift 2

dir="${TMPDIR:-/tmp}/smtp-dialogue.$$"
mkdir "$dir" || exit 1
trap 'exec 3>&- 4<&- 2>/dev/null; rm -rf "$dir"' EXIT
mkfifo "$dir/in" "$dir/out"

nc -w 15 "$host" "$port" < "$dir/in" > "$dir/out" &
exec 3> "$dir/in" 4< "$dir/out"

send() { printf '%s\r\n' "$1" >&3; }

# Read one complete SMTP reply from fd 4 and echo it. Multiline replies
# continue while the line looks like "NNN-..."; anything else ends the reply.
reply() {
    while IFS= read -r line <&4; do
        printf '%s\n' "$line"
        case "$line" in
            [0-9][0-9][0-9]-*) ;;
            *) return 0 ;;
        esac
    done
    return 1
}

reply || exit 1        # greeting
send "EHLO smoketest"
reply || exit 1

in_data=0
for cmd; do
    send "$cmd"
    if [ "$in_data" = 1 ]; then
        if [ "$cmd" = "." ]; then
            in_data=0
            reply || exit 1
        fi
        continue
    fi
    r=$(reply) || exit 1
    printf '%s\n' "$r"
    case "$r" in
        354*) in_data=1 ;;
    esac
done

send "QUIT"
reply
exit 0
