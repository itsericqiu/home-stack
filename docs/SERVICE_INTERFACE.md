# Home Stack Service Interface (The Contract)

Last updated: 2026-09-10

To be managed by the Home Stack orchestrator, an application or project should adhere to this "Service Contract." This ensures consistent logging, health monitoring, and lifecycle management across your private cloud.

A **tenant app** is an application whose source lives in another repository
and which home-stack supervises and routes under this contract — Hermes, and
the first tenant app, whose own repository documents its home-stack
onboarding contract. Home-stack's side of a tenant is a registry entry,
optionally a thin wrapper that maps
`HOME_STACK_*` inputs onto the app's own environment namespace, and a wrapper
test. The tenant never reads `HOME_STACK_*` directly and never reads
`env.local`.

---

## 1. Network Connectivity
*   **Binding:** Apps MUST bind to `127.0.0.1` (localhost) only. External access is handled exclusively by Caddy unless the authenticated native-protocol exception below applies.
*   **Port Injection:** Apps SHOULD allow the listening port to be injected via an environment variable (e.g., `PORT` or `APP_PORT`). Home Stack will set this variable based on the `services.yaml` registry.

### Authenticated native-protocol exception

This exception is deliberately narrow. An app may bind only to the profile's
exact `HOME_STACK_TAILNET_IP` when all of these are true:

- compatible native clients require a non-loopback listener or raw protocol port;
- native authentication is fail-closed and verified before deployment;
- `0.0.0.0`, LAN interfaces, and public forwarding are not used, and the
  service never declares a remote route;
- Caddy remains the friendly HTTPS/browser route; and
- the exception and its verification are recorded in Architecture, Security,
  Verification, and the Decisions Log.

Hermes qualifies because its current auth gate is disabled on loopback and its
remote-client WebSocket checks require a non-loopback bind. No other service
inherits this exception automatically.

## 2. Process & Lifecycle
*   **Foreground Execution:** Apps MUST NOT "daemonize" or fork themselves into the background. They should run in the foreground so `launchd` can supervise them.
*   **Graceful Shutdown:** Apps MUST listen for `SIGTERM` signals and perform a graceful shutdown (closing DB connections, finishing active requests) within 30 seconds.
*   **Agent Environment:** A service capable of executing tools or inspecting its process environment MUST receive an explicit child-environment allowlist. Loading the shared Home Stack environment is permitted for wrapper-side resolution, but unrelated stack secrets MUST be removed before the agent process is executed.

### App-owned auxiliary worker exception

An application's official service generator may supervise an auxiliary worker
outside the registry when the worker has no Home Stack route/listener, shares
app-private state and upgrade semantics, and the upstream generator provides
material lifecycle behavior that a generic plist would duplicate. The label,
logs, environment keys, verification, and ownership decision must be recorded,
and Home Stack must not generate or load a second supervisor for the process.

Hermes' `ai.hermes.gateway` qualifies: it is a profile-aware messaging/cron
worker with upstream restart, drain, PATH refresh, resource-limit, and
code-update handling. The exposed Hermes dashboard remains a normal Home
Stack-managed service. Adding a webhook/API listener or public messaging
ingress is a new network/security review; this exception does not authorize it.

## 3. Logging (The Unified Stream)
*   **Standard Streams:** Apps SHOULD write all logs to `stdout` and `stderr`.
*   **Redirection:** Home Stack automatically redirects these streams to:
    `~/.config/home-stack/logs/<service_name>.launchd.out.log`
*   **Rotation:** By writing to standard streams, apps automatically inherit zero-config log rotation (size-based) from the global `logrotate` service.

## 4. Health & Observability
*   **Probes:** To enable the "High-Res" status bars in the Admin UI, apps SHOULD provide a lightweight HTTP health check endpoint (e.g., `GET /health`).
*   **Signal Requirements:**
    *   **[L]aunchd:** Verified by process presence.
    *   **[P]ort:** Verified by TCP connect.
    *   **[R]oute:** Verified by Caddy config presence.
    *   **[H]ealth:** Verified by the app's internal health check.

