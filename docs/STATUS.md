# Home Stack Status

Last audited: 2026-09-10

This document is the current implementation ledger for home-stack. It supersedes
checkbox state in older planning files. Historical plans are preserved for
context, but this file should be updated whenever implementation reality shifts.

## Source-of-Truth Order

1. `AGENTS.md` — contributor and safety rules.
2. `docs/STATUS.md` — current implementation state.
3. `docs/ROADMAP.md` — current planned work.
4. `docs/ARCHITECTURE.md` and `docs/RUNBOOK.md` — architecture and operations.
5. Archived session handoffs, planning artifacts, and the original roadmap
   live in the archived private repository (`docs/INDEX.md` → Historical
   context), not in this tree.

## Implemented

- **Phase C Tailnet TLS/launchd baseline**
  - Wildcard Tailnet DNS/TLS via Caddy DNS-01 is the deployed model.
  - Core production services are launchd-managed rather than Makefile harnesses.

- **Admin control plane v1**
  - Admin is a Go service on `127.0.0.1:31510`, exposed through Caddy at `admin.<parent-domain>`.
  - Caddy Admin API remains private at `127.0.0.1:2019`.
  - Admin uses Basic Auth plus a same-origin mutation header for mutating requests.
  - Implemented API surface includes:
    - `GET /api/health`
    - `GET /api/status`
    - `GET /api/services`
    - `GET /api/overview`
    - `GET /api/incidents`
    - `GET /api/events`
    - `GET /api/doctor`
    - `GET /api/deploy/preview`
    - `POST /api/actions`
  - Mutations are centralized through typed `/api/actions`.
  - Events are recorded with redaction and bounded output.
  - Optional/dev/testing services can surface informational incidents without degrading stack triage.

- **Registry and profile foundation**
  - `profiles/default/` is the tracked starter template; any real profile is
    gitignored by design (`docs/PUBLIC_RELEASE.md` §4) and lives in the
    operator's own dotfiles overlay. `default` is never auto-loaded.
  - Admin service inventory is registry-driven rather than fully hardcoded.
  - Registry validation in `portable/home-stack/admin/engine.go` enforces the new `subdomain`/`host` composition model and rejects hosts that overlap the active profile's parent domain.

