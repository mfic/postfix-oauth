# Postfix → Microsoft 365 relay for printers

A dockerized Postfix MTA that lets printers/scanners with **no modern auth
support** send mail through Microsoft 365. Printers connect either

- **without authentication**, if their fixed IP is whitelisted, or
- **with a per-printer username/password** (SASL PLAIN/LOGIN on port 587 or 25).

**Sender lockdown:** only envelope senders listed in `config/allowed_senders`
are accepted — for every client, whitelisted or authenticated. Anything else is
rejected with `550`. So printers can *choose* a sender, but only from the
predefined list.

## Two outbound modes, one image

Outbound to Microsoft 365 there are two variants; pick one by starting the
matching compose file. The inbound policy, printer setup, and testing are
identical in both.

| | `docker-compose.graph.yml` (recommended) | `docker-compose.smtp.yml` |
|---|---|---|
| Transport | HTTPS: Graph `sendMail` per message (`POST /users/{envelope-sender}/sendMail`) | SMTP submission to `smtp.office365.com:587` with XOAUTH2 (`sasl-xoauth2`) |
| Entra permission | Microsoft Graph → Application → `Mail.Send` | Office 365 Exchange Online → Application → `SMTP.SendAsApp` |
| Exchange setup | One application access policy | Service principal + mailbox permission + SendAs grants, SMTP AUTH enabled on the mailbox |
| `.env` extras | — | `RELAY_MAILBOX` |
| SMTP AUTH at Microsoft | can stay disabled tenant-wide | must be enabled on the relay mailbox |

Both use app-only client credentials — no user password anywhere — and a small
refresher loop keeps the access token fresh.

## Setup

### 1. Entra ID app registration

1. Entra admin center → App registrations → New registration (e.g. `postfix-relay`).
2. API permissions → Add a permission →
   - **graph mode:** *Microsoft Graph* → **Application permissions** → `Mail.Send`
   - **smtp mode:** *APIs my organization uses* → **Office 365 Exchange Online**
     → **Application permissions** → `SMTP.SendAsApp`
3. **Grant admin consent** for the added permission.
4. Certificates & secrets → New client secret → note the **value**.
5. Note the **Application (client) ID** and **Directory (tenant) ID**.

### 2a. Exchange Online for graph mode: scope what the app may send as

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

### 2b. Exchange Online for smtp mode: register the service principal

With the app's enterprise-application **Object ID** and **App ID**:

```powershell
New-ServicePrincipal -AppId <CLIENT_ID> -ObjectId <ENTERPRISE_APP_OBJECT_ID>
Add-MailboxPermission -Identity printers@example.com `
    -User <ENTERPRISE_APP_OBJECT_ID> -AccessRights FullAccess

# SMTP AUTH must be enabled on the relay mailbox:
Set-CASMailbox -Identity printers@example.com -SmtpClientAuthenticationDisabled $false

# let the relay send as additional allowed_senders addresses:
Add-RecipientPermission scanner@example.com -Trustee printers@example.com -AccessRights SendAs
```

> M365 verifies the sender: mail from an address the relay mailbox has no
> SendAs right for is rejected by Microsoft even if this relay accepts it.

### 3. Configure and start the relay

```bash
cp .env.example .env                                    # fill in tenant/client/secret
cp config/allowed_senders.example config/allowed_senders
cp config/printer_accounts.example config/printer_accounts   # optional

docker compose -f docker-compose.graph.yml up -d --build     # graph mode
# or: docker compose -f docker-compose.smtp.yml up -d --build (needs RELAY_MAILBOX)

docker compose -f docker-compose.graph.yml logs -f    # watch for "token-refresher: new access token"
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
| `docker-compose.graph.yml` / `docker-compose.smtp.yml` | Same relay, outbound mode baked in via `OUTBOUND_MODE` |
| `config/allowed_senders` | Sender whitelist (one address per line) — **required** |
| `config/printer_accounts` | Optional `user password` lines for SASL accounts |
| `config/tls/cert.pem` + `key.pem` | Optional real TLS cert (self-signed otherwise) |
| `postfix/main.cf.tmpl`, `postfix/master.cf` | The Postfix policy — rendered/copied at startup, linted with `postfix check` |
| `scripts/outbound-graph.sh` / `scripts/outbound-smtp.sh` | Outbound-mode adapters: each owns its mode's Postfix config, aux services, OAuth scope, and token store |
| `scripts/graph-send.sh` | graph mode pipe transport: posts one queued message to Graph `sendMail` |
| `scripts/fetch-token.sh` | One-shot Entra ID token fetch; hands the token to the mode adapter (used at startup and by the refresher loop) |

Config changes are applied by `docker compose -f <file> restart` (everything
is rendered at container start).

## Delivery semantics (graph mode)

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
- graph mode: without an application access policy (step 2a) the app could
  send as anyone in the tenant; don't skip it.
- smtp mode: Microsoft is retiring Basic Auth for SMTP submission through
  2026; XOAUTH2 as used here is the supported replacement path.

## Testing

- `./test/graph-send.test.sh` — unit tests for the Graph delivery script
  against a local mock endpoint (needs bash, curl, python3).
- `./test/smtp-dialogue.sh` — response-driven SMTP driver used by the smoke
  test (each command is sent when the previous reply completes; no sleeps).
- `./test/smoke.sh` — boots an isolated stack per outbound mode (mock
  Entra/Graph endpoints, fixture config) and replays SMTP dialogues against
  ports 25/587: sender whitelist enforcement (also for authenticated
  clients), relay denial for untrusted IPs, and printer SASL login, in both
  modes. In graph mode an accepted message is additionally followed
  end-to-end to the mock Graph `sendMail` endpoint; the real
  `smtp.office365.com` leg of smtp mode needs real credentials and is not
  covered.

## Troubleshooting

```bash
docker compose -f docker-compose.graph.yml logs -f   # postfix + token refresher (+ graph-send/sasl-xoauth2 errors)
docker compose -f docker-compose.graph.yml exec postfix postqueue -p   # stuck mail
```

graph mode:

- `graph-send: HTTP 401 ... bouncing` → token rejected: admin consent missing
  or wrong tenant/client/secret.
- `graph-send: HTTP 403 ErrorAccessDenied` → sender mailbox not covered by the
  application access policy, or `Mail.Send` not granted.
- `graph-send: HTTP 404` → envelope sender is not a mailbox in the tenant.
- Mail stuck in the queue with `deferred` → check the logs for
  `graph-send: HTTP 429/5xx` (throttling/outage) or token fetch failures.

smtp mode:

- `535 5.7.3 Authentication unsuccessful` from Microsoft → service principal
  not registered / no mailbox permission / SMTP AUTH disabled on the mailbox
  (step 2b), or admin consent missing (step 1).
- Sender rejected by Microsoft (`SendAsDenied`) → missing `Add-RecipientPermission`.

both modes:

- `550 ... Access denied` at MAIL FROM on the relay → sender not in
  `config/allowed_senders`.
