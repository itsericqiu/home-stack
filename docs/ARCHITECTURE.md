# Architecture Notes

Last updated: 2026-09-10

This document describes the current system model and durable architectural
boundaries. Current implementation status lives in `docs/STATUS.md`; future work
lives in `docs/ROADMAP.md`.

## System Shape

Home Stack is a macOS-first private infrastructure/control repo. It owns:

- Caddy ingress and TLS termination.
- launchd service definitions and lifecycle management.
- Service registry/profile configuration.
- Generated catalog/status primitives.
- Admin/control-plane primitives.

It does not own every app's source code, app data, Dockerfiles, migrations, or
project-specific lifecycle beyond declared integration points.

## Network And Ingress

- Caddy is the only Tailnet-facing ingress for ordinary HTTP applications.
- Upstream services bind to `127.0.0.1` unless they satisfy the narrowly
  reviewed authenticated native-protocol exception below.
- Browser traffic goes through Caddy under `*.<your-domain>`.
- TLS is issued via DNS-01 using a custom `caddy-cloudflare` binary built with the Cloudflare DNS plugin.
- Unknown wildcard subdomains should abort rather than expose service fingerprints.

Current core ports:

- OpenCode backend: `127.0.0.1:31496`
- OpenChamber UI: `127.0.0.1:31497`
- Admin backend: `127.0.0.1:31510`
- Hermes dashboard: `<HOME_STACK_TAILNET_IP>:31511` (authenticated exception)
- Caddy Admin API: `127.0.0.1:2019` only

### Authenticated native-protocol exception

A service may bind the profile's exact `HOME_STACK_TAILNET_IP` only when its
compatible native clients require a non-loopback listener, the application
provides a fail-closed native authentication gate, the raw port is useful to
those clients, and the exception is recorded in `docs/DECISIONS_LOG.md`.
`0.0.0.0`, LAN-interface binds, and public port forwarding remain prohibited,
and a service holding this exception never receives a remote route (see Remote
Access Model). Caddy should still provide the friendly HTTPS route.

Hermes is the first and currently only exception. Current Hermes engages its
auth gate only on a non-loopback bind and rejects remote-client WebSockets on a
loopback listener. It binds only the Tailnet IP, advertises the `basic` provider,
and exposes its raw authenticated port for official-compatible clients.

OpenChamber serves the `opencode.<parent_domain>` hostname by design:
OpenChamber *is* OpenCode's web interface, so it owns the user-facing name
while the `opencode` service stays a headless backend with no subdomain of
its own. The service names and the hostname deliberately do not line up.

## Generation Boundaries

Two generators exist, and the split is intentional:

- **The Go engine** owns everything derived from the service registry —
  the Caddyfile, agent plists, the Caddy LaunchDaemon plist, and
  `catalog.json`. Anything that varies per service belongs here, and it is
  golden-tested per fixture profile.
- **`render-caddyfile.sh`** owns only the local-development Caddyfiles
  (`LOCAL_HTTP=1` / `LOCAL_TLS=1`) rendered from `templates/`. These exist to
  bring up TLS-less or self-signed local variants *before* or *outside* a
  working registry, so they cannot depend on the engine.

If a new artifact varies with the registry, it belongs in the engine.

## Portal And Admin Boundary

