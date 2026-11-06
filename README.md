# Postfix → Microsoft 365 relay for printers

A dockerized Postfix MTA that lets printers/scanners with **no modern auth
support** send mail through Microsoft 365. Printers connect either

- **without authentication**, if their IP is in `config/trusted_networks`, or
- **with a per-printer username/password** (SASL PLAIN/LOGIN on port 587 or 25).

**Sender lockdown:** only envelope senders listed in `config/allowed_senders`
are accepted — for every client, whitelisted or authenticated. Anything else is
rejected with `554`. So printers can *choose* a sender, but only from the
predefined list.

**Per-client mailboxes (optional):** a printer listed in
`config/client_senders`, by source IP or SASL account, always sends as its own
mailbox, whatever it has configured. Its MAIL FROM is not checked against the
list, because it is replaced by that mailbox. See [step 3a](#3a-optional-give-a-printer-its-own-mailbox).

## Two outbound modes, one image

Outbound to Microsoft 365 there are two variants; pick one by starting the
matching compose file. The inbound policy, printer setup, and testing are
identical in both.

| | `docker-compose.graph.yml` (recommended) | `docker-compose.smtp.yml` |
|---|---|---|
| Transport | HTTPS: Graph `sendMail` per message (`POST /users/{envelope-sender}/sendMail`) | SMTP submission to `smtp.office365.com:587` with XOAUTH2 (`sasl-xoauth2`) |
| Entra permission | None: `Application Mail.Send` is granted in Exchange Online instead | Office 365 Exchange Online → Application → `SMTP.SendAsApp` |
| Exchange setup | Service principal + scoped role assignment (RBAC for Applications) | Service principal + mailbox permission + SendAs grants, SMTP AUTH enabled on the mailbox |
| `.env` extras | — | `RELAY_MAILBOX` |
| SMTP AUTH at Microsoft | can stay disabled tenant-wide | must be enabled on the relay mailbox |

Both use app-only client credentials — no user password anywhere — and a small
refresher loop keeps the access token fresh.

## Setup

### 1. Entra ID app registration

1. Entra admin center → App registrations → New registration (e.g. `postfix-relay`).
2. API permissions → Add a permission →
   - **graph mode:** add **no** `Mail.Send` permission here. Step 2a grants it
     in Exchange Online, scoped to the relay's mailboxes. An Entra grant is
     tenant-wide and would make that scoping pointless.
   - **smtp mode:** *APIs my organization uses* → **Office 365 Exchange Online**
     → **Application permissions** → `SMTP.SendAsApp`
3. smtp mode: **Grant admin consent** for the added permission.
4. Certificates & secrets → New client secret → note the **value**.
5. Note the **Application (client) ID** and **Directory (tenant) ID**.

### 2a. Exchange Online for graph mode: scope what the app may send as

Grant `Mail.Send` only for the relay's mailboxes with
[RBAC for Applications](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac),
which replaces Application Access Policies. You need the Organization Management
role group. With the **Application ID** and **Object ID** from *Enterprise
applications* (not App registrations, which shows a different Object ID), in
Exchange Online PowerShell (`Connect-ExchangeOnline`):

```powershell
New-ServicePrincipal -AppId <CLIENT_ID> -ObjectId <ENTERPRISE_APP_OBJECT_ID> -DisplayName postfix-relay

# a group whose DIRECT members are every mailbox the relay may send as;
# members of nested groups are out of scope
$group = (Get-Group relay-senders@example.com).DistinguishedName
New-ManagementScope -Name "postfix-relay senders" -RecipientRestrictionFilter "MemberOfGroup -eq '$group'"

New-ManagementRoleAssignment -App <ENTERPRISE_APP_OBJECT_ID> -Role "Application Mail.Send" `
    -CustomResourceScope "postfix-relay senders"

# InScope must be True for a relay mailbox, False for any other
Test-ServicePrincipalAuthorization -Identity <CLIENT_ID> -Resource printers@example.com
```

An administrative unit works too: replace the scope and `-CustomResourceScope`
with `-RecipientAdministrativeUnitScope <ADMIN_UNIT_ID>`.

- **The scope only works if the app has no tenant-wide grant.** The two
  permission systems add up, so an Entra `Mail.Send` consent still lets the app
  send as anyone. If it was ever granted, remove it (App registration → API
  permissions → remove the permission, and revoke admin consent).
- **Changes take 30 minutes to 2 hours to apply** to a running app.
  `Test-ServicePrincipalAuthorization` bypasses that cache, so it can succeed
  while the relay still gets the old result.

Every address in `config/allowed_senders` must be a mailbox (or an alias of
one — sending from aliases additionally needs `Set-OrganizationConfig
-SendFromAliasEnabled $true`) covered by that scope.

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
cp config/trusted_networks.example config/trusted_networks   # optional
cp config/client_accounts.example config/client_accounts     # optional
cp config/client_senders.example config/client_senders       # optional, see 3a

docker compose -f docker-compose.graph.yml up -d --build     # graph mode
# or: docker compose -f docker-compose.smtp.yml up -d --build (needs RELAY_MAILBOX)

docker compose -f docker-compose.graph.yml logs -f    # watch for "token-refresher: new access token"
```

### 3a. Optional: give a printer its own mailbox

Each line of `config/client_senders` maps a client to a mailbox:

```
192.168.10.21    scanner@example.com
printer-lobby    printers@example.com
```

- The relay **overwrites** the sender of a listed client: it replaces the
  envelope sender and the From header and removes any Sender header, whatever
  the printer sends. The printer's From display name is dropped too. Reply-To is
  left alone.
- A client **not** listed keeps today's behaviour: it chooses any sender from
  `allowed_senders`. With no entries the relay's policy is unchanged.
- If both an IP and an account match, the account wins. Among IP entries, the
  first match wins.
- Each mailbox must be in `allowed_senders`, each account in `client_accounts`,
  and an IP must be a valid address or CIDR. Otherwise the relay refuses to
  start, because a skipped line would let that client choose its own sender.
- The file grants no relay access: a listed IP still has to be in
  `config/trusted_networks` or authenticate.
- Each mailbox also needs what step 2a or 2b requires for any sender. In smtp
  mode that means a SendAs grant for `RELAY_MAILBOX`.
- IP matching needs the relay to see the printer's real source IP. Check for it
  in the `connect from` log lines, especially behind a Docker port mapping,
  where a proxy or NAT can replace it with a gateway address.

A mapped message appears in the log twice: under its first queue ID with
`relay=sender-rewrite`, then under a new ID with `from=<mailbox>`.

### 4. Point the printers at it

| Printer capability | Settings |
|---|---|
| No auth (IP in `config/trusted_networks`) | SMTP server = relay IP, port 25, no auth, no TLS needed |
| Username/password | Port 587 (or 25), STARTTLS if supported, PLAIN/LOGIN with an account from `config/client_accounts` |

The From/sender address on the printer must be one of `config/allowed_senders`,
unless the printer has a mapped mailbox (step 3a).

**TLS** is offered on ports 25 and 587 through STARTTLS, and is optional:

- **Certificate:** the relay uses a self-signed certificate by default, and a
  printer that checks certificates will refuse it. Get a real one through
  [Let's Encrypt](#4a-optional-a-lets-encrypt-certificate), or put your own in
  `config/tls/cert.pem` and `key.pem`, with a name matching the address the printer
  connects to. Don't import the self-signed certificate on a printer: a new one is
  generated whenever the container is recreated, such as by an update.
- **Renewing your own certificate:** replace the files in `config/tls/`. The relay
  loads them within 5 minutes, with no restart. A key that doesn't match its
  certificate is logged and ignored, and the current certificate stays in use.
- **Port 465 is not available:** a printer that only offers implicit TLS ("SSL/TLS"
  rather than STARTTLS) can't connect.
- **Versions:** the relay accepts TLS 1.2 and 1.3. It refuses TLS 1.0 and 1.1 on both
  ports, and that will affect older printers: in a live test, one real printer used
  TLS 1.0, and failed once it was refused, without falling back to plain text. TLS
  itself stays optional, so what a refused printer does next is up to the printer:
  another model may **send in plain text, password included**. Check each older
  printer after updating. A refused
  attempt logs `SSL_accept error from <client>`, and a printer that fell back has no
  `TLS connection established` line for its message.
- **A printer that can't do TLS 1.2:** set `TLS_MIN_VERSION=TLSv1` in `.env`, then run
  `docker compose up -d`. This applies to every client on both ports, though a client
  that supports newer versions still negotiates them. The accepted values are `TLSv1`,
  `TLSv1.1`, `TLSv1.2` and `TLSv1.3`.
- **Ciphers:** anonymous ciphers are refused. Older ones such as AES-CBC with SHA-1 are
  still accepted, because older printers may need them.
- **Which printers use TLS:** each TLS connection logs a line. A client with no
  such line sent in plain text.

  ```bash
  docker compose logs | grep 'TLS connection established'
  ```

### 4a. Optional: a Let's Encrypt certificate

A sidecar container obtains the certificate through a Cloudflare DNS challenge and
renews it. The relay needs no inbound access from the internet, and its name doesn't
have to resolve publicly. You need:

- `POSTFIX_HOSTNAME` in a public domain whose DNS is on Cloudflare
- printers that connect by that name, not by IP, so internal DNS must resolve it
- printers that trust ISRG Root X1, which some older ones don't

Certificates are published in public Certificate Transparency logs, so this makes
the relay's hostname public. Starting the sidecar also accepts the
[Let's Encrypt Subscriber Agreement](https://letsencrypt.org/repository/).

1. In Cloudflare, create an API token with one permission, **Zone > DNS > Edit**,
   limited to the zone containing `POSTFIX_HOSTNAME`.
2. Store it in `cloudflare.ini`, not in `.env`, because the relay receives everything
   in `.env`:

   ```bash
   cp cloudflare.ini.example cloudflare.ini
   chmod 600 cloudflare.ini
   # add the token to cloudflare.ini
   ```

3. Add these lines to `.env` and start the sidecar. Remove `config/tls/` first if you
   have it, because the relay refuses to start with both. The staging server issues
   an untrusted test certificate, without using up production limits:

   ```bash
   COMPOSE_PROFILES=letsencrypt
   LETSENCRYPT_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory
   ```

   ```bash
   docker compose up -d
   ```

4. Within about 6 minutes the relay logs
   `TLS certificate: installed a new one from Let's Encrypt`. Until then it serves
   the self-signed certificate. Mail keeps flowing either way.
5. Switch to production: remove the `LETSENCRYPT_SERVER` line from `.env`, then delete
   the staging certificate, because certbot would otherwise keep it until it's due:

   ```bash
   docker compose exec certbot certbot delete --non-interactive --cert-name <POSTFIX_HOSTNAME>
   docker compose up -d
   ```

   The relay serves its self-signed certificate until the new one arrives, about 6
   minutes. Mail keeps flowing, but a printer that checks certificates fails during
   that time, so pick a quiet moment. This gap only happens here: normal renewals swap
   the certificate directly.

The sidecar checks every 12 hours and renews when due, and the relay then loads the
new certificate with no restart. A failed attempt is logged by the sidecar and retried
after an hour, and the relay keeps its current certificate. From 14 days before expiry
the relay logs a daily warning, so watch for this line:

```bash
docker compose logs | grep 'WARNING: the TLS certificate'
```

### 5. Updating

```bash
bash update.sh
```

This runs `git pull --ff-only`, rebuilds on a fresh base image, restarts the
container if anything changed, and shows the container's status. `.env`, your
files in `config/` and the mail queue are kept. It rebuilds even when the repo has
no new commits, so running it also picks up a newer base image.

`update.sh` needs to know your outbound mode, so `.env` must name the compose
file. Use one of these lines:

```bash
COMPOSE_FILE=docker-compose.graph.yml   # graph mode
COMPOSE_FILE=docker-compose.smtp.yml    # smtp mode
```

**Clone from before `update.sh` existed:** add the line above to `.env`, then:

```bash
git pull --ff-only
bash update.sh
```

**Following a branch:** `update.sh` updates whichever branch the clone is on, and
ignores new commits on any other branch. To test a branch:

```bash
git fetch origin
git switch <branch>
bash update.sh
```

**Back to `main`,** once the branch is merged (before that, `main` may lack
changes you are relying on):

```bash
git fetch origin --prune
git switch main
bash update.sh
git branch -d <branch>     # optional
```

If the pull can't be done cleanly, `update.sh` stops before it builds anything,
and the running relay is left as it was:

| Situation | What you see | What to do |
|---|---|---|
| Branch was force-pushed | `Not possible to fast-forward` | `git reset --hard origin/<branch>`, which discards local commits and edits to tracked files |
| Branch was deleted on GitHub | `no such ref was fetched` | Switch back to `main` as above |
| Tracked file edited locally | An error naming your local changes | `git diff` to review, then `git checkout -- <file>` to discard |
| No branch checked out | `You are not currently on a branch` | `git switch main` |

## Files

| File | Purpose |
|---|---|
| `.env` | Tenant/app credentials, hostname, `COMPOSE_FILE`, failure notice mailboxes |
| `update.sh` | Pulls, rebuilds and restarts a deployed relay |
| `docker-compose.graph.yml` / `docker-compose.smtp.yml` | Same relay, outbound mode baked in via `OUTBOUND_MODE` |
| `config/allowed_senders` | Sender whitelist (one address per line) — **required** |
| `config/trusted_networks` | Optional IPs/CIDRs that may relay without authentication (one per line) |
| `config/client_accounts` | Optional `user password` lines for SASL accounts |
| `config/client_senders` | Optional `client mailbox` lines giving a printer its own sender (step 3a) |
| `config/tls/cert.pem` + `key.pem` | Optional real TLS cert (self-signed otherwise, see step 4) |
| `cloudflare.ini` | Optional Cloudflare token for the Let's Encrypt sidecar (step 4a), mounted only into the sidecar |
| `postfix/main.cf.tmpl`, `postfix/master.cf` | The Postfix policy — rendered/copied at startup, linted with `postfix check` |
| `scripts/entrypoint.sh` | Container start: renders the Postfix config, runs the mode adapter's `setup`, starts the token refresher and Postfix |
| `scripts/config-tables.sh` | The one reader of `config/`: checks each file and turns it into Postfix tables, SASL accounts and the sender policy |
| `scripts/outbound-graph.sh` / `scripts/outbound-smtp.sh` | Outbound-mode adapters: each owns its mode's Postfix config, aux services, OAuth scope, and token store |
| `scripts/graph-send.sh` | graph mode pipe transport: posts one queued message to Graph `sendMail` |
| `scripts/failure-notice.sh` | graph mode: turns a Postfix bounce into the plain text failure notice that `graph-send.sh` posts |
| `scripts/graph-size-test.sh` | graph mode: sends real test mails to find which scan sizes Microsoft accepts |
| `scripts/tls-cert.sh` | Chooses the certificate Postfix serves and loads a new one when it changes |
| `scripts/letsencrypt-renew.sh` | Runs in the certbot sidecar: obtains and renews the Let's Encrypt certificate. `.dockerignore` keeps it out of the relay image |
| `scripts/sender-rewrite.sh` | Pipe transport for mapped clients: overwrites the sender, then re-injects the message |
| `scripts/fetch-token.sh` | One-shot Entra ID token fetch; hands the token to the mode adapter (used at startup and by the refresher loop) |
| `scripts/token-refresher.sh` | Background loop: calls `fetch-token.sh`, sleeps until well before expiry, repeats |

Everything is rendered at container start. Changes in `config/` are applied by
`docker compose restart`, except `config/tls/`, which is loaded by itself. Changes in `.env` need `docker compose up -d`, because
Docker only reads that file when it creates the container.


## Delivery semantics (graph mode)

- Graph delivers to the recipients in the **MIME headers**; envelope
  recipients missing from To/Cc (e.g. a printer's BCC) are added as a `Bcc`
  header, which Exchange honors and strips.
- Graph errors map to queue behavior: `429`/`5xx` and network failures are
  **deferred and retried**, other `4xx` (e.g. access denied by the scope above)
  **fail the message**. See [Failure notices](#failure-notices).
- Sent mail lands in the sending mailbox's **Sent Items** (Graph default).

### Large scans

The relay accepts messages up to 50 MB. In a live test on one tenant (November
2026), Graph accepted and delivered attachments of 1, 2, 3, 5 and 10 MB. The 10 MB
one was a 19 MB request, so Microsoft's documented 4 MB limit on Graph write
requests did not apply to `sendMail` there. **The actual ceiling is unknown:**
nothing above 10 MB has been tested, and other tenants or receiving mail systems
may differ. A scan is base64-encoded in the MIME message, and the whole message is
encoded again for Graph, so the request is about 1.8x the scan.

A rejected message fails instead of retrying, and is logged with its size. A
`413` is logged as `graph-send: MESSAGE TOO LARGE`, with the message and request
sizes. Any other rejection also includes the sizes. Microsoft has not yet been
seen refusing a message for its size, so the status code it uses is unconfirmed.

To check other sizes, send test mails (real ones, to a mailbox you can check):

```bash
docker compose -f docker-compose.graph.yml exec postfix \
    graph-size-test.sh printers@example.com you@example.com 10 20 30   # attachment MB
```

## Failure notices

The printer never learns of a failure once the relay has accepted the message, so
failures need somewhere to go. In graph mode, set both of these in `.env`:

```bash
FAILURE_NOTICE_MAILBOX=it@example.com         # receives the notices
FAILURE_NOTICE_SENDER=no-reply@example.com    # sends them
FAILURE_NOTICE_ATTACH_MESSAGE=no              # optional, yes attaches the failed message
```

- The sender must be a mailbox in the app's scope (step 2a). It doesn't need to be
  in `allowed_senders`. The recipient can be any address.
- A notice is plain text with the queue ID, sender, decoded subject, failed recipients and
  failure reason, including Graph's error. It contains the message's content only
  with `FAILURE_NOTICE_ATTACH_MESSAGE=yes`.
- With that setting, the failed message is attached, so the recipient sees any scans
  it contains. Outlook shows it as a `.msg` named after the message's subject. If Graph refuses the notice with the
  attachment, for example because the message was too large, the relay sends the
  notice again without it and says so in the text.
  Plain text is required: in a live test, Graph accepted Postfix's usual
  `multipart/report` bounce format, but Exchange routed it back to the sending
  mailbox's Inbox instead of its recipient. So a `2xx` from Graph, or a copy in Sent
  Items, doesn't prove delivery.
- Without these settings, or if a notice itself is refused, the only record is the
  log. Each such notice is logged as `graph-send: FAILURE NOTICE NOT SENT`, with the
  original message's queue ID and the failed recipients:

```bash
docker compose logs postfix | grep -E 'status=bounced|FAILURE NOTICE'
```

A notice that was sent shows up in the log as `from=<>` and `status=sent`, with the
**failed message's sender** in `to=`, not `FAILURE_NOTICE_MAILBOX`. The relay swaps
the recipient after Postfix logs that address, so check the mailbox itself to confirm
arrival.

Postfix's notices to the postmaster are only ever logged, because their SMTP
transcript can contain printer credentials.

smtp mode ignores these settings. Notices go to Microsoft with an empty sender
through the relay mailbox, and whether Microsoft accepts them is **not yet tested**.

## Security notes

- The relay accepts mail **only** from `config/trusted_networks` IPs or authenticated
  clients, and **only** with whitelisted or mapped senders — it is not an open relay,
  but still: run it on an internal network, don't expose port 25 to the internet.
- Auth on port 25/587 permits plaintext passwords because most printers can't
  do STARTTLS; treat printer passwords accordingly (LAN-only).
- graph mode: the app can send as anyone in the tenant if it has an Entra
  `Mail.Send` consent or an unscoped role assignment. Follow step 2a and check
  it with `Test-ServicePrincipalAuthorization`.
- The relay checks only the **envelope** sender, so a printer without a mapped
  mailbox can put any address in the **From header**. In a live test in graph mode,
  Microsoft refused a From outside the app's scope with a `403`, and the message
  failed. A From naming a second mailbox **inside** the scope is **not yet tested**.
  Clients with a mapped mailbox (step 3a) are not affected, because their From is
  overwritten.
- The Cloudflare token can edit DNS for its whole zone. It's only in `cloudflare.ini`
  and the sidecar's volume, never in the relay. The relay does mount the volume
  read-only for the certificate, which also holds certbot's Let's Encrypt account key.
- smtp mode: Microsoft is retiring Basic Auth for SMTP submission through
  2026; XOAUTH2 as used here is the supported replacement path.

## Testing

- `./test/graph-send.test.sh` — unit tests for the Graph delivery script
  against a local mock endpoint (needs bash, curl, python3), including a few
  failure notices end to end.
- `./test/failure-notice.test.sh` — unit tests for building a failure notice: a
  bounce goes in, MIME comes out, with no mock.
- `./test/sender-rewrite.test.sh` — unit tests for the sender rewrite, with a
  stub `sendmail`.
- `./test/tls-cert.test.sh` — unit tests for choosing the certificate, with real
  `openssl` and a stub `postfix`, no Docker: source order, every FATAL, mismatches,
  what the watcher does on a pass, expiry warnings and the self-signed rules.
- `./test/config.test.sh` — tests for the config reader, with each case's files
  written inline: the tables, the SASL accounts and every FATAL, including CRLF,
  a missing final newline and comment-only files. Needs Docker: it builds the
  relay image and runs in one throwaway container, with no stack, because
  `postmap` and `saslpasswd2` exist only there.
- `./test/smtp-dialogue.sh` — response-driven SMTP driver used by the smoke
  test (each command is sent when the previous reply completes; no sleeps).
- `./test/smoke.sh` — boots an isolated stack per outbound mode (mock
  Entra/Graph endpoints, fixture config) and replays SMTP dialogues against
  ports 25/587: sender whitelist enforcement (also for authenticated
  clients), relay denial for untrusted IPs, and printer SASL login, in both
  modes. In graph mode an accepted message is additionally followed
  end-to-end to the mock Graph `sendMail` endpoint; the real
  `smtp.office365.com` leg of smtp mode needs real credentials and is not
  covered. A bad config file is shown to stop a real boot, for each of the
  entrypoint's two calls to the config reader; `config.test.sh` has every other
  rule. Separate stacks cover per-client mailboxes: followed to the mock Graph
  in graph mode, and to the queue, with delivery held, in smtp mode. Further stacks
  cover TLS certificates: your own served to a client, renewed on disk with a real
  `postfix reload`, a bad pair stopping a real boot, and the real certbot sidecar
  against Pebble, Let's Encrypt's test server, with a mock Cloudflare API
  (`test/mock-cloudflare.py`). `tls-cert.test.sh` has every other certificate rule.
  Run part of it with `./test/smoke.sh <section>...`: `graph`, `notice-attachment`, `trusted-networks`, `bad-config`, `graph-mapped`, `older-tls`, `certificates`, `letsencrypt`, `smtp`, `smtp-mapped`.

Everything in this section runs against mocks. It proves what the relay sends, not what
Microsoft does with it. **Not yet proven against a real tenant:**

- attachments above 10 MB, and the status code Graph uses to refuse by size
- a From naming a second mailbox inside the app's scope
- whether a real printer checks the relay's certificate. Printers have connected over
  TLS with a production Let's Encrypt certificate, but the log can't show whether
  they checked it
- all of smtp mode's connection to `smtp.office365.com`, including SendAs and
  failure notices

Tested live once in graph mode, on one tenant (November 2026): a send under RBAC for
Applications with no Entra `Mail.Send` consent, refusal of a sender outside the
scope, attachments up to 10 MB, refusal of a From outside the scope, delivery as a
mapped mailbox, and a real failure producing a notice that arrived, both without the
message's content and with it attached.

### Continuous checks

- **`.github/workflows/ci.yml`** — runs shellcheck and the test scripts on
  every push to `main` and every pull request.
- **`.github/workflows/upstream-drift.yml`** — weekly, and on demand: rebuilds
  the image with `--no-cache --pull` and runs the same tests. The repo does not
  change between runs, so a failure means the *outside* moved — a new
  `debian:trixie-slim`, a changed Debian package, sasl-xoauth2, or Microsoft.
  A failing run opens (or comments on) an `upstream-drift` issue.
- **`renovate.json`** — Renovate watches the container images, the GitHub
  Actions, and the `SASL_XOAUTH2_VERSION` build arg, and files PRs. The Debian
  base image is deliberately excluded: moving to the next Debian release is a
  decision, not a routine bump. `ignorePaths` is overridden because
  `config:recommended` skips `**/test/**` by default, and `test/compose.*.yml`
  is the only place this repo pins an image (`python:3-alpine`). Renovate needs
  its GitHub App installed on the repository; it then keeps a Dependency
  Dashboard issue up to date.

## Troubleshooting

```bash
docker compose -f docker-compose.graph.yml logs -f   # postfix + token refresher (+ graph-send/sasl-xoauth2 errors)
docker compose -f docker-compose.graph.yml exec postfix postqueue -p   # stuck mail
```

graph mode:

- `graph-send: HTTP 401 ... bouncing` → token rejected: admin consent missing
  or wrong tenant/client/secret.
- `graph-send: HTTP 403 ErrorAccessDenied` → the sender mailbox, or the address
  in the message's From header, is not in the scope, or there is no
  `Application Mail.Send` role assignment (step 2a). Check with
  `Test-ServicePrincipalAuthorization -Identity <CLIENT_ID> -Resource <mailbox>`;
  a recent change can take up to 2 hours to reach the relay.
- `graph-send: MESSAGE TOO LARGE` → see [Large scans](#large-scans).
- `graph-send: FAILURE NOTICE NOT SENT` → a message failed, and this is the notice
  that could not go out. See [Failure notices](#failure-notices).
- `graph-send: HTTP 404` → envelope sender is not a mailbox in the tenant.
- Mail stuck in the queue with `deferred` → check the logs for
  `graph-send: HTTP 429/5xx` (throttling/outage) or token fetch failures.

smtp mode:

- `535 5.7.3 Authentication unsuccessful` from Microsoft → service principal
  not registered / no mailbox permission / SMTP AUTH disabled on the mailbox
  (step 2b), or admin consent missing (step 1).
- Sender rejected by Microsoft (`SendAsDenied`) → missing `Add-RecipientPermission`.

both modes:

- `554 ... Sender address rejected: Access denied` on the relay → sender not in
  `config/allowed_senders`.
- `FATAL: /config/client_senders: ...` or `FATAL: /config/trusted_networks: ...` at
  startup → fix the named line.
- `FATAL: /config/allowed_senders ...` at startup → the file holds no address, so
  the relay would reject every sender.
- `554 5.5.0 Error: SMTP protocol synchronization` → the client sent before the
  relay's reply arrived: before the banner, or commands together before `EHLO`
  offered PIPELINING. This is Postfix's default protection
  (`smtpd_forbid_unauth_pipelining`). No real printer has been seen doing this
  yet. If one does, add `smtpd_forbid_unauth_pipelining = no` to
  `postfix/main.cf.tmpl`.
