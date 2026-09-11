# Migration Guide

Last updated: 2026-05-02

This guide covers two scenarios:

- **A. Portable migration** — moving home-stack to a new macOS host, VM, or container.
- **B. Upgrading an existing installation** — bringing a host with running pre-Phase-1 home-stack services up to the Phase 1 (Profiles & Portability) model in place.

## Key Concepts

- Profile (mandatory): identity values live in `profiles/<name>/home-stack.env`. The loader fails fast and lists every missing mandatory var.
- Machine-local non-secret override (optional): `~/.config/home-stack/config.env`.
- Secrets: `~/.config/home-stack/env.local`. Identity keys are forbidden here.
- Generated artifacts (Caddyfile, catalog.json, launchd plists under `portable/home-stack/`) are gitignored; the engine regenerates them from the active profile on every `hs sync`.
- Mandatory variables: HOME_STACK_PARENT_DOMAIN, HOME_STACK_TAILNET_IP, HOME_STACK_ACME_EMAIL, HOME_STACK_OWNER_HOME, HOME_STACK_IDENTIFIER_PREFIX, HOME_STACK_ADMIN_USERNAME.

---

## A. Portable Migration (new host)

1. **Clone the repo** on the target host:
   ```bash
   git clone <remote-url> ~/github/home-stack
   ```

2. **Build Caddy** (with DNS-01 plugin) and the admin binary:
   ```bash
   cd ~/github/home-stack/portable/home-stack/admin
   go build -o home-stack-admin .
   cd -
   # Caddy is installed separately via Homebrew or the official binary with xcaddy
   ```

3. **Initialise your profile** (creates or validates `profiles/<name>/home-stack.env`):
   ```bash
   portable/home-stack/scripts/hs init <name>
   ```
   Fill in all six mandatory variables in the generated `profiles/<name>/home-stack.env`. Do not put identity keys in `env.local`.

4. **Populate secrets** in `~/.config/home-stack/env.local`:
   ```bash
   HOME_STACK_ADMIN_PASSWORD=<password>
   HOME_STACK_CLOUDFLARE_API_TOKEN=<token>
   ```

5. **Run doctor** to confirm the env contract is satisfied:
   ```bash
   portable/home-stack/scripts/hs doctor
   ```
   Resolve every `[!]` line before proceeding.

6. **Sync** to regenerate Caddyfile, catalog.json, and launchd plists:
   ```bash
   portable/home-stack/scripts/hs sync
   ```

7. **Install launchd services**:
   ```bash
   portable/home-stack/scripts/install-launchd.sh
   ```

8. **Verify**:
   ```bash
   portable/home-stack/scripts/hs status
   portable/home-stack/scripts/hs doctor
   ```
   Browser checks: `https://portal.<parent_domain>/`, `https://opencode.<parent_domain>/`, `https://admin.<parent_domain>/`.

If the namespace changes (different parent_domain), the profile drives all generation; TLS reissuance happens automatically via Caddy DNS-01.

---

## B. Upgrading An Existing Local Installation

This procedure assumes:
- You already have home-stack running on this machine via launchd (Caddy daemon + Admin/OpenChamber/OpenCode/logrotate user agents).
- Your `profiles/<name>/home-stack.env` has the new mandatory variables (Phase 1 added them).
- Your `~/.config/home-stack/env.local` already contains `HOME_STACK_ADMIN_PASSWORD` and `HOME_STACK_CLOUDFLARE_API_TOKEN`.

If those assumptions don't match, run `hs init` against your profile first or hand-edit the profile to satisfy the contract.

### Pre-flight (read-only)

```bash
# 1. Validate the new contract before touching the live system.
portable/home-stack/scripts/hs doctor
```

`hs doctor` runs even when the profile is incomplete. It will tell you exactly what is missing. Resolve every `[!]` line before proceeding.

```bash
# 2. Confirm env.local does NOT contain identity keys (the loader will reject them).
grep -E "^[[:space:]]*HOME_STACK_(PARENT_DOMAIN|TAILNET_IP|ACME_EMAIL|OWNER_HOME|IDENTIFIER_PREFIX|ADMIN_USERNAME)=" ~/.config/home-stack/env.local || echo "env.local is clean"
```