Portal consumes only a sanitized summary of those signals. Service-specific
health details, target addresses, process identifiers, and lifecycle actions
remain in authenticated Admin and must not be added to the public projection.
Every registry entry is projected even when Portal has no custom presentation
metadata; a service without a safe routed URL is non-launchable rather than
omitted.

## 4b. Authentication (`auth:`)

A routed service opts into ingress-level authentication with one registry field.
The engine emits a fixed block per value; the registry never carries Caddy
directives directly.

| `auth:` | Behavior | Choose when |
|---|---|---|
| omitted / `none` | No gate. Identical output to before this field existed. | The app authenticates itself, or the route is deliberately public (Portal projections). |
| `tailnet` | `tailscale_auth` resolves the peer's Tailscale identity and passes it upstream as `X-Webauth-User`, `-Email`, `-Name`. Zero interaction. | Browser-only internal tools where being on your tailnet on a user-owned device is sufficient. |
| `sso` | `forward_auth` to the `tinyauth` broker, which owns the login ceremony and session. | Real sessions, shared access, or reachability from off-tailnet. |
| `tailnet-or-sso` | `remote_ip` picks the lane: tailnet peers go the zero-click route, everything else falls back to the broker. | The seamless default for a route that must also work from elsewhere. |

Three things worth knowing before choosing:

- **`auth:` only protects the Caddy path.** Anything reaching the service over
  loopback — a sidecar, a CLI, another local service — bypasses it entirely.
  That is why OpenCode is safe without it (nothing routes to it) and why Hermes
  needs its own auth regardless (its CLI and native clients never touch Caddy).
  Setting `auth:` on a service with no `subdomain`/`host` is rejected rather
  than silently ignored.
- **Identity headers are only as trustworthy as the path they arrived on.** An
  app receiving `X-Webauth-User` (or `Remote-User`) cannot tell whether Caddy
  set it or a caller did: the header looks identical either way. What makes it
  safe is that these services bind `127.0.0.1`, so Caddy is the only thing that
  can reach them, and each gated lane strips the headers it does not itself set.
  If you expose an upstream any other way, or run something else on the host
  that can reach its port, that guarantee is gone and the header becomes
  attacker input. Admin is the exception: it additionally requires a shared
  secret (`HOME_STACK_ADMIN_PROXY_SECRET`) that only the ingress injects, and it
  is the only upstream that receives it — a service holding that secret could
  impersonate anyone to Admin's mutation API. Treat the headers as *convenience*
  identity, not as an authorization boundary, unless you verify the secret too.
- **`tailnet` trusts the device, not a fresh human ceremony.** Anyone holding an
  unlocked, logged-in tailnet device is that user. Tagged (machine) nodes are
  rejected outright, since there is no person to attribute the request to.
- **The broker cannot gate itself.** `tinyauth` and `pocket-id` are registered
  with `auth: none` deliberately: they *are* the login path, so gating them
  would deadlock the flow.

## 4c. Availability (`enabled:`)

A registry entry opts out of being active with one field, in the same
closed-enum, fixed-behavior idiom as `auth:`.

| `enabled:` | Behavior |
|---|---|
| omitted / `true` | Unchanged: the engine emits a Caddy route (if it has a `subdomain`/`host`) and a launchd plist (if it is not `type: system`/`static`), same as before this field existed. |
| `false` | The service stays registered, fully validated (nothing is skipped — a disabled service can be safely re-enabled), and inventoried. The engine emits **no** Caddy route and **no** launchd plist for it, in every generation path (`hs sync`, `hs deploy --preview`, `hs deploy --apply`). |

`Validate` rejects `enabled: false` outright in three cases, because each
would otherwise silently break the stack with nothing downstream that
notices:

- On a **`type: system`** service (the ingress) — `install-launchd.sh`
  hard-requires its daemon plist to exist.
