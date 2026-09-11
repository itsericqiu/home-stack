# Portable Home Stack Bundle

This directory contains the portable service bundle intended to be moved to another host.
It should be moved with its templates and runtime scripts, while secrets remain on the host.

## Usage
- Render the final Caddyfile using render-caddyfile.sh with templates.
- Start OpenCode and OpenChamber using the included run scripts or LaunchAgents.
- Ensure ~/.config/home-stack/env.local is present on the new host and contains the required secrets.
- Use `scripts/install-launchd.sh` to install plist files without starting services.
- Use `scripts/install-launchd.sh --load` only when ready to start launchd-managed services.
- Use `scripts/uninstall-launchd.sh --unload` to stop services and remove home-stack plist files without deleting app data.
- Launchd setup includes `<prefix>.home-stack.logrotate` (named from `HOME_STACK_IDENTIFIER_PREFIX`) for hourly log rotation.
- Use `scripts/oc` and `scripts/occ` to attach local OpenCode TUI sessions to `127.0.0.1:31496` from the current directory.
- Use `scripts/install-helpers.sh --with-ops` to install `oc`, `occ`, plus `hs` and `hs-status` convenience links.
- Override `HOME_STACK_OWNER_HOME` when installing for a different macOS user; scripts derive the bundle path from their own location.

## Script Groups
- `scripts/lib/common.sh`: shared defaults for owner home, config dir, logs, pids, TLS, ports, and rendering.
- `scripts/run-*.sh`: launchd foreground wrappers.
- `scripts/start-*.sh` and `scripts/stop-phase-*.sh`: local Phase A/B harness only.
- `scripts/render-caddyfile.sh`: renders Caddyfile templates into this bundle.
- `scripts/install-launchd.sh`, `scripts/status-launchd.sh`, `scripts/uninstall-launchd.sh`: launchd lifecycle helpers.
- `scripts/service-launchd.sh`: per-service launchd control (start/stop/restart/status).
- `scripts/rotate-logs.sh`: size-based log rotation for `~/.config/home-stack/logs`.
- `scripts/oc`, `scripts/occ`: optional OpenCode TUI convenience helpers.
- `scripts/install-helpers.sh`: symlink `oc`/`occ` into `~/bin`, optionally install `hs`/`hs-status`, and optionally update `.zshrc` PATH.

## Data Boundary
- This bundle should not contain OpenCode databases, OpenChamber settings, project source code, or secrets.
- OpenCode and OpenChamber use their normal user-level config/data directories by default.
- Home-stack-specific secrets and operational files live under `$HOME_STACK_OWNER_HOME/.config/home-stack/`.
