# Domain glossary

- **Relay** — the dockerized Postfix MTA; accepts mail from printers, delivers to Microsoft 365.
- **Printer** — an SMTP client with no modern auth: connects from a whitelisted IP or with a per-printer SASL account.
- **Sender lockdown** — the whitelist in `config/allowed_senders`; binds every client, trusted or authenticated.
- **Outbound mode** — how the relay hands mail to Microsoft 365: `graph` (Graph `sendMail` over HTTPS) or `smtp` (SMTP submission with XOAUTH2). Chosen per deployment by the compose file.
- **Outbound-mode adapter** — `scripts/outbound-<mode>.sh`; the one file that owns everything a mode needs. Interface (identical for every mode): `setup` (Postfix config + aux services at boot), `token-scope` (OAuth scope), `write-token <token> <ttl>` (that mode's token store, format and ownership included). Adding a mode = adding one adapter script; entrypoint and token scripts stay mode-agnostic.
- **Token store** — `/etc/tokens/token`; its format belongs to the adapter (raw bearer token for graph's pipe user, sasl-xoauth2 JSON for smtp).