- On **`admin`** — it owns the Portal projection and the control plane.
- On the **auth broker** (the service `auth: sso`/`auth: tailnet-or-sso`
  routes depend on) while any enabled service still returns
  `RequiresAuthBroker()` — the error names the dependents, so the fix is
  either re-enable the broker or disable the dependents first.

Any other service can be disabled freely.

Five things worth knowing:

- **The registry is still the truth for a disabled service, not a hole in it.**
  `catalog.json` keeps the entry, carrying `"enabled": false`, so tooling that
  reads the private catalog can tell "not deployed" apart from "does not
  exist." The Portal projection keeps listing it too — `lifecycle` and the
  schema version are unchanged, but `url` is `null` and `launchable` is
  `false`, since there is genuinely nothing to launch.
- **`catalog.json` also carries a `url` key, computed by the engine.** Every
  entry gets a `"url"` field from the new `Service.RoutableURL` (the
  resolved host with an `https://` prefix), but it is present only when the
  service is enabled, has a resolvable `subdomain`/`host`, and does not
  resolve to a wildcard — it is empty/absent for a disabled, unrouted, or
  wildcard service. This is the one place a shell script should ever read a
  service's own or a sibling's URL from; see §5's wrapper resolution order.
- **Admin never probes a disabled service — unless it is still loaded.**
  Launchd, port, route, and HTTP checks would only ever report failure for a
  reason that is not an incident — the service was never meant to run — so
  none of them execute. Admin shows it as `disabled`, a fifth, neutral
  overall state distinct from `down` or `unknown`, and normally raises no
  incident and offers no start/stop/restart actions for it.
- **A disabled-but-not-yet-pruned service is not invisible.** Flipping
  `enabled: false` doesn't retroactively stop a service already running under
  its old plist — that only happens once `install-launchd.sh` prunes it (see
  below). Until then, Admin still reports its launchd state, raises an info
  incident naming it ("registry says disabled, but still running"), and
  exposes exactly one action: `service.stop` (never start/restart) — so an
  operator can actually stop what the registry no longer wants running,
  instead of a state that looks identical to "cleanly disabled."
- **Disabling a service prunes its stale plist.** A service that is removed
  from the registry, or newly set to `enabled: false`, had its plist deleted
  from the bundle the moment it stops being desired — `hs sync` and
  `hs deploy --apply` both remove any `<identifier-prefix>.home-stack.*.plist`
  in the launchd agents directory that is no longer in the desired set (never
  touching the `daemons/` subdirectory or a file outside that prefix
  namespace). `install-launchd.sh`'s own prune step keys off what exists in
  that directory, so this is what lets it actually notice and uninstall a
  turned-off service. `hs sync`/`Apply`/`Diff` now share one
  `desiredArtifacts`/`writeArtifacts` pipeline, and `Apply` generates and
  prunes the daemon plist too (previously agent plists only).

