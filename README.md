# Postfix → Microsoft 365 Graph relay for printers

A dockerized Postfix MTA that lets printers/scanners with **no modern auth
support** send mail through Microsoft 365. Printers connect either

- **without authentication**, if their fixed IP is whitelisted, or
- **with a per-printer username/password** (SASL PLAIN/LOGIN on port 587 or 25).

Outbound, each queued message is delivered with a single **Microsoft Graph
`sendMail`** call (`POST /users/{envelope-sender}/sendMail`, app-only client
credentials — no user password anywhere, no SMTP AUTH at Microsoft's edge).
A small refresher loop keeps the app-only access token fresh.

**Sender lockdown:** only envelope senders listed in `config/allowed_senders`
are accepted — for every client, whitelisted or authenticated. Anything else is
rejected with `550`. So printers can *choose* a sender, but only from the
predefined list.

## Setup

### 1. Entra ID app registration

1. Entra admin center → App registrations → New registration (e.g. `postfix-relay`).
2. API permissions → Add a permission → **Microsoft Graph** →
   **Application permissions** → `Mail.Send` → add, then **Grant admin consent**.
3. Certificates & secrets → New client secret → note the **value**.
4. Note the **Application (client) ID** and **Directory (tenant) ID**.

### 2. Exchange Online: scope what the app may send as

App-only `Mail.Send` can send as **any** mailbox in the tenant. Restrict it to
the relay's senders with an application access policy (Exchange Online
PowerShell, `Connect-ExchangeOnline`):

```powershell
# mail-enabled security group containing every mailbox in allowed_senders
New-ApplicationAccessPolicy -AppId <CLIENT_ID> `
    -PolicyScopeGroupId relay-senders@example.com `
    -AccessRight RestrictAccess `
    -Description "postfix relay may only send as its printer mailboxes"
Test-ApplicationAccessPolicy -AppId <CLIENT_ID> -Identity printers@example.com
```

Every address in `config/allowed_senders` must be a mailbox (or an alias of
one — sending from aliases additionally needs `Set-OrganizationConfig
-SendFromAliasEnabled $true`) covered by that policy.

### 3. Configure and start the relay

```bash
cp .env.example .env                                    # fill in tenant/client/secret
cp config/allowed_senders.example config/allowed_senders
cp config/printer_accounts.example config/printer_accounts   # optional
docker compose up -d --build
docker compose logs -f    # watch for "token-refresher: new access token"
```

### 4. Point the printers at it

| Printer capability | Settings |
|---|---|
| No auth (IP in `PRINTER_NETWORKS`) | SMTP server = relay IP, port 25, no auth, no TLS needed |
| Username/password | Port 587 (or 25), STARTTLS if supported, PLAIN/LOGIN with an account from `config/printer_accounts` |

The From/sender address on the printer must be one of `config/allowed_senders`.

## Files

| File | Purpose |
|---|---|
| `.env` | Tenant/app credentials, hostname, printer IPs |
| `config/allowed_senders` | Sender whitelist (one address per line) — **required** |
| `config/printer_accounts` | Optional `user password` lines for SASL accounts |
| `config/tls/cert.pem` + `key.pem` | Optional real TLS cert (self-signed otherwise) |
| `postfix/main.cf.tmpl`, `postfix/master.cf` | The Postfix policy — rendered/copied at startup, linted with `postfix check` |
| `scripts/graph-send.sh` | Pipe transport: posts one queued message to Graph `sendMail` |
| `scripts/fetch-token.sh` | One-shot Entra ID token fetch (used at startup and by the refresher loop) |

Config changes are applied by `docker compose restart` (everything is rendered
at container start).

## Delivery semantics

- Graph delivers to the recipients in the **MIME headers**; envelope
  recipients missing from To/Cc (e.g. a printer's BCC) are added as a `Bcc`
  header, which Exchange honors and strips.
- Graph errors map to queue behavior: `429`/`5xx` and network failures are
  **deferred and retried**, other `4xx` (e.g. access denied by the policy
  above) **bounce** back to the printer.
- Sent mail lands in the sending mailbox's **Sent Items** (Graph default).

## Security notes

- The relay accepts mail **only** from `PRINTER_NETWORKS` IPs or authenticated
  clients, and **only** with whitelisted senders — it is not an open relay,
  but still: run it on an internal network, don't expose port 25 to the internet.
- Auth on port 25/587 permits plaintext passwords because most printers can't
  do STARTTLS; treat printer passwords accordingly (LAN-only).
- SMTP AUTH can stay **disabled** on all mailboxes — the outbound leg is
  HTTPS-only. Without an application access policy (step 2) the app could
  send as anyone in the tenant; don't skip it.

## Testing

- `./test/graph-send.test.sh` — unit tests for the Graph delivery script
  against a local mock endpoint (needs bash, curl, python3).
- `./test/smoke.sh` — boots an isolated stack (mock Entra + Graph endpoints,
  fixture config) and replays SMTP dialogues against ports 25/587: sender
  whitelist enforcement (also for authenticated clients), relay denial for
  untrusted IPs, printer SASL login, and end-to-end delivery of an accepted
  message to the mock Graph `sendMail` endpoint.

## Troubleshooting

```bash
docker compose logs -f            # postfix + token refresher + graph-send stderr
docker compose exec postfix postqueue -p    # stuck mail
```

- `graph-send: HTTP 401 ... bouncing` → token rejected: admin consent missing
  or wrong tenant/client/secret.
- `graph-send: HTTP 403 ErrorAccessDenied` → sender mailbox not covered by the
  application access policy, or `Mail.Send` not granted.
- `graph-send: HTTP 404` → envelope sender is not a mailbox in the tenant.
- `550 ... Access denied` at MAIL FROM on the relay → sender not in
  `config/allowed_senders`.
- Mail stuck in the queue with `deferred` → check `docker compose logs` for
  `graph-send: HTTP 429/5xx` (throttling/outage) or token fetch failures.
