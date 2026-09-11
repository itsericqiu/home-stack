# AGENTS.md — Home Stack Contributor Guide

Concise guidance for agents and contributors working on **home-stack**.

---

## Project Ownership

home-stack owns the following primitives:

- **Caddy** — reverse proxy configuration and TLS termination. The production Caddyfile is generated exclusively by the Go engine from `profiles/<name>/services.yaml` via `hs sync`. The legacy `templates/Caddyfile.template` has been deleted; `render-caddyfile.sh` remains for local dev modes only.
- **launchd** — macOS service definitions and lifecycle management. User-agent plists and Caddy's system daemon plist are engine-generated from the registry; installation remains a separate, explicitly reviewed operation.
- **Service registry** — service discovery and registration mechanisms. The registry uses `subdomain:` (composed against the active profile's `parent_domain`) or absolute `host:` (rejected if it overlaps the parent domain).
- **Generated catalog** — `portable/home-stack/catalog.json` remains the private, infrastructure-shaped sync artifact. Admin publishes a separate versioned and sanitized Portal projection at `/.well-known/home-stack/catalog.json` only when the request arrives on the Portal host.
- **Status primitives** — Admin's authenticated `GET /api/services` serves the full multi-signal model. A separate versioned and sanitized read-only projection is published at `/.well-known/home-stack/status.json` only through the Portal host; it intentionally excludes diagnostics, targets, PIDs, actions, paths, and credentials.
- **Portal contract schemas** — canonical versioned JSON Schemas live under `schemas/portal/`; Home Stack projection tests validate emitted documents against them. Consumers may mirror them but do not own the contract.
- **Admin primitives** — administrative interfaces and tooling. Admin v1 is implemented at `admin.<your-domain>` (Go service on `127.0.0.1:31510`) as a mobile-first control plane with Triage, Services, Deploy, Events, Doctor, registry-backed service inventory, typed actions, and multi-signal service control. Caddy Admin API remains private at `127.0.0.1:2019`.

---

## What may live in this repository

| Tier | Lives in | Examples |
|---|---|---|
| **Machinery and procedures** | this repo (public) | engine, scripts, tests, docs that say *how* |
| **Deployment record** | the owner's private dotfiles overlay | the real profile, version pins, verification transcripts, deployed agent config, Keychain item names |
| **Secrets** | `~/.config/home-stack/env.local` and service-private dirs — never in any repo | tokens, hashes, signing secrets |

Deployment records never go in this repository; `docs/STATUS.md` describes
the code, the overlay describes the machine. See `docs/PUBLIC_RELEASE.md`.

---

## Secrets Management

- Secrets reside in `~/.config/home-stack/env.local`
- This file **must never be committed** to the repository
- The `.gitignore` should already exclude this path — verify before committing
- Agents should not read, echo, or propagate secret values in logs or output

---

## Agent Tiering

| Tier | Use For |
|------|---------|
| **Cheap agents** | Exploration, documentation, fixture generation, read-only analysis |
| **Infra-review required** | Changes touching Caddy, launchd, sudoers, secrets, routing, Cloudflare/DNS/TLS, or deployment |

Any modification to the above infra-review items requires explicit human review before merge.

---

## Safety Constraints

- **Avoid destructive git commands** — no `git reset --hard`, `git push --force`, `git branch -D`, etc.
- **Avoid destructive system commands** — no `rm -rf /`, `sudo` writes outside home-stack scope, etc.
- Prefer read-only exploration and staged/preview operations over mutating commands

### Runtime rules you will otherwise violate

- **Never run the launchd-mutating tests on the live host.** `make test-mac` runs in a Tart VM; host tests that touch launchd guard on `HOME_STACK_TEST_ALLOW_SYSTEM_CHANGES=1`. Do not set it here.
- **`make test` only compiles the admin package as a check** (`go build -o /dev/null .`); nothing consumes that binary, and it never touches the production binary path. `make build-admin` is the only target that writes `portable/home-stack/admin/home-stack-admin`, the path launchd resolves. `tests/source-tree-guard.test.sh` statically enforces that no test writes to the production path or mutates `$ROOT_DIR`'s `hs`/`reload-caddy.sh` in place, and that no test rsyncs `portable/` outside the shared `tests/lib/stage.sh` helper.
- **launchd reloads:** a loaded agent whose plist is unchanged is restarted with `kickstart -k`; never `bootout` then immediately `bootstrap` — `bootout` is asynchronous. Use `home_stack_wait_label_gone` from `lib/common.sh` before any bootstrap. Never pass `install-launchd.sh --load` on the live host.
- **Agent environments:** a service that can execute tools (Hermes) or a tenant app must receive an explicit child-environment allowlist; wrappers may load the shared environment to resolve the profile but must not pass `HOME_STACK_*` secrets to the child (`docs/SERVICE_INTERFACE.md` §2).

---

## Validation (Preferred Commands)

Run these to validate configuration without claiming they have been executed:

```bash
# Full host test suite (Go + shell, <10s)
make test

# Compare consumer schema mirrors when a sibling home-portal checkout exists
npm --prefix ../home-portal run check:schema-sync

# Linux container cross-platform tests (<30s, requires Docker/OrbStack/Colima)
make test-linux

# Tart macOS VM integration tests (<90s, requires Tart on Apple Silicon)
make test-mac

# Regenerate engine output goldens after code changes
make test-snapshot
```

These commands are suggested for validation — actual execution is the responsibility of the contributor or CI.

---

## Architectural Guidelines

- **Caddyfile generation**: The Go engine is the sole production Caddyfile source. Never add back template-based production Caddyfile rendering; `render-caddyfile.sh` is for local dev modes only (`LOCAL_HTTP=1`, `LOCAL_TLS=1`).
- **Service validation**: Use `validateToken` (control chars only) for service args, binary, working_dir, and env values. Use `validateCaddyToken` (control chars + whitespace) for Caddy-specific fields (upstream, email, host, etc.).
- **Decisions**: Record architectural decisions in `docs/DECISIONS_LOG.md`. Update `docs/STATUS.md` when implementation reality shifts.
- **Tests**: New code should include tests. See the existing `tests/` suite for coverage expectations and conventions.

---

## Contribution Flow

1. Use cheap agents for discovery and documentation tasks
2. For infra-changing proposals, flag the review requirement explicitly
3. Keep secrets out of diffs — double-check `~/.config/home-stack/env.local` is gitignored
4. Prefer validation commands above before suggesting merges
5. Request infra-review when touching owned primitives listed in "Project Ownership"

---

*Last updated: 2026-09-10*
