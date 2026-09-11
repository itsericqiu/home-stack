# Home Stack

Home Stack turns one macOS machine into a private, Tailnet-only homelab:
local services run under launchd supervision behind one Caddy ingress, served
with real HTTPS at stable names like `https://admin.<your-domain>/` that are
reachable only from your own Tailscale network. A mobile-first Admin webapp
provides status, triage, and safe service operations. A service registry —
one YAML file per profile — is the single source of truth that a Go engine
turns into the Caddyfile, launchd plists, and a discovery catalog.

## What this is not

- **Not multi-host.** One Mac is the whole stack. There is no clustering, no
  distributed state, no load balancing.
- **Not Linux.** Supervision is launchd; the scripts assume Darwin throughout.
- **Not a product.** This is an opinionated personal project, built and
  maintained for one owner's own machine. It is published so the machinery is
  reusable and inspectable, not because it aims to serve a general audience.
  Expect sharp edges outside the documented paths, and expect the roadmap to
  reflect one person's priorities (`docs/ROADMAP.md`).

## What you get

- **One HTTPS ingress**: Caddy (with the Cloudflare DNS-01 plugin) terminates
  TLS for `*.<your-domain>` on your Tailnet IP. No ports exposed to the
  internet; no raw `localhost:PORT` juggling.
- **Supervised services**: launchd keeps long-running services alive and runs
  scheduled tasks (like log rotation) on intervals. Crash → restart, boot →
  start.
- **A service registry as source of truth**: `profiles/<name>/services.yaml`
  declares your services; a Go engine generates the Caddyfile, launchd plists,
  and a catalog from it. You never hand-edit generated artifacts.
- **An admin control plane**: `https://admin.<your-domain>/` — gated at the
  ingress by tailnet identity (zero-click from your own devices, passkey login
  otherwise), with Basic Auth retained underneath as a second factor and
  break-glass; a mutation-allowlisted webapp for status, health checks,
  service restarts, deploy preview/apply, and registry inspection. Plus an
  `hs` CLI for everything scriptable.
