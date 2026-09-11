# Onboarding

Last updated: 2026-05-04

For a new contributor, maintainer, or anyone bringing up home-stack on a new machine.

## Prerequisites

- macOS with Homebrew.
- Tailscale installed, logged in, and routing your Tailnet IP.
- Cloudflare zone access for your parent domain plus a DNS-01 token.
- Go installed (for the custom Caddy build and the admin binary).
- `gum` for the interactive bootstrap: `brew install gum`

## Quick-start — Bootstrap Script

The bootstrap script automates the full setup in one guided flow:

```bash
portable/home-stack/scripts/bootstrap.sh
```

It will:
1. Check prerequisites (go, tailscale, git)
2. Prompt for your profile name and all mandatory values
3. Prompt for secrets (admin password, Cloudflare token — never echoed)
4. Build Caddy with Cloudflare DNS + Security modules (one-time)
5. Run `hs init`, configure your profile, write secrets
6. Run `hs doctor` and `hs sync`
7. Run `install-launchd.sh --load` to install and start services
8. Print your admin URL and next steps

## Manual Setup (if bootstrap isn't suitable)

1. Clone the repository.
2. Build the custom Caddy binary with xcaddy + the Cloudflare DNS plugin (see `docs/RUNBOOK.md` §"Build Caddy").
3. Build the admin binary: `cd portable/home-stack/admin && go build -o home-stack-admin .`.
4. Run `portable/home-stack/scripts/hs init [<name>]`. This scaffolds:
   - `profiles/<name>/home-stack.env` (copied from `profiles/default/`)
   - `profiles/<name>/services.yaml`
   - Runtime directories under `~/.config/home-stack/`
   - A stub `~/.config/home-stack/env.local` with `chmod 600` (only if it does not already exist).

   `profiles/<name>/` (everything but `profiles/default/`) is gitignored —
   it's yours, not the repo's, so keep it in your own dotfiles if you want it
   backed up. `HOME_STACK_PROFILES_DIR` can point the tooling at a profile
   living elsewhere without a symlink, mainly useful for tests/CI.
5. Edit `profiles/<name>/home-stack.env` and fill in every mandatory variable (`HOME_STACK_PARENT_DOMAIN`, `HOME_STACK_TAILNET_IP`, `HOME_STACK_ACME_EMAIL`, `HOME_STACK_OWNER_HOME`, `HOME_STACK_IDENTIFIER_PREFIX`, `HOME_STACK_ADMIN_USERNAME`).
6. Edit `~/.config/home-stack/env.local` with real secrets (`HOME_STACK_ADMIN_PASSWORD`, `HOME_STACK_CLOUDFLARE_API_TOKEN`, plus any service secrets you've enabled). Identity keys are forbidden here.
7. Run `portable/home-stack/scripts/hs doctor`. It must report HEALTHY before proceeding. Doctor never prints secret values.
8. Run `portable/home-stack/scripts/hs sync`. The engine validates your registry and generates Caddyfile, catalog.json, and launchd plists from the active profile.
9. Run `portable/home-stack/scripts/install-launchd.sh --load` to install plists and start managed services.
10. Verify with `hs status` and browser checks (`https://admin.<parent_domain>/`).

## Secrets Handling

- Never commit `~/.config/home-stack/env.local`.
- Use `portable/home-stack/scripts/env-set.sh KEY` to update keys in env.local with timestamped backups and no value echoing.
- Identity values (parent_domain, tailnet_ip, acme_email, owner_home, identifier_prefix, admin_username) live in the profile, not in env.local. The loader rejects identity keys appearing in env.local.

## Governance

- Single-maintainer project; the Owner reviews all changes.
- Infra-touching changes (Caddy, launchd, sudoers, secrets, routing, Cloudflare/DNS/TLS, deployment) require explicit review per `AGENTS.md`.

## Migrating An Existing Installation

If you already have home-stack running on this machine and are upgrading from a pre-Phase-1 build, see `docs/MIGRATION.md` §"Upgrading An Existing Local Installation".

## Troubleshooting

- `hs doctor` is the first stop. It reports every missing mandatory var, identifier-prefix sanity, env.local presence/mode, identity-key violations, and binary discovery.
- For deeper operational issues, see `docs/RUNBOOK.md` §"Troubleshooting".