If any identity key appears, move it into `profiles/<name>/home-stack.env` and remove it from env.local.

### Build

```bash
# 3. Build the admin binary. `hs sync` invokes its `sync` subcommand locally.
cd portable/home-stack/admin
go build -o home-stack-admin .
cd -
```

The admin launchd wrapper (`run-admin.sh`) builds its own copy of the binary into `/tmp/home-stack-admin` on every restart, so this build is for the CLI's `hs sync`, not for the running admin service.

### Sync (regenerate artifacts)

```bash
# 4. Regenerate Caddyfile, catalog.json, and launchd plists from your active profile.
portable/home-stack/scripts/hs sync
```

For your profile, the regenerated content should be byte-equivalent to what was previously checked in (same parent_domain, same identifier_prefix, same owner_home). To verify, you can `git diff` against the pre-Phase-1 versions in git history.

### Reload running services

```bash
# 5. Reload Caddy with the regenerated Caddyfile.
portable/home-stack/scripts/hs reload caddy

# 6. Restart admin so it picks up the new validateEnv() and the new env layering.
portable/home-stack/scripts/hs restart admin
```

The admin's launchd wrapper calls `home_stack_load_env`, which now validates mandatory vars before launching the Go binary. If admin fails to start, the launchd stderr log under `~/.config/home-stack/logs/admin.launchd.err.log` will name the offending variables.

### Optional: refresh installed launchd plists

If you want the installed plists in `~/Library/LaunchAgents/<prefix>.home-stack.*.plist` (and the daemon plist at `/Library/LaunchDaemons/<prefix>.home-stack.caddy.plist`) to match the regenerated set, reinstall:

```bash
portable/home-stack/scripts/install-launchd.sh
```

This does not start services; existing services keep running because the labels match (`<prefix>.home-stack.*` prefix is unchanged). If a plist's content changed (e.g. a new env var was added), launchd picks it up on next bootstrap.

### Verify

```bash
portable/home-stack/scripts/hs status
portable/home-stack/scripts/hs doctor
bash tests/profile-portability.test.sh   # asserts engine works against a fixture profile distinct from the maintainer's own
```

Browser checks: `https://portal.<parent_domain>/`, `https://opencode.<parent_domain>/`, `https://admin.<parent_domain>/`.

### Rollback

If anything breaks:

- **Admin won't start** — check `~/.config/home-stack/logs/admin.launchd.err.log`. Most common cause: a mandatory var is missing in `profiles/<name>/home-stack.env`. Fix the profile and `hs restart admin`.
- **Caddy won't reload** — re-run `hs sync` and `hs reload caddy`. If still failing, check `~/.config/home-stack/logs/caddy.launchd.err.log` and validate the Caddyfile manually with `caddy adapt`.
- **CLI complains about missing profile** — run `hs doctor` to see what is missing.
- **Need to revert wholesale** — `git stash` or check out a pre-Phase-1 commit; the live system continues running on the previously-rendered Caddyfile and installed plists since they're now untracked.

### Permanent cleanup of stale tracked artifacts

Phase 1 untracked the previously-committed `portable/home-stack/Caddyfile`, `portable/home-stack/catalog.json`, and `portable/home-stack/launchd/<prefix>.home-stack.*.plist`. After running `hs sync` the regenerated copies sit on disk but are gitignored. The first commit on the post-Phase-1 branch will record the deletions.

---

## Verifying The Contract End-To-End

```bash
# Drives an `acme` fixture profile (distinct from the maintainer's own) through the engine and asserts no maintainer-specific strings leak.
bash tests/profile-portability.test.sh
```

Expected: `PASS profile-portability.test.sh`.

## Crucial Security Step (macOS SSH)

If using macOS native "Remote Login" instead of `tailscale up --ssh`, you MUST edit `/etc/ssh/sshd_config` on the new host to bind `ListenAddress` to its new Tailscale IP (`100.x.y.z`); otherwise the SSH server will fail to start. Ensure your SSH keys are installed in `~/.ssh/authorized_keys` before disabling password auth.