- Portal is for discovery/navigation and lives in a separate app repo ([home-portal](https://github.com/itsericqiu/home-portal)); this repo ships only a static fallback page.
- The registry entry that serves the Portal origin **must be named `portal`**: the engine attaches the two `/.well-known/home-stack/` projection routes to that service name and no other.
- `portable/home-stack/portal-www` is a minimal fallback landing page.
- Admin is a privileged Tailnet control plane at `admin.home.example.com`.
- Admin and Portal must remain separate because Admin has mutation privileges and a stronger security boundary.
- Portal awareness comes from two versioned, sanitized projections owned by
  Home Stack: `/.well-known/home-stack/catalog.json` and
  `/.well-known/home-stack/status.json`. Caddy proxies only those exact paths
  from the Portal origin to Admin; the remainder of the origin stays static.
- The catalog projection is derived from the sync-generated registry snapshot.
  The status projection is computed from Admin's live multi-signal checks.
  Neither is the raw catalog or privileged Admin API: infrastructure paths,
  upstreams, process identifiers, diagnostics, details, actions, and secrets
  are excluded by construction.
- The handlers reject non-Portal Host values. Every other Admin route remains
  behind Basic Auth and the existing mutation boundary.
- Canonical schema-v1 definitions live under `schemas/portal/`. Home Stack tests
  compile those schemas and validate the emitted Go documents. The Portal repo
  mirrors and independently validates the same definitions at its trust
  boundary; coordinated changes compare the two copies before deployment.

## Admin Control Plane

Admin is a Go service bound to `127.0.0.1:31510` and exposed only through Caddy.

Current model:

- Basic Auth with `HOME_STACK_ADMIN_PASSWORD`.
- Same-origin mutation header for mutating requests.
- Typed `POST /api/actions` mutation endpoint.
- Server-side action/target allowlists.
- Redacted event logging.
- Multi-signal service inventory from registry, launchd, port checks, Caddy route checks, and HTTP checks.

Hard boundaries:

- Do not proxy Caddy's native Admin API to browsers or remote users.
- Do not expose arbitrary command execution from the browser.
- Do not add direct browser mutation routes for registry/sync/app lifecycle without the typed action safety model.

Resolved in Phase 1:

- `hs sync` now invokes the admin binary's `sync` subcommand locally; the broken `/api/sync` HTTP wiring is gone.
- `hs app add` was removed from the user-facing CLI; Phase F then shipped as `hs service add/remove` and `hs deploy`, backed by the same typed `/api/actions`. The `hs app` migration-message stub was removed in P2: an unrecognized first-level `hs` command now prints usage and exits 2 rather than falling through to `service-launchd.sh`.

## Configuration Layers

Configuration is separated to keep the stack portable and secrets out of git.

1. **Code defaults:** built into `portable/home-stack/scripts/lib/common.sh`. Only safe non-identity values (port numbers, runtime dir defaults). Never domain, owner, prefix, IP, or email.
2. **Profile (mandatory):** tracked non-secret identity under `profiles/<profile>/home-stack.env`. Must define HOME_STACK_PARENT_DOMAIN, HOME_STACK_TAILNET_IP, HOME_STACK_ACME_EMAIL, HOME_STACK_OWNER_HOME, HOME_STACK_IDENTIFIER_PREFIX, HOME_STACK_ADMIN_USERNAME. Loader fails fast on missing keys. Every profile but `profiles/default/` is gitignored (`docs/PUBLIC_RELEASE.md` §4); the documented way to keep a real profile durable is a symlink from `profiles/<name>` to it living elsewhere (e.g. a private dotfiles overlay), and both the shell and Go resolvers follow that symlink — `HOME_STACK_PROFILES_DIR` exists only to point tests/CI at a fixture tree and is never pinned into a generated plist.
3. **Machine-local non-secret override:** optional untracked `~/.config/home-stack/config.env` for per-host tweaks.
4. **Secrets:** untracked `~/.config/home-stack/env.local`. Identity keys are forbidden here and the loader rejects them.

A fifth, per-service layer sits on top of these: the engine injects
`HOME_STACK_SELF_NAME`, `HOME_STACK_SELF_HOST`, `HOME_STACK_SELF_URL`, and
`HOME_STACK_DATA_DIR` into each managed service's generated plist, computed
from that service's own registry entry rather than from a profile variable —
see `docs/SERVICE_INTERFACE.md` §5.

Hermes' port and dashboard username are tracked non-secrets. Its scrypt
password hash and stable session-signing secret remain in `env.local` under
home-stack names and are translated by `run-hermes.sh`; no model/API
credentials enter the registry or generated plist. Unlike ordinary wrappers,
`run-hermes.sh` does not pass the loaded stack environment through to its
child. It constructs a clean allowlist containing normal user runtime values
and only the Hermes dashboard/OIDC inputs. This prevents an agent tool from
turning unrelated Home Stack credentials into ambient authority.

Profile examples:

- `profiles/default/home-stack.env`
- `profiles/default/services.yaml`

Scripts should source `lib/common.sh` and call `home_stack_load_env` so wrappers,
helpers, and services share the same environment model.

### Hermes authority model

The remotely reachable Hermes dashboard is a host-level management surface,
not an authorization boundary between ordinary Hermes profiles. Current Hermes
can switch the machine dashboard among profiles and can spawn a chat under the
selected profile. A profile therefore separates configuration and state, but
does not by itself prove that a remote dashboard user cannot select a more
privileged profile.

Different authority levels may use isolated Hermes homes/processes when a real
workflow needs them. The Tailnet dashboard is the personal/remote-operator
surface, and concurrent coding writers use separate worktrees.

Home Stack owns the exposed dashboard's exact bind, Caddy route, generated
LaunchAgent, health, and reviewed recovery entrypoints. Hermes owns models,
memories, skills, MCP definitions, provider credentials, messaging behavior,
cron state, and the official `ai.hermes.gateway` LaunchAgent for its internal
messaging/cron worker. That upstream service is intentionally outside
`services.yaml`: it opens no Home Stack route, is profile-aware, refreshes its
own PATH/runtime definition across Hermes updates, and publishes gateway state
through the dashboard. Generating a second Home Stack plist would create two
supervisors for the same Hermes state. The staged operating contract is in
`docs/HERMES_OPERATING_MODEL.md`.

## Caddyfile And Registry Generation

The Caddyfile is generated exclusively from the registry by the Go engine:

- **Registry path:** `hs sync` invokes the admin engine locally, which generates `Caddyfile`, launchd plists, and `catalog.json` from `profiles/<profile>/services.yaml`. This is the only production Caddyfile path.
- **Template path (deprecated):** `render-caddyfile.sh` and `templates/Caddyfile.template` have been removed from the production flow. The render script remains for local development modes (`LOCAL_HTTP=1`, `LOCAL_TLS=1`) only.
- `reload-caddy.sh` validates and reloads the engine-generated Caddyfile without re-rendering.
- Admin web actions (`caddy.validate`, `caddy.reload`) use the typed action model and regenerate from the registry before validating.

The template path was removed because it generated a hardcoded Caddyfile that did not reflect the registry. The engine path produces a Caddyfile that is always consistent with the active profile's `services.yaml`.

## Service Extension Model

Home-stack can route services whose source/assets live outside this repository.

Service shapes:

- **static:** Caddy serves files directly with `root` and `file_server`.
- **proxy:** Caddy proxies one localhost upstream.
- **split:** implemented shape where Caddy serves frontend assets and proxies one or more comma-separated API/backend prefixes.

Host models:

- **subdomain:** `<name>.${HOME_STACK_PARENT_DOMAIN}` (specified via `subdomain:` key in registry), best for auth, cookies, redirects, WebSockets, HMR, and long-lived services.
- **portal path:** `portal.${HOME_STACK_PARENT_DOMAIN}/apps/<name>/`, best for simple apps that tolerate a base path.
- **dev gateway:** `dev.${HOME_STACK_PARENT_DOMAIN}` catalog plus a dynamic host-based proxy behind registry `subdomain: "*.dev"`; code exists, production enablement remains planned.

Managed apps should follow `docs/SERVICE_INTERFACE.md`.

Proxy services may set `proxy_identity: upstream`. This is intentionally not
an arbitrary header-template surface: the engine emits only fixed `Host` and
`Origin` rewrites to Caddy's selected `{upstream_hostport}` while retaining
Caddy's default `X-Forwarded-Host`, `X-Forwarded-Proto`, and client forwarding.
Hermes needs this because its HTTP and WebSocket DNS-rebinding guard compares
those headers with its Tailnet-IP bind.

## Identity And Auth Tiers

Seamlessness and centralization are different axes, so the stack runs both
rather than compromising on one:

- **Tier 0 — perimeter.** Tailscale plus a Caddy bind on the Tailnet IP. Not
  authentication, but the reason everything above it can stay light: the TCP
  peer address at Caddy is a real tailnet address rather than a proxy hop.
- **Tier 1 — zero-click identity.** `tailscale_auth` (caddy-tailscale plugin,
  compiled into the same xcaddy binary as the Cloudflare DNS provider) resolves
  the peer via the local tailscaled WhoIs API and forwards `X-Webauth-*`
  upstream. No extra process, no login screen. It does not require Caddy to be a
  tsnet node.
- **Tier 2 — sessions and passkeys.** tinyauth brokers login and federates its
  backends (Tailscale identity, OIDC via Pocket ID, LDAP later); Pocket ID is
  the passkey-only OIDC provider behind it. This serves the tailnet's need for
  a real session and a human ceremony; it is not an off-tailnet path, because
  nothing off the tailnet can reach Caddy. Off-tailnet access is a separate
  lane with its own gate (Remote Access Model).
- **Tier 3 — app-native.** Apps with non-browser clients own their auth, because
  an ingress gate cannot cover a CLI. Hermes integrates OIDC directly;
  OpenChamber keeps its own passkeys; OpenCode keeps loopback plus a shared
  secret and has no route at all.

`auth: tailnet-or-sso` chains Tiers 1 and 2 on one route: a `remote_ip` matcher
on Tailscale's CGNAT range selects the lane, and `tailscale_auth` still performs
authorization inside it — the IP match is routing, not trust. Because Caddy
copies a non-2xx forward-auth response back to the client, the broker itself
decides between "proceed" and "go log in".

## Health Model

Admin/status should combine multiple signals:

- **launchd:** whether a managed process is loaded/running, PID, last exit.
- **port:** whether the expected local listener exists.
- **route:** whether Caddy has the expected host/path in loaded config.
- **HTTP:** whether user-facing or app-native endpoints return expected status.

Caddy route presence is not an upstream health check. App-defined health checks in
`services.yaml` should override hardcoded probes as the registry matures.

## Registry Schema Direction

The registry should describe service metadata, routing, health, and eventually
lifecycle commands. Commands must be fixed declarations with explicit execution
context; Admin must never accept arbitrary command text from the browser.

Minimal direction:

```yaml
services:
  portal:
    display_name: Portal
    kind: static
    type: static
    subdomain: portal
    root: ~/github/home-portal/dist
    health:
      http_url: https://portal.home.example.com/

  openchamber:
    display_name: OpenChamber
    kind: proxy
    type: proxy
    subdomain: opencode
    upstream: 127.0.0.1:31497
    health:
      port: 31497
      http_url: https://opencode.home.example.com/
```

For app/container lifecycle schema plans, see `docs/ROADMAP.md`.

## Registry Composition

Services use `subdomain:` (composed against the active profile's parent_domain) or absolute `host:` (rejected if it overlaps the parent domain). Engine renders the FQDN at sync time. No shell-style `${VAR}` interpolation in services.yaml.

## Remote Access Model

Remote/off-Tailnet access is planned as a dual-perimeter extension, specified
in `docs/REMOTE_ACCESS.md`:

- Internal perimeter: Tailscale for `*.<parent domain>`; unchanged.
- External perimeter: Cloudflare Tunnel and Cloudflare Access for services that
  declare `remote: access` in the registry, served as `<name>.remote.<parent
  domain>`. Access authenticates at the edge before any packet reaches the Mac;
  a loopback `access-verify` service re-validates the Access JWT at origin so a
  misconfigured tunnel cannot expose an app.
- The tunnel reaches Caddy on a loopback HTTP listener reserved for the remote
  lane; the lane strips tailnet identity headers and forwards only the
  Access-verified email.
- `remote:` is denied by kind for control, agent, auth, backend, and ingress
  services: Admin, Hermes, Pocket ID, tinyauth, OpenCode, Caddy, and the dev
  gateway never get a remote route. No wildcard remote exposure.

Cloudflare Access identity is documented; the tunnel, the registry fields, and
the two supporting services are not implemented yet (P3 in `docs/ROADMAP.md`).

## Upgrade Model

- OpenCode/OpenChamber upgrades must update the binary launchd actually resolves.
- Caddy upgrades must preserve the Cloudflare DNS plugin by rebuilding the custom `caddy-cloudflare` binary.
- Config-only changes use Caddy reload.
- Binary upgrades require launchd restart because reload does not replace the running process image.
- Future upgrade tooling should track install method, binary path, and current version per managed component, via a registry `install:` block (`docs/PLAN.md` §3.6).