- **A read-only Portal boundary**: a separate static Portal app can consume
  versioned, sanitized catalog and health projections published on its own
  origin. New registry entries appear automatically without exposing Admin
  credentials, diagnostics, process identifiers, filesystem paths, or
  mutation actions. This repository ships only the minimal static fallback
  page for that origin; the richer Portal PWA lives in its own repository,
  [home-portal](https://github.com/itsericqiu/home-portal), as an external
  consumer of the published schemas (`schemas/portal/`).
- **An optional identity layer**: Pocket ID (passkey-only OIDC) and tinyauth
  (a login broker) can sit behind the ingress so services opt into zero-click
  tailnet identity, brokered sessions, or both, per the registry's `auth:`
  field.
- **Optional agent/app tenants**: the registry can also describe an
  externally-built agent or app that home-stack only supervises and routes —
  see `docs/SERVICE_INTERFACE.md`.

## Requirements

Accounts and infrastructure:

- **A domain managed by Cloudflare**, plus an API token scoped for DNS edits
  (used for DNS-01 certificate issuance only — nothing is served through
  Cloudflare by default).
- **Tailscale**, installed and logged in on the machine. Exposure is
  Tailnet-only by default; devices on your tailnet reach the stack, nothing
  else does.

On the machine (macOS only — supervision is launchd, scripts assume Darwin):

- Homebrew.
- Go (builds the custom `caddy-cloudflare` binary via xcaddy, and the admin
  service).
- `gum` (`brew install gum`) — only for the interactive bootstrap.
- Whatever binaries your own registry entries need (OpenCode/OpenChamber,
  Hermes, Pocket ID, tinyauth, …) — only if you enable them.

## Quick start

```bash
git clone <this-repo> && cd home-stack
portable/home-stack/scripts/bootstrap.sh
```

The bootstrap script walks the full setup: checks prerequisites, prompts for
your profile values and secrets (never echoed), builds Caddy, scaffolds your
profile via `hs init`, runs `hs doctor` + `hs sync`, and installs services
with `install-launchd.sh --load`. Equivalently, by hand:

1. `portable/home-stack/scripts/hs init [<name>]` — scaffolds `profiles/<name>/`
   from `profiles/default/`.
2. Fill in your profile's mandatory identity variables and `services.yaml`.
3. Populate secrets in `~/.config/home-stack/env.local`.
4. `portable/home-stack/scripts/hs doctor` — validates the whole contract
   before you touch anything live.
5. `portable/home-stack/scripts/hs sync` — generates the Caddyfile, catalog,
   and launchd plists (build the admin binary first: `make build-admin`).
6. `portable/home-stack/scripts/install-launchd.sh --load` — installs and
   starts services.

Once you've run `portable/home-stack/scripts/install-helpers.sh --with-ops`
(see "Daily operation" below), the bare `hs` command works directly;
`install-launchd.sh` is always invoked by its full path.

`profiles/<name>/` (everything but `profiles/default/`, the tracked starter
template) is gitignored by design — it's yours, not this repository's. Keep
it in your own dotfiles and symlink it in (`HOME_STACK_PROFILES_DIR` can also
point the tooling at a profile living elsewhere). See `docs/ONBOARDING.md`
for the full manual path.

## What runs out of the box vs. what is an example

Out of the box: Caddy and the Admin control plane — the two uncommented
entries in `profiles/default/services.yaml`. Everything else in that file —
a Portal (the shipped fallback page, or the
[home-portal](https://github.com/itsericqiu/home-portal) PWA), Hermes,
OpenCode/OpenChamber, Pocket ID, tinyauth, a dev gateway — is a commented
**example registry entry**, meant to show the shape of a real service
declaration, not something this repository installs for you. The Portal entry
must be named `portal`: that is the name the engine attaches the two
projection routes to. Enable, remove, or replace any of
them; the registry doesn't care which services exist, only that they satisfy
`docs/SERVICE_INTERFACE.md`.

## How configuration works

Two layers, strictly separated:

1. **Profile (tracked)** — `profiles/<name>/home-stack.env` holds identity:
   `HOME_STACK_PARENT_DOMAIN`, `HOME_STACK_TAILNET_IP`,
   `HOME_STACK_ACME_EMAIL`, `HOME_STACK_OWNER_HOME`,
   `HOME_STACK_IDENTIFIER_PREFIX`, `HOME_STACK_ADMIN_USERNAME`, and ports.
   `profiles/<name>/services.yaml` is the effective service-selection source.
   `profiles/default/` is the starter template that `hs init` copies from.
2. **Secrets (never tracked)** — `~/.config/home-stack/env.local` (mode 0600)
   holds `HOME_STACK_ADMIN_PASSWORD`, `HOME_STACK_CLOUDFLARE_API_TOKEN`, and
   any per-service credentials. The loader rejects identity keys in this file,
   and `hs doctor` audits both layers without printing values. Use
   `portable/home-stack/scripts/env-set.sh KEY` to update secrets safely.

Generated artifacts (Caddyfile, catalog.json, launchd plists) are gitignored
and rebuilt by `hs sync`; `tests/profile-portability.test.sh` generates
against fixture profiles and fails if any output — or anything in the runtime
bundle itself — contains hardcoded deployment values.

## Operational realities

Worth knowing before you depend on it:

- **Tailnet-only by construction.** Caddy binds the Tailscale IP; backends
  bind `127.0.0.1`; Caddy's own admin API stays private on `127.0.0.1:2019`.
  Nothing listens on public interfaces by default.
- **A narrow native-client exception exists.** A service may bind the
  profile's exact Tailnet IP instead of loopback only when its native clients
  require a non-loopback listener and it provides its own fail-closed
  authentication — see `docs/SERVICE_INTERFACE.md` → Authenticated
  native-protocol exception. It is never published through a public tunnel.
- **Reboots and FileVault**: Caddy runs as a LaunchDaemon (starts pre-login),
  but ordinary services are LaunchAgents — they start at GUI login. With
  FileVault on, a rebooted machine serves 502s until you log in. For planned
  reboots, `sudo fdesetup authrestart` skips the stall.
- **Sleep**: a laptop must be told to stay awake for the stack to be
  reachable — e.g. `sudo pmset -c sleep 0 womp 1` plus closed-display mode
  (via Amphetamine or similar) if it runs lid-closed. Scope it to AC power so
  the machine still sleeps on battery.
- **Logs** live in `~/.config/home-stack/logs/` and are rotated on a schedule
  by the logrotate task (size threshold + gzip retention).

## Daily operation

Install helper links once: `portable/home-stack/scripts/install-helpers.sh --with-ops`

```bash
hs doctor          # portability + config preflight
hs sync            # regenerate Caddyfile/plists/catalog from the registry
hs status          # multi-signal service status
hs restart <svc>   # allowlisted service operations
hs reload caddy    # pick up Caddyfile changes without restarting Caddy
open https://admin.<your-domain>/
```

## Adding or changing services

Registry-driven, no hand-edited configs:

1. Edit `profiles/<name>/services.yaml` — `subdomain:` for names under your
   parent domain, `host:` for external hostnames. Long-running services get
   supervised (`KeepAlive`); `type: task` entries run on `interval_seconds`
   schedules.
2. `hs sync` — regenerates everything from the registry.
3. `hs reload caddy` — applies routing.
4. `install-launchd.sh --load` — (re)installs launchd services when you added
   or changed one.

Services managed by Home Stack should follow `docs/SERVICE_INTERFACE.md`:
bind `127.0.0.1` unless they satisfy the documented authenticated
native-protocol exception, run foreground under launchd, log to stdout/stderr,
expose a health endpoint where practical, and keep app data outside the bundle.

## Maintainer and agent rules

- Never commit `~/.config/home-stack/env.local`, generated certs, logs,
  databases, or app state.
- Do not print, read aloud, or propagate secret values.
- Changes touching Caddy, launchd, sudoers, secrets, routing,
  Cloudflare/DNS/TLS, or deployment require infra review before merge.
- Keep the Caddy Admin API local-only at `127.0.0.1:2019`.
- Keep Admin mutations typed, allowlisted, audited, and free of arbitrary
  browser-provided command text.
- Update `docs/STATUS.md` after implementation reality changes and
  `docs/ROADMAP.md` when priorities shift.
- Deployment records — what is actually installed on someone's machine —
  never belong in this repository. See `docs/PUBLIC_RELEASE.md` §1.

## Documentation map

- `AGENTS.md` — contributor/agent safety rules.
- `docs/INDEX.md` — full documentation map (start here for everything else).
- `docs/ONBOARDING.md` — new-machine setup, bootstrap and manual paths.
- `docs/STATUS.md` — current implementation state and known gaps.
- `docs/ROADMAP.md` — current planned work.
- `docs/PLAN.md` — the coherence audit and specs behind the roadmap sequence.
- `docs/ARCHITECTURE.md` — system model and boundaries.
- `docs/SECURITY_MODEL.md` — secrets, auth, exposure, and mutation safety.
- `docs/SERVICE_INTERFACE.md` — the contract for services and tenant apps.
- `docs/PUBLIC_RELEASE.md` — what may and may not live in this repository.

## License

MIT — see `LICENSE`.
