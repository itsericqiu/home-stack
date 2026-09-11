# Documentation Index

Last updated: 2026-09-10

Use this map to choose the right document. Every file under `docs/` is listed.

## What lives where

| Tier | Lives in | Examples |
|---|---|---|
| **Machinery and procedures** | this repo (public) | engine, scripts, tests, docs that say *how* |
| **Deployment record** | the owner's private dotfiles overlay | the real profile, version pins, verification transcripts, deployed agent config, Keychain item names |
| **Secrets** | `~/.config/home-stack/env.local` and service-private dirs — never in any repo | tokens, hashes, signing secrets |

Deployment records never go in this repository; `docs/STATUS.md` describes
the code, the overlay describes the machine. See `docs/PUBLIC_RELEASE.md` for
the full rationale.

## Source-of-truth order

1. `AGENTS.md` — contributor and safety rules, including the runtime rules
   agents otherwise violate.
2. `docs/STATUS.md` — current implementation state. Inspect before assuming
   what is done.
3. `docs/ROADMAP.md` — current planned work and its sequence.
4. `docs/ARCHITECTURE.md`, `docs/SECURITY_MODEL.md`, `docs/RUNBOOK.md` — model,
   boundaries, operations.
5. Active specs (below), then `docs/DECISIONS_LOG.md` for why.
6. Historical context (below) — provenance only.

## For new readers

- `README.md` — what home-stack is, requirements, quick start, daily commands,
  current gaps.
- `docs/ONBOARDING.md` — bringing up home-stack on a new machine.
- `docs/MIGRATION.md` — upgrading an existing installation to the current
  contract; portable migration to a new host.
- `docs/RUNBOOK.md` — operational procedures: build, secrets, profiles,
  launchd, sync, Hermes, Admin, logs, upgrades, identity layer, troubleshooting.
- `docs/VERIFICATION.md` — the validation checklist per change type.

## For maintainers

- `docs/STATUS.md` — implementation ledger; update when behavior changes.
- `docs/ROADMAP.md` — planned work; update when priorities shift.
- `docs/ARCHITECTURE.md` — system model, generation boundaries, identity
  tiers, remote-access model, upgrade model.
- `docs/SECURITY_MODEL.md` — secrets (shared and service-private), token scope,
  network exposure, identity layer, Admin, Portal projection, review triggers.
- `docs/SERVICE_INTERFACE.md` — the contract for services and tenant apps:
  binding, lifecycle, logging, health, `auth:`, persistence, planned fields.
- `docs/HERMES_OPERATING_MODEL.md` — staged authority contract for the Hermes
  agent as personal operator, coding dispatcher, and automation host.
- `docs/DECISIONS_LOG.md` — decision history and follow-ups.
- `docs/GOVERNANCE.md` — roles, decision rights, tag cadence.
- `docs/CONTRIBUTING.md` — contribution notes.
- `docs/PUBLIC_RELEASE.md` — the tier rule above and the workstream that
  enforces it.
- `CHANGELOG.md` — dated sections per tag.

## Active specs

- `docs/PLAN.md` — the coherence audit and forward direction: findings, the
  sequence, and per-workstream specifications (tenant-ready registry,
  reliability, migration, and the items pulled by need).
- `docs/REMOTE_ACCESS.md` — Phase D: Cloudflare Tunnel + Access design,
  `remote:` registry contract, supporting services, tests, acceptance,
  rollback. Complete and parked until an app needs it.
- The first tenant app's own repository documents its home-stack onboarding
  contract; home-stack's side of that contract is `docs/SERVICE_INTERFACE.md`.

## Reference notes

- `docs/DEVTOOLS_TLS.md` — local-development TLS notes.
- `docs/SESSION_TEMPLATE.md` — template for session handoff notes.

## Historical context

Earlier design history (session logs, dated implementation plans, and the
original roadmap) lives in the archived private repository, not in this
public tree.