## 5. Persistence & State
*   **Standard Data Dir:** Stateful apps SHOULD store their data (SQLite, JSON, etc.) in a directory provided by the `HOME_STACK_DATA_DIR` environment variable, unless preserving the application's established user state location is an explicit integration requirement.
*   **Location:** Home Stack standardizes this to `~/.config/home-stack/data/<service_name>/`.
*   **Backups:** Following this standard allows the entire stack's state to be backed up by zipping one folder.
*   **Engine-injected per-service environment:** `GenerateLaunchdPlist` injects four variables into every managed service's `EnvironmentVariables`, alongside the `HOME_STACK_PROFILE` pin — computed from that service's own registry entry, never overridable from it (`Validate` rejects `HOME_STACK_*` in a service's own `env:`):
    *   `HOME_STACK_SELF_NAME` — the service's registry name.
    *   `HOME_STACK_SELF_HOST` — the rendered FQDN (`subdomain`/`host` composed against `parent_domain`, the same computation the Caddyfile generator uses), or empty when the service has no `subdomain`/`host` or resolves to a wildcard (e.g. dev-gateway's `*.dev`).
    *   `HOME_STACK_SELF_URL` — `https://<HOME_STACK_SELF_HOST>`, or empty when that is empty. Same value as `catalog.json`'s `url` key for this service (§4c).
    *   `HOME_STACK_DATA_DIR` — `<config dir>/data/<service_name>/`, matching the Standard Data Dir above. Honors a `HOME_STACK_CONFIG_DIR` override the same way `GenerateSystemDaemonPlist` already did, rather than always assuming `~/.config/home-stack`.

    **Wrapper URL resolution order.** `hs restart` (`launchctl kickstart -k`)
    re-execs an already-loaded job under its *existing* environment — launchd
    only re-reads a plist on `bootstrap` — so a service started under an
    older plist (or before the next `install-launchd.sh --load`; see
    `docs/RUNBOOK.md` → "Upgrading services whose plists changed") would
    crash-loop under `KeepAlive` if a wrapper required
    `HOME_STACK_SELF_URL`/`HOME_STACK_DATA_DIR` with no fallback. Every
    managed wrapper (`run-pocket-id.sh`, `run-tinyauth.sh`, `run-hermes.sh`)
    therefore resolves its **own** URL and data dir in this order, and a
    wrapper resolving a *sibling* service's URL (Pocket ID's, for OIDC) uses
    the same first fallback:
    1. The injected `HOME_STACK_SELF_URL` (or `HOME_STACK_DATA_DIR`), if set.
    2. `home_stack_service_url <name>` in `lib/common.sh` — reads the `url`
       key straight out of `catalog.json` (still registry-authoritative,
       written by the engine's `RoutableURL`; **never** recomposed from a
       profile subdomain variable) for a sibling, or the service's own name
       as a stale-plist fallback. (For `HOME_STACK_DATA_DIR` the equivalent
       fallback is simply `$HOME_STACK_CONFIG_DIR/data/<name>`, the same path
       the engine computes.)
    3. Fail closed with exit 78, naming both sources that came up empty.

    **The engine does not create `HOME_STACK_DATA_DIR`** — the app or its
    wrapper creates it if missing, the same as any other data directory under
    this contract.
*   **Service-private secrets:** a service that skips `env.local` keeps its own 0600 secret file under `~/.config/home-stack/<service_name>/`, never under `data/`. See `docs/SECURITY_MODEL.md` → Service-private secrets.

---

Hermes intentionally retains its official `~/.hermes` state so CLI, dashboard,
Desktop, and compatible mobile clients see the same sessions.

## Example `services.yaml` for an authenticated native-protocol app:

```yaml
services:
  hermes:
    display_name: "Hermes Agent"
    kind: "agent"
    lifecycle: managed
    type: "proxy"
    # Pure-data registries do not interpolate HOME_STACK_TAILNET_IP; a live
    # profile must use its literal Tailnet IP here.
    upstream: "100.64.0.8:31511"
    proxy_identity: upstream
    subdomain: hermes
    health:
      port: 31511
      http_url: "https://hermes.home.example.com/api/status"
```

`proxy_identity: upstream` is a fixed engine behavior for upstreams with
Host/Origin rebinding guards. It does not permit arbitrary Caddy directives or
headers in the registry.

## Planned fields

Closed-enum fields following the `auth:` / `proxy_identity:` idiom; not yet
implemented (see `docs/ROADMAP.md`):

| Field | Values | Effect |
|---|---|---|
| `remote:` | omitted / `none` / `access` | `access`: also serve `<name>.remote.<parent>` behind Cloudflare Access, verified at origin. Denied by kind for control/agent/auth/backend/ingress. Requires `remote_aud:`. (P3, `docs/REMOTE_ACCESS.md`) |
| `remote_aud:` | Access application AUD tag | Non-secret; required with `remote: access`. (P3) |
| `install:` | `method`, `source`, `pin`, `version_cmd` | Drives `hs upgrade status`. (P5) |
