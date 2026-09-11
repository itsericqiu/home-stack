# Home Stack Roadmap

Last updated: 2026-09-10

This roadmap describes the current forward plan. Implementation truth is
`docs/STATUS.md`; the reasoning behind this sequence, and the audit that
produced it, is `docs/PLAN.md`. Superseded design notes are archived outside
this repository (`docs/INDEX.md` → Historical context).

## Direction (2026-09-05)

The host is a laptop for the foreseeable future, and it may be migrated to a
new Mac — laptop or desktop — at any point. Two things outrank every feature:

1. **Reliable on a laptop.** Services survive sleep, lid, network changes, and
   reboots in a way that is documented, observable, and tested without
   touching production labels or files.
2. **Migration is a known procedure.** Everything that lives outside git is
   inventoried, and a new Mac is brought up by following `docs/MIGRATION.md`
   top to bottom.

This is a personal project. Build only what a real need pulls: no speculative
services, no tool families where a table and a command will do, no VM tier
when prefix isolation on the host gives the same safety. Remote access is
designed and parked. The Admin webapp is frozen at v1.

## Sequence

| Order | Workstream | Depends on | Infra review | Spec |
|---|---|---|---|---|
| P0 ✓ | Merge the identity layer to `main`; tag `v0.1.0` | — | no | done 2026-09-04 |
| P1 ✓ | Doc reconciliation and direction | P0 | no | `docs/PLAN.md` §3.1 |
| P2 ✓ | Tenant-ready registry: `enabled:`; engine-injected `HOME_STACK_SELF_*` and `HOME_STACK_DATA_DIR`; retire dead env flags and duplicate hostname vars; isolate `make test` from the production binary | P1 | **yes** — generation | `docs/PLAN.md` §3.2 |
| P3 | Reliability: prefix-isolated launchd tests on the host; verify or fix the known lifecycle bugs; finish `deploy.apply` converge; sleep/reboot runbook and `hs doctor` checks | P2 | **yes** — launchd | `docs/PLAN.md` §3.10, §3.3 |
| P4 | Migration: the outside-git inventory, one documented export command, a reinstall table per component | P3 | no (docs) + small script | `docs/PLAN.md` §3.11 |
| Pulled by need | `hs upgrade` ✓ (delivered — see below); a shared notifier (when a second client — Hermes approvals — is being built); remote access (when an app must be reached without Tailscale); dev gateway (when a workflow wants it) | — | yes | `docs/PLAN.md` §3.6, §3.12, §3.4/`docs/REMOTE_ACCESS.md`, §3.5 |

Tenant apps onboard themselves against the contract when they are ready;
home-stack's obligation is that the contract is real (P2) and the onboarding
path is documented (`docs/SERVICE_INTERFACE.md`). The first tenant app, in its
own repository, will arrive on its own schedule.

## Principles

1. **The registry is the only source of truth.** The engine emits fixed,
   reviewed blocks from closed enums. No directive surfaces, no shell-style
   interpolation, no environment flags that shadow registry state.
2. **Nothing listens publicly by default.** Every public route is an explicit,
   per-service, registry-declared, edge-authenticated, origin-verified
   exception. Native-protocol exceptions never get one.
3. **Fewest moving parts.** No VPS, no containers, no second supervisor, no
   wrapper per CLI, no tool where a documented command will do.
4. **Docs are governance.** `STATUS.md` is truth, this file is intent,
   `DECISIONS_LOG.md` is why. A change that lands without touching all three
   is incomplete.
5. **Reliable and migratable beat featureful.** A capability that cannot be
   tested without touching production, or that adds state the migration
   inventory does not cover, is not done.

## Workstreams

### Tenant-ready registry (P2) ✓

- `enabled: true|false`; `false` emits no route and no plist, shows as
  `disabled` in Admin, is projected non-launchable to Portal.
- The engine injects `HOME_STACK_SELF_NAME`, `HOME_STACK_SELF_HOST`,
  `HOME_STACK_SELF_URL`, and `HOME_STACK_DATA_DIR` into every managed plist,
  so a wrapper or tenant derives nothing from parallel profile variables.
- Deleted the inert `HOME_STACK_ENABLE_*` flags, the duplicate
  `HOME_STACK_POCKET_ID_SUBDOMAIN` / `HOME_STACK_TINYAUTH_SUBDOMAIN` /
  `HOME_STACK_DEV_DOMAIN` variables, and the phase-era Caddy port defaults.
- `make test` builds to a gitignored staging path; only an explicit
  `make build-admin` writes the production binary.
- Service-private secrets rule and the tenant-app section in
  `docs/SERVICE_INTERFACE.md` (landed in P1).

### Reliability (P3)

