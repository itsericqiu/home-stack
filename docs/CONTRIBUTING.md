# Contributing

home-stack is a single-maintainer personal project (see `docs/GOVERNANCE.md`).
Contributions are welcome within that scope.

## Welcome

- Bug reports, with reproduction steps and `hs doctor` output where relevant.
- Portability fixes: anything that makes the stack work for a profile that
  isn't the maintainer's own, or that fixes a hardcoded assumption.
- Documentation fixes and clarifications.
- Test coverage for existing behavior.

## Not welcome

- Features that add moving parts (a new supervisor, a new always-on service,
  a new tool family) without a concrete need pulling them in — see
  `docs/ROADMAP.md` → Principles, especially "fewest moving parts" and
  "reliable and migratable beat featureful."
- Multi-host, Linux, or non-macOS support. This is an opinionated single-Mac,
  Tailnet-only project maintained for one owner, not a general product.

## Process

- Do not commit secrets. Use `~/.config/home-stack/env.local` for host
  secrets, never a tracked file.
- Run the verification commands in `docs/VERIFICATION.md` relevant to your
  change before opening a PR.
- Changes touching Caddy, launchd, sudoers, secrets, routing,
  Cloudflare/DNS/TLS, or deployment require infra review (`AGENTS.md`,
  `docs/GOVERNANCE.md`) and are merged by the owner. Documentation-only
  changes may merge on green CI.
- Update `docs/STATUS.md`, `docs/ROADMAP.md`, or `docs/DECISIONS_LOG.md` when
  your change shifts implementation reality, priorities, or an architectural
  decision.
