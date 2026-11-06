# Postfix → Microsoft 365 relay for printers

A dockerized Postfix MTA that lets printers/scanners with **no modern auth
support** send mail through Microsoft 365. Printers connect either

- **without authentication**, if their fixed IP is whitelisted, or
- **with a per-printer username/password** (SASL PLAIN/LOGIN on port 587 or 25).

**Sender lockdown:** only envelope senders listed in `config/allowed_senders`
are accepted — for every client, whitelisted or authenticated. Anything else is
rejected with `550`. So printers can *choose* a sender, but only from the
predefined list.

**Per-client mailboxes (optional):** a printer listed in
`config/client_senders`, by source IP or SASL account, always sends as its own
mailbox, whatever it has configured. See [step 3a](#3a-optional-give-a-printer-its-own-mailbox).

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
cp config/printer_accounts.example config/printer_accounts   # optional
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
- Each mailbox must be in `allowed_senders`, each account in `printer_accounts`,
  and an IP must be a valid address or CIDR. Otherwise the relay refuses to
  start, because a skipped line would let that client choose its own sender.
- The file grants no relay access: a listed IP still has to be in
  `PRINTER_NETWORKS` or authenticate.
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
| No auth (IP in `PRINTER_NETWORKS`) | SMTP server = relay IP, port 25, no auth, no TLS needed |
| Username/password | Port 587 (or 25), STARTTLS if supported, PLAIN/LOGIN with an account from `config/printer_accounts` |

The From/sender address on the printer must be one of `config/allowed_senders`,
unless the printer has a mapped mailbox (step 3a).

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
| `.env` | Tenant/app credentials, hostname, printer IPs, `COMPOSE_FILE` |
| `update.sh` | Pulls, rebuilds and restarts a deployed relay |
| `docker-compose.graph.yml` / `docker-compose.smtp.yml` | Same relay, outbound mode baked in via `OUTBOUND_MODE` |
| `config/allowed_senders` | Sender whitelist (one address per line) — **required** |
| `config/printer_accounts` | Optional `user password` lines for SASL accounts |
| `config/client_senders` | Optional `client mailbox` lines giving a printer its own sender (step 3a) |
| `config/tls/cert.pem` + `key.pem` | Optional real TLS cert (self-signed otherwise) |
| `postfix/main.cf.tmpl`, `postfix/master.cf` | The Postfix policy — rendered/copied at startup, linted with `postfix check` |
| `scripts/outbound-graph.sh` / `scripts/outbound-smtp.sh` | Outbound-mode adapters: each owns its mode's Postfix config, aux services, OAuth scope, and token store |
| `scripts/graph-send.sh` | graph mode pipe transport: posts one queued message to Graph `sendMail` |
| `scripts/graph-size-test.sh` | graph mode: sends real test mails to find which scan sizes Microsoft accepts |
| `scripts/sender-rewrite.sh` | Pipe transport for mapped clients: overwrites the sender, then re-injects the message |
| `scripts/fetch-token.sh` | One-shot Entra ID token fetch; hands the token to the mode adapter (used at startup and by the refresher loop) |

Config changes are applied by `docker compose -f <file> restart` (everything
is rendered at container start).

## Delivery semantics (graph mode)

- Graph delivers to the recipients in the **MIME headers**; envelope
  recipients missing from To/Cc (e.g. a printer's BCC) are added as a `Bcc`
  header, which Exchange honors and strips.
- Graph errors map to queue behavior: `429`/`5xx` and network failures are
  **deferred and retried**, other `4xx` (e.g. access denied by the scope above)
  **fail the message**. See [Failure notices](#failure-notices).
- Sent mail lands in the sending mailbox's **Sent Items** (Graph default).

### Large scans

The relay accepts messages up to 50 MB, but Graph may refuse far less. Microsoft
documents a 4 MB limit on Graph write requests; whether and how it applies to
`sendMail` is **not yet tested against a real tenant**. Encoding matters here: a
scan is base64-encoded in the MIME message, and the whole message is encoded
again for Graph, so the request is about 1.8x the scan. If 4 MB applies, the
largest scan is about 2.2 MB, not 3 MB.

A rejected message fails instead of retrying, and is logged with its size. A
`413` is logged as `graph-send: MESSAGE TOO LARGE`, with the message and request
sizes. Any other rejection also includes the sizes.

To find the real limit, send test mails (real ones, to a mailbox you can check):

```bash
docker compose -f docker-compose.graph.yml exec postfix \
    graph-size-test.sh printers@example.com you@example.com 3 5 10   # attachment MB
```

## Failure notices

Postfix would normally mail a failure notice to the sender of a failed message.
**That does not work in graph mode**: a notice has no sender mailbox, so Graph
cannot send it, and nobody is told. The relay therefore doesn't try, and logs the
loss instead. Failures are only visible in the log, so watch it:

```bash
docker compose -f docker-compose.graph.yml logs postfix | grep -E 'status=bounced|FAILURE NOTICE'
```

Each lost notice is logged as `graph-send: FAILURE NOTICE NOT SENT`, with the
original message's queue ID and the failed recipients. The printer itself never
learns of the failure once the relay has accepted the message.

smtp mode has no such handling. Notices go to Microsoft with an empty sender
through the relay mailbox, and whether Microsoft accepts them is **not yet tested**.

## Security notes

- The relay accepts mail **only** from `PRINTER_NETWORKS` IPs or authenticated
  clients, and **only** with whitelisted senders — it is not an open relay,
  but still: run it on an internal network, don't expose port 25 to the internet.
- Auth on port 25/587 permits plaintext passwords because most printers can't
  do STARTTLS; treat printer passwords accordingly (LAN-only).
- graph mode: the app can send as anyone in the tenant if it has an Entra
  `Mail.Send` consent or an unscoped role assignment. Follow step 2a and check
  it with `Test-ServicePrincipalAuthorization`.
- The relay checks only the **envelope** sender, so a printer without a mapped
  mailbox can put any address in the **From header**. How Microsoft treats a From
  that differs from the sending mailbox is **not yet tested**. Clients with a
  mapped mailbox (step 3a) are not affected, because their From is overwritten.
- smtp mode: Microsoft is retiring Basic Auth for SMTP submission through
  2026; XOAUTH2 as used here is the supported replacement path.

## Testing

- `./test/graph-send.test.sh` — unit tests for the Graph delivery script
  against a local mock endpoint (needs bash, curl, python3).
- `./test/sender-rewrite.test.sh` — unit tests for the sender rewrite, with a
  stub `sendmail`.
- `./test/smtp-dialogue.sh` — response-driven SMTP driver used by the smoke
  test (each command is sent when the previous reply completes; no sleeps).
- `./test/smoke.sh` — boots an isolated stack per outbound mode (mock
  Entra/Graph endpoints, fixture config) and replays SMTP dialogues against
  ports 25/587: sender whitelist enforcement (also for authenticated
  clients), relay denial for untrusted IPs, and printer SASL login, in both
  modes. In graph mode an accepted message is additionally followed
  end-to-end to the mock Graph `sendMail` endpoint; the real
  `smtp.office365.com` leg of smtp mode needs real credentials and is not
  covered. Separate stacks cover per-client mailboxes: followed to the mock Graph
  in graph mode, and to the queue, with delivery held, in smtp mode.

All of this runs against mocks. It proves what the relay sends, not what
Microsoft does with it.

### Continuous checks

- **`.github/workflows/ci.yml`** — runs shellcheck and both test scripts on
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
- `graph-send: HTTP 403 ErrorAccessDenied` → sender mailbox not in the scope
  or no `Application Mail.Send` role assignment (step 2a). Check with
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

- `550 ... Access denied` at MAIL FROM on the relay → sender not in
  `config/allowed_senders`.
- `FATAL: /config/client_senders: ...` at startup → fix the named line (step 3a).
- `554 5.5.0 Error: SMTP protocol synchronization` → the client sent before the
  relay's reply arrived: before the banner, or commands together before `EHLO`
  offered PIPELINING. This is Postfix's default protection
  (`smtpd_forbid_unauth_pipelining`). No real printer has been seen doing this
  yet. If one does, add `smtpd_forbid_unauth_pipelining = no` to
  `postfix/main.cf.tmpl`.