Current state: `make test-mac` is disabled; three host tests write into the
source tree and use production labels, which is why the launchd tests may
never run on this host. A lifecycle bug list from the 2026-08-08 reviews is
unverified. After a reboot, LaunchAgents wait for a GUI login; lid-closed on
battery sleeps the host.

- **Prefix-isolated tests.** The identifier-prefix parameterization already
  exists: run the launchd tests under a test prefix
  (`<prefix>.hstest.*`), test ports, and a temporary `HOME_STACK_CONFIG_DIR`
  and bundle copy, so nothing they bootstrap, write, or delete can collide
  with production. The destructive-test guard becomes "no production label,
  no source-tree write" rather than "never on this host". Tart stays
  disabled; revisit only if prefix isolation proves insufficient.
- **Lifecycle bug list**, verify then fix, one PR each: `diffPlists`
  comparing names only; `lifecycle: external` bootstrapped into a KeepAlive
  loop; uninstall without `--unload` orphaning jobs; `run-admin.sh` never
  rebuilding a stale binary; prefix validation only in `hs doctor`. Confirm
  the two believed fixed by the 2026-08-08 race work.
- **`deploy.apply` converge** (`docs/PLAN.md` §3.3), tested under the test
  prefix.
- **Sleep and reboot**: a RUNBOOK section stating the truth (AC-powered with
  `pmset` sleep disabled; lid-closed on battery sleeps; a reboot needs a login
  before agents start; no unattended OS-update restarts), plus `hs doctor`
  checks for `pmset` state, "agents loaded since boot", and the registry's
  literal Tailnet IP matching the profile.

### Migration (P4)

Current state: `docs/MIGRATION.md` covers clone, build, profile, secrets,
sync, install, verify — and omits every path outside git.

- An inventory table: each path outside git, its owner, sensitivity, and
  whether it is copied, re-issued (TLS), or re-enrolled (passkeys if Pocket
  ID's database is lost). Known entries: `env.local`; `data/*` per service;
  service-private secret dirs; `~/.hermes`; Keychain break-glass items;
  tenant binaries; the Portal build; identity that changes on a new Mac
  (Tailnet IP in the profile *and* the Hermes upstream literal; owner home).
- One documented export command (a `tar` of the copy-class entries, 0600)
  and the matching restore steps; a per-component "how installed / how to
  reinstall" table. No tool family.
- `env-set.sh` backup rotation (fourteen `env.local.bak.*` files exist today).
- The rehearsal is the real one: the day a new Mac arrives, follow the doc
  and fix what it gets wrong.

### Hermes

The staged operating contract is `docs/HERMES_OPERATING_MODEL.md`. Next: one
allowlisted channel, then deterministic read-only cron. When approvals need a
way to reach the phone, that is the moment a shared notifier is extracted
from whichever tenant already has one.

### Parked, pulled by need

- **Remote access** — `docs/REMOTE_ACCESS.md` is complete; build it the week
  an app needs to be reached from a machine that cannot run Tailscale. Remote
  Admin and remote Hermes: never.
- **Shared notifier** — extract from the first tenant's push code when the
  second client is being built (`docs/PLAN.md` §3.12 is the sketch).
- **Dev gateway** — `enabled: false` after P2; DNS record and `hs dev`
  helpers if a workflow ever wants them.
- **Admin webapp** — frozen at v1. Bug fixes only; `hs` plus Hermes are the
  operator surface. Basic Auth stays as break-glass (`docs/SECURITY_MODEL.md`).

### Upgrade tooling (`hs upgrade`) ✓ — delivered 2026-09-10

Pulled by need: four operator-installed components (Pocket ID, tinyauth,
Caddy, Hermes) had no reviewed upgrade procedure beyond a RUNBOOK recipe, and
OpenCode/OpenChamber's self-updaters were run by hand with no drift
visibility. The registry gained an optional `install:` block
(`docs/SERVICE_INTERFACE.md` §4d) and `hs upgrade status` / `hs upgrade
<service>` (`portable/home-stack/scripts/lib/upgrade.sh`) turn each RUNBOOK
recipe into a reviewed, scriptable procedure with a backup, a health check,
and an auto-revert on failure. Fully automated: `github-release` (Pocket ID),
`source-go` (tinyauth), `npm-global` (OpenChamber), `opencode`. Still manual
by design: `xcaddy` (Caddy) stops short of the daemon restart, which needs
`sudo`; `hermes-pinned` requires `--yes` and a full commit SHA, since it
mutates `~/.hermes`; `brew` is status-only (`brew upgrade <formula>` by hand).

## Historical Context

The Phase 1 design notes that used to live here (now implemented), the
original roadmap, earlier session handoffs, and dated implementation plans
are archived in the archived private repository — see `docs/INDEX.md` →
Historical context.