- **Registry `enabled:` field**
  - Optional `enabled: true|false` (default `true`) on a registry `Service` entry, implemented as `Enabled *bool` with an `IsEnabled()` accessor (nil means enabled). `Validate` rejects `enabled: false` outright on a `type: system` service (the ingress; `install-launchd.sh` hard-requires its daemon plist), on `admin` (it owns the Portal projection and the control plane), and on the auth broker while any enabled service still returns `RequiresAuthBroker()` (the error names the dependents) — each would otherwise silently break the stack with nothing downstream that notices. Any other disabled service is still fully validated and can be safely re-enabled.
  - `false` emits no Caddy route and no launchd plist, in every generation path: `GenerateCaddyfile` and the unified `desiredArtifacts`/`writeArtifacts` pipeline `syncSystem`, `registry.go`'s `Diff`, and `registry.go`'s `Apply` now all share. A single `Service.generatesAgentPlist()` helper (enabled and type not `system`/`static`) replaced three copies of the same inline skip check.
  - `catalog.json` still lists a disabled service, carrying `"enabled": false`; an enabled one omits the key so existing output stays byte-identical. It also carries a per-service `"url"` field computed from the new `Service.RoutableURL` (resolved host with an `https://` prefix), present only for a service that is enabled, has a resolvable subdomain/host, and does not resolve to a wildcard — empty/absent for disabled, unrouted, or wildcard services. `lib/common.sh`'s `home_stack_service_url` reads this key directly instead of recomposing Subdomain/Host/wildcard itself. The Portal catalog projection still lists a disabled service too, with `url: null` and `launchable: false` — the `lifecycle` enum and schema version are unchanged.
  - Admin inventories a disabled service without running any launchd/port/route/http checks against it; `OverallState` is the new `"disabled"` value (a fifth, neutral signal state, its own bucket in `countServiceStates`), it raises no incidents, and `serviceOperations`/`actionsForService` expose no actions for it — **unless** it is disabled but not yet pruned by `install-launchd.sh` (still loaded in launchd). In that case `collectServices` still reports its launchd state, `deriveIncidents` raises an info incident naming it, and `serviceOperations`/`actionsForService` expose exactly `service.stop` (never start/restart) so an operator can actually stop what the registry no longer wants running. `app.js`'s `sig()` takes an explicit `disabled` flag so this doesn't regress a merely-not-yet-installed *enabled* service back to looking neutral.
  - `syncSystem`, `registry.go`'s `Apply`, and `registry.go`'s `Diff` now all build on one `desiredArtifacts`/`writeArtifacts` pipeline instead of three hand-rolled copies. `Apply` now also generates and prunes the daemon plist (previously agent-plists-only), and `Diff` now includes the daemon plist in its comparison too. Pruning deletes stale `<identifier-prefix>.home-stack.*.plist` files from the launchd agents directory (never `daemons/`, never a file outside the prefix namespace) for a service removed from the registry or newly disabled, via one idPrefix-scoped `agentPlistFilename`/`plistServiceName` helper shared by `diffPlists` and `pruneStalePlists` so a leftover plist from a different identifier prefix can no longer collide with a same-named service. `Diff()` validates `HOME_STACK_IDENTIFIER_PREFIX` the same way `Apply`/`syncSystem` do, instead of reading it unchecked inside its loop.
  - `diffPlists` is content-aware: a same-named plist whose bytes changed from what is on disk now reports `Changed` ("Would update plist for `<name>`"), where it previously compared names only and reported no diff — `hs deploy --preview` is no longer blind to content-only changes.
  - `aggregatePortalState` no longer lets a disabled service (whose own state has nothing better than the schema's "unknown" fallback) drag the Portal-wide `overall_state` to "degraded"; its own per-service entry still projects "unknown".

- **Tenant-ready registry (P2)**
  - `GenerateLaunchdPlist` injects `HOME_STACK_SELF_NAME`, `HOME_STACK_SELF_HOST` (rendered FQDN, or empty when the service has no subdomain/host or resolves to a wildcard), `HOME_STACK_SELF_URL` (`https://<host>` or empty), and `HOME_STACK_DATA_DIR` (`<configDir>/data/<name>`) into every managed service's plist, alongside the existing `HOME_STACK_PROFILE` pin. `HOME_STACK_DATA_DIR` honors a `HOME_STACK_CONFIG_DIR` override the same way `GenerateSystemDaemonPlist` already did, instead of always assuming `<ownerHome>/.config/home-stack`. `Validate` already rejects `HOME_STACK_*` in a service's own `env:`, so none of these four are overridable from the registry.
  - Each of `run-pocket-id.sh`, `run-tinyauth.sh`, and `run-hermes.sh` resolves its **own** URL (`APP_URL`/`TINYAUTH_APPURL`/`HERMES_DASHBOARD_PUBLIC_URL`) as: injected `HOME_STACK_SELF_URL` if set, else `home_stack_service_url <its own name>` (still registry-authoritative, reading the engine's own `catalog.json`, never a profile-variable fallback), else fail closed naming both sources. This fallback exists because `hs restart` is `launchctl kickstart -k`, which re-execs a loaded job under its EXISTING environment — launchd only re-reads a plist on bootstrap — so a service started under an older plist (before the next `install-launchd.sh --load`) would otherwise crash-loop under KeepAlive the instant `HOME_STACK_SELF_URL` is required with no fallback. The same DATA_DIR fallback (`${HOME_STACK_DATA_DIR:-$HOME_STACK_CONFIG_DIR/data/<name>}`) applies. `run-tinyauth.sh` and `run-hermes.sh` separately resolve **Pocket ID's** URL (for OIDC endpoints/issuer) via the same `home_stack_service_url` helper.
  - `HOME_STACK_ENABLE_*`, `HOME_STACK_POCKET_ID_SUBDOMAIN`, `HOME_STACK_TINYAUTH_SUBDOMAIN`, `HOME_STACK_PHASE_A_CADDY_PORT`/`HOME_STACK_PHASE_B_CADDY_PORT`, and `HOME_STACK_DEV_DOMAIN` are deleted from both profiles, all fixtures, and `templates/profile.env.example`. `hs app`'s stub dispatch (`cmd_app_add`) is removed; `hs`'s dispatch now refuses any unrecognized first-level command (`hs app add`, `hs bogus x`) with usage and exit 2 before the `<service> <command>` fallback is attempted — only a known lifecycle verb (`start`/`stop`/`restart`/`status`/`reload`) in the second argument position reaches that fallback, so `hs <service> start` keeps working while `hs app add` no longer reaches `service-launchd.sh` at all.

- **Generation engine**
  - Go engine generates `portable/home-stack/Caddyfile`, `catalog.json`, and `launchd/*.plist` from the active profile.
  - All generated artifacts are gitignored — they are runtime state, not source.
  - `syncSystem()` materializes registry state and reloads Caddy.
  - Admin binary supports `home-stack-admin sync` as a local subcommand for CLI invocation.
  - `templates/Caddyfile.template` is deleted — the engine is the sole Caddyfile generation path. `render-caddyfile.sh` remains for local dev modes (`LOCAL_HTTP=1`, `LOCAL_TLS=1`) only.
  - `reload-caddy.sh` validates and reloads the engine-generated Caddyfile without re-rendering.
  - Caddy's LaunchDaemon plist and user LaunchAgent plists are engine-generated from the registry. Installation remains a separate reviewed step.

- **Profiles & Portability (Phase 1)**
  - No owner-specific fallbacks remain in code, scripts, or templates. Mandatory variables must come from the active profile; the loader fails fast and lists every missing key.
  - Variable contract enforced: `HOME_STACK_PARENT_DOMAIN`, `HOME_STACK_TAILNET_IP`, `HOME_STACK_ACME_EMAIL`, `HOME_STACK_OWNER_HOME`, `HOME_STACK_IDENTIFIER_PREFIX`, `HOME_STACK_ADMIN_USERNAME`.
  - Four-layer loading order: code defaults (non-identity only) → `profiles/<name>/home-stack.env` → `~/.config/home-stack/config.env` → `~/.config/home-stack/env.local`. Identity keys are rejected if set in `env.local`.
  - Registry uses `subdomain` (composed against `parent_domain`) or absolute `host`; never both.
  - `scripts/lib/common.sh` exposes `home_stack_resolve_profile`, `home_stack_validate_mandatory`, `home_stack_reject_identity_in_env_local`, and the new `home_stack_load_env`.
  - Admin binary refuses to start when mandatory env is absent (`validateEnv()` in `main.go`).
  - `tests/profile-portability.test.sh` drives an `acme` fixture (distinct from the maintainer's own) end-to-end and asserts zero maintainer-specific strings leak into generated artifacts.

- **CLI helpers**
  - `hs sync` invokes the local admin binary's `sync` subcommand (no HTTP).
  - `hs init [<name>] [--force]` bootstraps a profile from `profiles/default/`, scaffolds runtime dirs, and seeds `env.local` from `templates/env.example` (never overwrites existing secrets).
  - `hs doctor` is a 9-section portability preflight (the ninth checks identity-layer coherence: gated routes against the Caddy binary's plugins, sso routes against a registered broker, registered identity services against their binaries, and the Admin proxy secret's presence): profile resolution, mandatory variables, identifier-prefix sanity, registry presence, env.local presence/mode/identity-key check, required binaries, Tailnet, footer. Never echoes secret values.
  - `hs app add` was removed; Phase F shipped as `hs service add/remove` (below). The `hs app` migration-message stub is gone too (P2): an unrecognized first-level command like `hs app` now prints usage and exits 2 instead.
  - `hs status`, service lifecycle commands, and `hs logs` continue to work.

- **Dev gateway code**
  - `portable/home-stack/dev-gateway/main.go` exists.
  - `portable/home-stack/scripts/run-dev-gateway.sh` exists.
  - Registry contains a `dev-gateway` service entry.

- **Catalog artifact**
  - Generated to `portable/home-stack/catalog.json` (gitignored) on every sync.

- **Portal catalog and status projections**
  - Admin publishes schema-v1 sanitized projections at the exact Portal-origin paths `/.well-known/home-stack/catalog.json` and `/.well-known/home-stack/status.json`.
  - Caddy sends only those two paths to Admin and keeps the rest of `portal.<parent-domain>` on the static `home-portal/dist` root.
  - The catalog includes every registry service but only safe discovery fields; headless/task services remain visible and non-launchable.
  - Status is computed from live Admin checks and exposes only coarse process/network/route/HTTP state. PIDs, targets, diagnostics, details, actions, paths, upstreams, logs, and credentials are excluded.
  - Handlers require the Portal Host. All normal Admin surfaces remain authenticated and no Portal mutation capability exists.
  - Canonical schema-v1 documents live under `schemas/portal/`; Go tests compile them and validate projected catalog/status output, while the consumer repo runs Ajv and Zod checks against mirrored fixtures.

- **Identity layer (deployed)**
  - `auth:` registry field with a closed enum (`none` / `tailnet` / `sso` / `tailnet-or-sso`); the engine emits one fixed Caddy block per value and validation rejects anything else.
  - `tailnet` uses the caddy-tailscale plugin's `tailscale_auth`, resolving the connecting peer through the local tailscaled WhoIs API — zero interaction, no extra process. Tagged (machine) nodes are refused by the provider.
  - `sso` and the fallback lane of `tailnet-or-sso` call tinyauth's `/api/auth/caddy`. Browsers receive a 302 to the login page; non-browser clients receive 401 plus `x-tinyauth-location`.
  - Pocket ID (passkey-only OIDC) and tinyauth (broker) are registered services with loopback binds and launchd wrappers; both are `auth: none` because they are the login path.
  - `admin` runs `auth: tailnet-or-sso`, verified live: the Caddy gate resolves tailnet identity and passes, leaving Admin's own Basic Auth as a second factor. `dev-gateway` carries `auth: tailnet` but is unreachable until `*.dev` has a certificate.
  - Live-verified end to end: zero-click tailnet identity, and tinyauth federating to Pocket ID for passkey login.
  - All binaries build for the host's real architecture; the Makefile derives GOARCH rather than trusting the toolchain's default.
  - **Cutover verified.** The ingress runs a binary built for the host's real architecture, with both plugins; the previous binary is retained on disk for rollback (`docs/RUNBOOK.md` → rollback procedure).

- **Continuous verification**
  - GitHub Actions runs Go tests on Linux and the full host suite on macOS.
  - Dependabot proposes pinned Go module and GitHub Actions updates weekly.

- **Hermes Agent production integration**
  - A profile's `services.yaml` declares the official Hermes dashboard as a managed service with an engine-generated LaunchAgent and Admin-derived start/stop/restart actions.
  - `run-hermes.sh` loads the four-layer environment for resolution, then replaces it with a Hermes-specific child allowlist before exec. It keeps state under `~/.hermes`, requires a scrypt password hash plus stable signing secret, binds the profile's exact Tailnet IP, and runs `hermes dashboard --no-open` in the foreground without exposing unrelated stack secrets to agent tools.
  - The Caddy route uses the fixed `proxy_identity: upstream` mode so Hermes' Host/Origin rebinding guard accepts the HTTPS and WebSocket proxy path while Caddy retains normal `X-Forwarded-*` identity.
  - The reviewed install procedure (`docs/RUNBOOK.md`) installs a pinned official Hermes Agent checkout under `~/.hermes/hermes-agent` with the official web/PTY extras, a managed Python runtime, browser engine, and current config schema. Record the actual installed version/commit in your overlay's `INSTALLED.md`.
  - The generated LaunchAgent is installed and loaded in the owner GUI domain with `RunAtLoad` and `KeepAlive`; Caddy serves the dashboard's HTTPS route and the authenticated raw port is Tailnet-only at the profile's exact Tailnet IP.
  - Only the official scrypt hash and stable signing secret live in mode-0600 `env.local`; the plaintext break-glass login belongs in an Apple Passwords/iCloud Keychain website record, not a generic local Keychain item.
  - The reviewed verification checklist (`docs/VERIFICATION.md`) proves `auth_required: true`, an active auth provider, unauthenticated `401`, authenticated HTTPS login, PTY WebSocket streaming through Caddy, restart-persistent sessions, Admin lifecycle restart, no `0.0.0.0`/LAN/Tunnel listener, and healthy peer services. Record your own verification results in your overlay's `INSTALLED.md`.
  - Hermes-owned runtime configuration (model/provider routing, auxiliary model assignments, price/privacy routing constraints, memory and skill-write approvals, delegation bounds) is deliberately configured outside Home Stack; record the deployed configuration in your overlay's `hermes-deployed.md`.
  - General terminal/file/code/browser/delegation capability may be enabled for the authenticated operator per `docs/HERMES_OPERATING_MODEL.md`. Messaging, cron tool access, computer-use, image generation, and MCP servers should stay disabled until deliberately reviewed and enabled.
  - Upgrades follow the reviewed pattern in `docs/RUNBOOK.md`: back up config, run the pinned installer/`hermes update` against a reviewed commit, converge the locked environment if needed, and re-run `hermes security audit`.
  - The official gateway is supervised by its own upstream-generated `ai.hermes.gateway` LaunchAgent — not a Home Stack registry entry — verified per `docs/VERIFICATION.md` § Hermes Gateway Checks. With no messaging platform configured it opens no listener and stays alive only for cron/housekeeping.

- **Registry management (Phase F)**
  - `hs service add/remove`: interactive (gum) and non-interactive CLI for adding/removing services from the registry.
  - `hs deploy [--preview|--apply]`: shows diff between desired state and deployed state, applies changes with confirmation.
  - Admin webapp: deploy tab shows per-section diff (Caddyfile/Launchd/Catalog) with Apply button.
  - Admin webapp: service add sheet with type/lifecycle cards, conditional fields, live preview.
  - Web app mutations: `registry.add`, `registry.remove`, `deploy.preview`, `deploy.apply` through typed `/api/actions`.
  - Shared Go logic in `registry.go`: AddService, RemoveService, Diff, Apply with atomic writes.
  - New service shape: `type: split` (static assets + API proxy), `lifecycle` field (managed/external/custom), `plist` field, `api_path` field.
  - Admin binary runs from `portable/home-stack/admin/home-stack-admin` (persistent), no longer `/tmp`.
  - `hs deploy --preview` initializes its private loopback Admin transport from the loaded profile/secrets and reports the deployed registry as in sync.

- **Test suite**
  - Go tests plus 17 host shell test scripts cover load-bearing surfaces across three tiers: host (`make test`), Linux container (`make test-linux`), and Tart macOS VM (`make test-mac`).
  - Go unit tests in `portable/home-stack/admin/` cover engine, actions, events, incidents, models, templates, and doctor.
  - Bash tests in `tests/` cover env safety, env layering, engine snapshots (3 fixture goldens), engine idempotency, profile portability, CLI bootstrap, admin action safety, admin HTTP contract, plist lint, secret redaction, identifier prefix flows, install-launchd end-to-end, and service lifecycle.
  - Mac-only tests guard with `HOME_STACK_TEST_ALLOW_SYSTEM_CHANGES=1` or Tart VM detection.
  - Linux-agnostic tests skip macOS-specific services (launchctl/plutil).

## Partial, Disabled, Or Mismatched

- **Hermes iPhone client validation**
  - The Basic credential rotation procedure (`docs/RUNBOOK.md`) regenerates
    the server-side hash from the existing Apple Passwords website credential
    without exposing the plaintext; a deployment records its own rotation
    history and current tested state in its overlay's `hermes-deployed.md`.
  - The intended `goncharik/hermes-mobile` iPhone client is community software
    using the official dashboard API. Its current implementation requires the
    Basic provider (self-hosted OIDC is unsupported) and stores only the
    resulting session in the device Keychain. Physical-device sign-in, session
    resume, and streaming remain to be checked per deployment. Optional
    third-party push remains disabled.

- **Deploy cockpit**
  - Preview and apply are implemented through typed Admin actions and shared Go registry logic.
  - Apply regenerates Caddy/launchd/catalog state and reloads Caddy, but does not install or restart changed LaunchAgents; operators still review and run the launchd installer separately. The reason it was deferred (the `bootout`/`bootstrap` race) was retired on 2026-08-08, so converge can now be finished (`docs/PLAN.md` §3.3).

- **Dev gateway production enablement**
  - Code and launchd artifacts exist, but the service is treated as optional/informational.
  - Feature defaults and DNS/TLS readiness should be verified before treating it as production-critical.

## Not Implemented Yet

- Hermes coding-agent concurrency exercises, an allowlisted messaging channel,
  and scheduled automation remain reviewed follow-on work. The official gateway
  supervisor is loaded with no messaging platform yet. Hermes cannot apply
  custom smart-approval policy to commands its built-in detector considers
  safe; this is documented as a trusted-user operating limitation, not papered
  over with a custom authorization subsystem.

- Server-provided action descriptors (`GET /api/actions` or equivalent read endpoint).
- More detailed deploy plans beyond the current per-section diff.
- Admin event filtering/search.
- Admin log tailing/streaming.
- Deeper Admin Doctor checks (the CLI `hs doctor` covers the portability contract and identity-layer coherence; the Admin `GET /api/doctor` surface still needs Caddyfile validation result, registry validation details, launchd plist presence, and binary/version checks).
- Native-feeling mobile action confirmation sheet; frontend still uses browser confirmation.
- Reliability: prefix-isolated launchd tests on the host, lifecycle bug list verified, sleep/reboot doctor checks (`docs/PLAN.md` §3.10). Tart stays disabled.
- Migration: outside-git inventory table, one export command, reinstall table (`docs/PLAN.md` §3.11).
- A shared notifier — only when a second client needs it (`docs/PLAN.md` §3.12).
- The first tenant app (external repository) onboards itself when ready; home-stack's side is P2.
- Cloudflare Tunnel / `.remote.` external gateway implementation (`docs/REMOTE_ACCESS.md`) — parked until an app needs it.
- `remote:` / `remote_aud:` registry fields and their generation behavior.
- Upgrade helpers such as `hs upgrade status` and `hs upgrade caddy`, and the `install:` registry block.
- Full `hs dev` helper family.

Retired from the plan (2026-09-04): the `hs app` helper family. Phase F shipped as `hs service add/remove` + `hs deploy`; the `hs app` migration-message stub was removed in P2 — an unrecognized first-level command now prints usage and exits 2.

## Known Documentation Notes

- The original roadmap and earlier dated implementation plans are archived
  outside this repository (`docs/INDEX.md` → Historical context), not the
  primary tracker.
- This status file should be treated as the cross-project progress ledger.
