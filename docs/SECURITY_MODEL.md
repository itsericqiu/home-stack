# Security

Last updated: 2026-09-10

This document summarizes security rules for operating and changing home-stack.
Contributor-specific workflow rules also live in `AGENTS.md`.

## Secrets

- Secrets live in `~/.config/home-stack/env.local`.
- `env.local` must not be committed, copied into docs, pasted into issue text, or printed in logs.
- Prefer `portable/home-stack/scripts/env-set.sh KEY [VALUE]` for edits; it creates a timestamped backup, does not print values, and does not source unrelated existing secret assignments while editing.
- The file should be mode `0600`.
- Repository scripts must not overwrite `env.local` wholesale.

Common secret-bearing variables:

- `HOME_STACK_CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_API_TOKEN`
- `HOME_STACK_ADMIN_PASSWORD`
- `HOME_STACK_OPENCODE_SERVER_PASSWORD`
- `HOME_STACK_HERMES_DASHBOARD_PASSWORD_HASH`
- `HOME_STACK_HERMES_DASHBOARD_SECRET`
- `HOME_STACK_POCKET_ID_ENCRYPTION_KEY`
- `HOME_STACK_TINYAUTH_SECRET`
- `HOME_STACK_TINYAUTH_USERS` (bcrypt hash, not a password)
- `HOME_STACK_TINYAUTH_TAILSCALE_APITOKEN`, `HOME_STACK_HERMES_OIDC_CLIENT_SECRET`

Identity keys (`HOME_STACK_PARENT_DOMAIN`, `HOME_STACK_TAILNET_IP`, `HOME_STACK_ACME_EMAIL`, `HOME_STACK_OWNER_HOME`, `HOME_STACK_IDENTIFIER_PREFIX`, `HOME_STACK_ADMIN_USERNAME`) MUST live in the profile's `home-stack.env`, never in `env.local`. The loader rejects identity keys appearing in the secrets file.

### Service-private secrets

A managed service whose wrapper sets `HOME_STACK_SKIP_ENV_LOCAL=1` — so the
process never loads the shared secret layer — may keep its own secrets in a
mode-0600 file under `~/.config/home-stack/<service>/`. Hermes (`~/.hermes`)
and a tenant app (`~/.config/home-stack/<tenant>/secrets.json`) follow this
pattern, and the planned `cloudflared` credentials will too. Rules:

- Never under `~/.config/home-stack/data/` — that tree is the backup folder.
- Never in `services.yaml`, a generated plist, `argv`, logs, or events.
- `hs doctor` checks the file mode; the wrapper test proves no `HOME_STACK_*`
  variable and no shared secret reaches the child process.

This is the default for tenant apps (external binaries): with no wrapper
sourcing `env.local`, the shared secrets cannot leak into them.

## Token Scope

- Cloudflare tokens should be scoped to the required zone and DNS permissions only.
- Do not use broad account-wide tokens unless there is a deliberate, documented reason.
- Rotate tokens if they are exposed or accidentally printed.

## Network Exposure

- Caddy is the only Tailnet-facing ingress for ordinary applications.
- Upstream services should bind to `127.0.0.1` unless an authenticated native-protocol exception is explicitly documented and reviewed.
- Caddy's native Admin API must remain private at `127.0.0.1:2019`.
- Do not add Caddy routes, tunnels, or proxies that expose `127.0.0.1:2019`.
- Unknown `*.<your-domain>` hosts should abort rather than fingerprint services.

Hermes is the only current exception. It binds the exact Tailnet IP—never
`0.0.0.0` or a LAN address—because its official auth gate and remote-client
WebSockets require a non-loopback listener. Its raw port is Tailnet-only, its
username/password provider must advertise `auth_required: true` and `basic`,
and it must never be routed through Cloudflare Tunnel or public port forwarding.

### External perimeter (Phase D, planned)

Nothing listens publicly by default. The planned remote lane
(`docs/REMOTE_ACCESS.md`) is the only public path and is governed by:

- **Per-service, registry-declared opt-in.** `remote: access` on a service
  with a routable hostname; denied by kind for control, agent, auth, backend,
  and ingress services. Remote Admin and remote Hermes are never permitted.
- **Authenticate before origin.** Cloudflare Access gates every remote
  hostname at the edge with a one-time PIN or a hosted passkey-capable IdP.
  Unauthenticated requests never reach the Mac.
- **Verify at origin.** The `access-verify` loopback service validates the
  `Cf-Access-Jwt-Assertion` signature, issuer, audience, and expiry on every
  request; a forged or missing token is a 401 at Caddy. A misconfigured or
  leaked tunnel cannot expose an app.
- **Outbound only.** `cloudflared` opens no inbound port; it reaches Caddy on
  a loopback HTTP listener reserved for the remote lane, which is `bind
  127.0.0.1` and unreachable from the tailnet or LAN.
