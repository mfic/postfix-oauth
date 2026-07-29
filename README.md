# Postfix → Microsoft 365 OAuth2 relay for printers

A dockerized Postfix MTA that lets printers/scanners with **no modern auth
support** send mail through Microsoft 365. Printers connect either

- **without authentication**, if their fixed IP is whitelisted, or
- **with a per-printer username/password** (SASL PLAIN/LOGIN on port 587 or 25).

Outbound, Postfix authenticates to `smtp.office365.com` with **OAuth2 client
credentials** (app-only, no user password anywhere) via the `sasl-xoauth2`
plugin. Because that plugin only handles refresh tokens, a small refresher
loop fetches app-only access tokens from Entra ID and keeps the token file
fresh.

**Sender lockdown:** only envelope senders listed in `config/allowed_senders`
are accepted — for every client, whitelisted or authenticated. Anything else is
rejected with `550`. So printers can *choose* a sender, but only from the
predefined list.

## Setup

### 1. Entra ID app registration

1. Entra admin center → App registrations → New registration (e.g. `postfix-relay`).
2. API permissions → Add a permission → *APIs my organization uses* →
   **Office 365 Exchange Online** → **Application permissions** →
   `SMTP.SendAsApp` → add, then **Grant admin consent**.
3. Certificates & secrets → New client secret → note the **value**.
4. Note the **Application (client) ID** and **Directory (tenant) ID**.

### 2. Exchange Online: register the service principal on the mailbox

In Exchange Online PowerShell (`Connect-ExchangeOnline`), with the app's
enterprise-application **Object ID** and **App ID**:

```powershell
New-ServicePrincipal -AppId <CLIENT_ID> -ObjectId <ENTERPRISE_APP_OBJECT_ID>
Add-MailboxPermission -Identity printers@example.com `
    -User <ENTERPRISE_APP_OBJECT_ID> -AccessRights FullAccess

# SMTP AUTH must be enabled on the relay mailbox:
Set-CASMailbox -Identity printers@example.com -SmtpClientAuthenticationDisabled $false
```

To let the relay send as *additional* addresses (everything in
`allowed_senders` that isn't the mailbox's own address), grant SendAs:

```powershell
Add-RecipientPermission scanner@example.com -Trustee printers@example.com -AccessRights SendAs
```

> M365 verifies the sender: mail from an address the relay mailbox has no
> SendAs right for is rejected by Microsoft even if this relay accepts it.

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
| `.env` | Tenant/app credentials, relay mailbox, hostname, printer IPs |
| `config/allowed_senders` | Sender whitelist (one address per line) — **required** |
| `config/printer_accounts` | Optional `user password` lines for SASL accounts |
| `config/tls/cert.pem` + `key.pem` | Optional real TLS cert (self-signed otherwise) |
| `postfix/main.cf.tmpl`, `postfix/master.cf` | The Postfix policy — rendered/copied at startup, linted with `postfix check` |
| `scripts/fetch-token.sh` | One-shot Entra ID token fetch (used at startup and by the refresher loop) |

Config changes are applied by `docker compose restart` (everything is rendered
at container start).

## Security notes

- The relay accepts mail **only** from `PRINTER_NETWORKS` IPs or authenticated
  clients, and **only** with whitelisted senders — it is not an open relay,
  but still: run it on an internal network, don't expose port 25 to the internet.
- Auth on port 25/587 permits plaintext passwords because most printers can't
  do STARTTLS; treat printer passwords accordingly (LAN-only).
- Heads-up: Microsoft is retiring Basic Auth for SMTP submission through 2026 —
  this OAuth2 setup is the supported replacement path.

## Testing

`./test/smoke.sh` boots an isolated stack (dummy credentials, fixture config)
and replays six SMTP dialogues against ports 25/587: sender whitelist
enforcement (also for authenticated clients), relay denial for untrusted IPs,
and printer SASL login. The outbound M365 leg needs real credentials and is
not covered.

## Troubleshooting

```bash
docker compose logs -f            # postfix + token refresher + sasl-xoauth2 (syslog)
docker compose exec postfix postqueue -p    # stuck mail
```

- `535 5.7.3 Authentication unsuccessful` from Microsoft → service principal
  not registered / no mailbox permission / SMTP AUTH disabled on the mailbox
  (step 2), or admin consent missing (step 1).
- `550 ... Access denied` at MAIL FROM on the relay → sender not in
  `config/allowed_senders`.
- Sender rejected by Microsoft (`SendAsDenied`) → missing `Add-RecipientPermission`.
