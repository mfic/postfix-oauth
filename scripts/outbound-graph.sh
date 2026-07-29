#!/bin/bash
# Outbound-mode adapter: Microsoft Graph Mail.Send via the graph-send.sh
# pipe transport. Every mode adapter implements the same interface:
#
#   setup                        render config, start aux services (once, at boot)
#   token-scope                  print the OAuth scope this mode needs
#   write-token <token> <ttl>    write this mode's token store atomically
#
# GRAPH_ENDPOINT and TOKEN_FILE can be overridden, e.g. for tests.
set -eu

TOKEN_FILE="${TOKEN_FILE:-/etc/tokens/token}"

case "${1:?usage: outbound-graph.sh setup|token-scope|write-token}" in

setup)
    cat >> /etc/postfix/main.cf <<'EOF'
# OUTBOUND_MODE=graph: deliver via the Graph sendMail API (pipe transport).
# The fixed "graph" nexthop makes all recipients of a message one queue
# destination, so a message is delivered in a single pipe call / Graph request
# (multiple calls would duplicate delivery to the MIME header recipients).
default_transport = graph:graph
graph_destination_recipient_limit = 1000
graph_destination_concurrency_limit = 5
EOF

    # Postfix scrubs the environment of pipe(8) commands, so graph-send.sh
    # reads its settings from this file.
    mkdir -p /etc/postfix-relay
    cat > /etc/postfix-relay/graph-send.env <<EOF
GRAPH_ENDPOINT=${GRAPH_ENDPOINT:-https://graph.microsoft.com/v1.0}
TOKEN_FILE=${TOKEN_FILE}
EOF
    ;;

token-scope)
    echo "https://graph.microsoft.com/.default"
    ;;

write-token)
    umask 077
    printf '%s' "${2:?token}" > "${TOKEN_FILE}.tmp"
    # graph-send.sh runs as the pipe user "nobody" (pipe refuses postfix/root)
    chown nobody:nogroup "${TOKEN_FILE}.tmp" 2>/dev/null || true
    mv -f "${TOKEN_FILE}.tmp" "$TOKEN_FILE"
    ;;

*)
    echo "outbound-graph: unknown command '$1'" >&2
    exit 64
    ;;
esac
