# Governance

Last updated: 2026-09-04

home-stack is a single-maintainer repository. This page records who decides
what, so agents and future contributors do not have to guess.

## Roles

- **Owner / maintainer:** the repository owner. Sets direction, approves plan
  changes, merges, and operates the live host.
- **Contributors:** coding agents and occasional humans. They propose changes
  as pull requests and never merge infra-review changes themselves.
- **Operator:** whoever runs bootstrap, sync, install, and verification on a
  host — today, the owner.

## Decision rights

- Architecture, security boundaries, exposure, and secrets: owner decision,
  recorded in `docs/DECISIONS_LOG.md` before or with the change.
- Changes touching Caddy generation, launchd, sudoers, secrets, routing,
  Cloudflare/DNS/TLS, tunnels, or deployment require **infra review** by the
  owner before merge (`AGENTS.md`).
- Documentation-only changes may merge on green CI.

## Cadence and versioning

- Every merged workstream gets an annotated tag (`v0.1.0` was cut on
  2026-09-04 at the identity-layer merge). `CHANGELOG.md` carries a dated
  section per tag; "Unreleased" is for work between tags only.
- `docs/STATUS.md` is updated after every implementation session;
  `docs/ROADMAP.md` when priorities shift; `docs/PLAN.md` §1 is re-run when a
  workstream lands.

## Change lifecycle

1. Proposal in a PR or a spec under `docs/`. A superseded spec is archived
   outside this repository (`docs/INDEX.md` → Historical context).
2. Review: CI, then infra review where required.
3. Merge, tag if a workstream completed, then deploy and verify on the host
   per `docs/VERIFICATION.md`.