- **Lane hygiene.** The remote block strips `X-Webauth-User` and
  `Remote-User` and forwards only the Access-verified email; upstreams cannot
  confuse the tailnet and remote lanes.
- **Secrets.** Tunnel credentials are service-private (above); the DNS-scoped
  Cloudflare token is used only by the operator-run `hs remote route` helper
  and is never passed to `cloudflared`.
The public `/api/status` and `/api/health` probes disclose bounded status only;
protected API requests must reject unauthenticated callers.

Hermes can read/write its own credential store and execute agent tools, so its
native auth supplements rather than replaces the Tailnet perimeter. The
tracked profile contains only the port, username, route, and literal Tailnet
upstream. The password hash, signing secret, and all model/API credentials stay
out of `services.yaml`, generated plists, logs, and git.

The launch wrapper may load the shared four-layer environment to resolve the
profile, but Hermes itself is executed under a clean allowlist. It receives
only normal user runtime values plus its dashboard/OIDC inputs. In particular,
Admin, Cloudflare, Pocket ID, tinyauth, OpenCode, and unrelated service secrets
must not survive into the agent process. Tests enforce both named sentinel
secrets and the absence of every `HOME_STACK_*` child variable.

The deployed operator configuration also hard-denies obvious direct reads of
the Home Stack, OpenCode, and Hermes credential files, Keychain password lookup
commands, and full `printenv` dumps. These supported glob rules are a useful
floor, not a filesystem sandbox: equivalent data can be reached through other
programs by an agent running as the logged-in user. Hermes' smart reviewer only
runs for commands recognized by its built-in dangerous-command detector, so
operator policy text must not be represented as universal enforcement.

Hermes profiles are state/configuration separation, not sufficient access
control for a remotely reachable machine dashboard: the dashboard can manage
and chat under selected profiles. The authenticated dashboard is therefore a
trusted-user operator surface. Use a separate process/home only when a concrete
workflow needs independent credentials or a smaller authority set; profiles
and custom brokers are not prerequisites for general CLI use. Gateway, cron,
webhook, and background execution require separate review before they receive
the dashboard operator's authority.

Hermes' messaging/cron gateway uses the official `ai.hermes.gateway`
LaunchAgent rather than a Home Stack wrapper. Its plist contains only
`HERMES_HOME`, `PATH`, and `VIRTUAL_ENV`; platform/provider secrets are loaded
from Hermes' mode-0600 store and never enter Home Stack configuration. With no
platforms configured it opens no network listener and accepts no remote
messages. Every added platform must identify the sole allowed sender/account;
pairing/default-deny is not a reason to set `GATEWAY_ALLOW_ALL_USERS=true`.
Webhook/API listeners and publisher-operated relays are separate ingress/data
boundaries requiring review. The gateway's secret redaction is defense in
depth, not permission to log credentials.

A deployment should store only the dashboard scrypt hash server-side. The
plaintext client credential belongs in an Apple Passwords/iCloud Keychain
website record for the HTTPS origin, not in service startup, logs, or a generic
local-login-keychain record assumed to sync. Direct OIDC is the normal
passkey-capable login; Basic remains a separately tested break-glass path.
The intended community iPhone client currently requires Basic rather than
OIDC. It stores the resulting session cookie in the device Keychain without an
explicit iCloud-synchronizable attribute and does not store the plaintext
password; the Apple Passwords website record is the cross-device credential.
Its optional publisher-operated push path remains disabled unless separately
reviewed. Record your own deployed credential arrangement and validation
status in your overlay's `hermes-deployed.md`.

## Identity Layer

Auth is opt-in per service through the registry's `auth:` field. The engine
emits one fixed Caddy block per value; the registry is never a directive
surface.

- **`auth:` only covers the Caddy path.** Loopback service-to-service calls
  bypass it entirely. That is why OpenCode needs no gate (it has no route) and
  why Hermes integrates OIDC directly (its CLI and native clients never traverse
  Caddy). Setting `auth:` on an unroutable service is rejected, not ignored.
- **`tailnet` authenticates the device, not a fresh human ceremony.** Anyone
  holding an unlocked, logged-in tailnet device is that user. This matches the
  perimeter's existing assumption, but it is weaker than a login prompt — prefer
  `sso` where you want a human in the loop. Tagged (machine) nodes are refused,
  since no person can be attributed.
- **Identity resolution is local.** `tailscale_auth` queries the tailscaled
  LocalAPI on this machine; no Tailscale API token is involved and nothing
  leaves the host. On macOS that API is TCP + a `sameuserproof` token file under
  `/Library/Tailscale`, not a unix socket. Never print that token.
- **Authorization for proxied apps belongs in tinyauth, not Pocket ID.** Every
  app behind the broker reaches Pocket ID as the same OAuth client, so the IdP
  cannot tell them apart. tinyauth keys its ACLs on the target hostname
  (`apps.<host>.users.allow/block`, `oauth.whitelist` for groups, plus IP and
  path rules) with a global allow/deny policy. Directly integrated apps are the
  exception: Hermes holds its own Pocket ID client, so per-client group
  restriction does apply there.
- **The brokers cannot gate themselves.** `pocket-id` and `tinyauth` are
  registered `auth: none` deliberately; gating the login path would deadlock it.
- **Admin trusts identity headers only with proof of the hop.** Admin listens on
  loopback, so `X-Webauth-User` / `Remote-User` are unauthenticated input on
  their own — any local process could set them. They are honoured only when
  accompanied by `X-Home-Stack-Proxy-Auth` matching
  `HOME_STACK_ADMIN_PROXY_SECRET`, which only the ingress injects. Absent or
  mismatched, Admin falls back to Basic Auth rather than trusting the headers.
- **Break-glass paths are deliberate.** Admin keeps Basic Auth, Hermes keeps its
  password provider, and tinyauth keeps a local account whose plaintext lives in
  the login Keychain (`<prefix>.home-stack.tinyauth.breakglass`) with only the
  bcrypt hash in `env.local`. Record your own Keychain item name in your
  overlay's `migration-private.md`. An identity-layer outage must never cost
  you the ability to repair it.
- **The Caddy binary is now load-bearing for auth as well as TLS.** It carries
  both the Cloudflare DNS and Tailscale plugins; a stock Caddy cannot serve this
  stack, and an upgrade that drops either plugin breaks ingress or auth. Rebuild
  with the recipe in `docs/RUNBOOK.md`.

## Admin Control Plane

- Admin is exposed through Caddy at `admin.home.example.com` and backed by `127.0.0.1:31510`.
- Admin authenticates a request one of two ways, in this order:
  1. **Ingress-verified identity** — `X-Webauth-User` (tailnet lane) or
     `Remote-User` (broker lane), accepted *only* alongside
     `X-Home-Stack-Proxy-Auth` matching `HOME_STACK_ADMIN_PROXY_SECRET`. The
     headers alone are unauthenticated input on a loopback listener; the secret
     is what proves the request came through the ingress. See "Identity Layer".
  2. **Basic Auth** via `HOME_STACK_ADMIN_PASSWORD` — retained as second factor
     and break-glass, and the only thing protecting the loopback port from
     local callers. Do not remove it: Admin is the tool used to repair a broken
     identity layer.
- Mutations are attributed to whichever identity authenticated, so zero-click
  actions are audited under the resolved user rather than an empty actor.
- Mutating Admin requests require the same-origin mutation header.
- Mutations must go through typed, allowlisted actions.
- Do not add arbitrary command execution to Admin.
- Do not accept command text from the browser for lifecycle, registry, Caddy, or launchd operations.
- Destructive or caution actions should require confirmation and be audited.

## Read-Only Portal Projection

- Caddy proxies only the exact catalog and status paths from the Portal origin
  to Admin. There is no general Portal-to-Admin proxy.
- The public handlers accept only the Portal Host and GET. Requests through the
  Admin host or raw loopback listener receive `404`.
- Catalog output contains only version, generation time, stable identity,
  display name, kind, public URL, scope, lifecycle, and launchability.
- Status output contains only version, generation time, aggregate state, and
  coarse process/network/route/HTTP states keyed by service ID.
- Never add upstreams, ports, filesystem paths, working directories, commands,
  PIDs, launchd labels, diagnostics, details, logs, action descriptors,
  credentials, or arbitrary registry fields to either projection.
- Portal remains static and carries no Admin password, session, or mutation
  capability. Presentation overrides may enrich a service but may not hide an
  unknown registry entry by acting as a second allowlist.

## Caddy, launchd, DNS, And Deployment Changes

Changes touching these areas require infra review before merge:

- Caddy generation logic, local-development templates, or generated Caddyfiles.
- launchd plist templates or generated plist behavior.
- sudoers or privileged execution.
- secrets or auth behavior.
- Cloudflare, DNS, TLS, or tunnel routing (including any `remote:` registry change).
- deployment/sync/apply workflows.

## OpenCode/OpenChamber Auth And Proxy Identity

- Launch OpenCode with `OPENCODE_SERVER_PASSWORD` when backend auth is enabled.
- Launch OpenChamber with the same value translated from `HOME_STACK_OPENCODE_SERVER_PASSWORD`.
- Preserve Caddy's default `X-Forwarded-Proto` and `X-Forwarded-Host` behavior so OpenChamber passkey origins and WebSocket checks use `https://opencode.home.example.com` rather than loopback.

## Audit And Traceability

- Keep `CHANGELOG.md` and `docs/DECISIONS_LOG.md` updated for significant changes.
- Keep `docs/STATUS.md` accurate when implementation state changes.
- Event logs should redact secrets and bound command output.
