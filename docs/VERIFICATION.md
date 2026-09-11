# Verification

Last updated: 2026-09-10

Use this checklist before claiming changes are complete, before merging, and after
operational changes. Run the relevant commands fresh and read their output.

## Documentation-Only Changes

- Check changed files:

```bash
git diff --stat
git diff -- README.md docs AGENTS.md CHANGELOG.md
```

- Search for stale status language:

```bash
grep -R "Source-of-truth plan\|OLED Stealth\|Ready for implementation\|fully declarative\|Added /api/sync\|Phase E\|unregistered Admin" README.md docs AGENTS.md CHANGELOG.md --exclude-dir=attic
```

Expected: matches should be historical/superseded context only, not current claims.

## Shell And Script Checks

```bash
bash -n portable/home-stack/scripts/lib/common.sh
bash -n portable/home-stack/scripts/run-opencode.sh portable/home-stack/scripts/run-openchamber.sh portable/home-stack/scripts/run-hermes.sh portable/home-stack/scripts/run-caddy.sh
bash -n portable/home-stack/scripts/status-launchd.sh portable/home-stack/scripts/service-launchd.sh
bash tests/hermes-wrapper.test.sh
```

The Hermes wrapper test must prove that required dashboard/OIDC values reach
the fake process while unrelated sentinel credentials, ambient variables, and
all `HOME_STACK_*` names do not.

## launchd Checks

```bash
plutil -lint portable/home-stack/launchd/*.plist portable/home-stack/launchd/daemons/*.plist
portable/home-stack/scripts/status-launchd.sh
portable/home-stack/scripts/status-launchd.sh --json
portable/home-stack/scripts/status-launchd.sh --verbose
```

## Caddy Checks

```bash
CLOUDFLARE_API_TOKEN=dummy portable/home-stack/bin/caddy-cloudflare adapt --config portable/home-stack/Caddyfile
portable/home-stack/scripts/caddy-status.sh
```

If applying config changes, reload and re-check:

```bash
portable/home-stack/scripts/reload-caddy.sh
portable/home-stack/scripts/caddy-status.sh
```

## Admin Checks

Admin backend tests:

```bash
cd portable/home-stack/admin
go test ./...
```

Safety tests from repo root:

```bash
bash tests/admin-safety.test.sh
bash tests/status-launchd.test.sh
env -u HOME_STACK_COMMON_SH_LOADED \
  -u HOME_STACK_BUNDLE_DIR \
  -u HOME_STACK_REPO_ROOT \
  -u HOME_STACK_TEMPLATE_DIR \
  -u HOME_STACK_CONFIG_DIR \
  -u HOME_STACK_ENV_FILE \
  -u HOME_STACK_CLOUDFLARE_API_TOKEN \
  -u CLOUDFLARE_API_TOKEN \
  bash tests/env-safety.test.sh
bash tests/profile-portability.test.sh
```

## Profile Portability Check

```bash
# Drives an `acme` fixture profile (distinct from the maintainer's own)
# through the engine and asserts zero maintainer-specific strings leak into
# generated artifacts.
bash tests/profile-portability.test.sh
```

Expected: `PASS profile-portability.test.sh`.

## Live Smoke Checks

Without printing secrets:

- `https://admin.<your-domain>/` unauthenticated should return `401 Unauthorized`.
- Authenticated `/api/overview` should return JSON with `ok: true` when the stack is healthy.
- `POST /api/actions` should require Basic Auth and mutation header.

## Portal Projection Checks

After Portal or Home Stack projection changes:

```bash
npm --prefix ../home-portal run check:schema-sync
cd portable/home-stack/admin && go test ./...
cd ../../..

curl -fsS https://portal.<your-domain>/.well-known/home-stack/catalog.json | jq -e '.schema_version == 1 and (.services | type == "array")'
curl -fsS https://portal.<your-domain>/.well-known/home-stack/status.json | jq -e '.schema_version == 1 and (.services | type == "object")'
```

Confirm Hermes is launchable at its routed HTTPS URL, every registry service is
represented, and headless/task services are present but not rendered as broken
links. Recursively audit both documents for forbidden keys including `upstream`,
`root`, `working_dir`, `binary`, `args`, `env`, `pid`, `target`, `details`,
`actions`, and credential-shaped names. The Admin-host versions of both
well-known paths must return `404`; unauthenticated `/api/services` must still
return `401`.

In a browser, verify desktop plus 390px and 430px viewports: no horizontal
overflow; Hermes and newly discovered services appear; search, favorites,
details, keyboard focus, and full-card launch targets work; malformed/offline/
stale states are disclosed; manifest and service worker load; sample services
never appear in production.

## DNS, TLS, And Proxy Checks

- Wildcard DNS `*.<your-domain>` should point to the Tailnet IP.
- Caddy should issue TLS via DNS-01 Cloudflare.
- OpenCode should not be browser-exposed directly.
- OpenChamber should be reachable through `https://opencode.<your-domain>/`.
- OpenChamber should receive Caddy's default `X-Forwarded-Proto` and `X-Forwarded-Host` headers for passkeys and WebSocket origin checks.

## Hermes Repository Checks

```bash
cd portable/home-stack/admin && go test ./...
cd ../../..
bash tests/hermes-wrapper.test.sh
bash tests/env-safety.test.sh
bash tests/engine-snapshot.test.sh
make test
```

Confirm the generated Hermes plist points only to
`portable/home-stack/scripts/run-hermes.sh`, contains no credential values, and
passes `plutil -lint`. Confirm the generated Caddy route targets the profile's
literal Tailnet IP and emits the fixed upstream Host/Origin identity block.

## Hermes Live Deployment Checks

Run these after every installation, upgrade, auth rotation, or routing change.

- `command -v hermes` resolves under `~/.local/bin`, and `hermes --version` is recorded.
- `lsof -nP -iTCP:31511 -sTCP:LISTEN` shows only the exact Tailnet IP—never `0.0.0.0`, `127.0.0.1`, or a LAN address.
- `launchctl print gui/$(id -u)/<identifier-prefix>.home-stack.hermes` reports a running PID and expected wrapper.
- Hermes logs contain no credentials and show a gated non-loopback start.
- The public status probe proves native auth is active:

```bash
curl -fsS "http://${HOME_STACK_TAILNET_IP}:${HOME_STACK_HERMES_PORT}/api/status" \
  | jq -e '.auth_required == true and (.auth_providers | index("basic") != null)'
```

- An unauthenticated protected endpoint such as `/api/sessions` returns `401` or the documented login response; it must not return session data.
- `https://hermes.<your-domain>/api/status` succeeds over the Tailnet and reports the same auth state.
- Login, session listing, and chat WebSocket streaming work through Caddy.
- Admin lists Hermes and offers registry-derived start/stop/restart operations.
- Restart Hermes and confirm the authenticated session and conversation history persist.
- OpenCode, OpenChamber, Admin, and Caddy remain healthy after the change.
- The intended iPhone client signs in with username/password, resumes an existing CLI/Desktop session, and streams a new turn.
- Verify no public DNS/Tunnel/port-forward rule exposes Hermes.
- `git diff` and `git status --short` contain no secrets, generated runtime artifacts, Hermes state, logs, or unrelated changes.

## Hermes Gateway Checks

- `hermes gateway status` reports the default profile running under launchd,
  with no stale definition or respawn storm.
- `plutil -lint ~/Library/LaunchAgents/ai.hermes.gateway.plist` passes.
- The plist executes the managed Python module with `gateway run --replace`,
  uses `~/.hermes` as its working directory, and its environment key set is
  exactly `HERMES_HOME`, `PATH`, and `VIRTUAL_ENV`.
- `launchctl print gui/$(id -u)/ai.hermes.gateway` reports a running PID;
  stopping and starting through `hermes gateway` drains and returns cleanly.
- With no platform configured, gateway logs say zero channel targets and no
  messaging listener appears. If a platform is later added, prove an unknown
  sender is denied and only the reviewed user/account can start a session.
- The dashboard `/api/status` reports `gateway_running: true`,
  `gateway_state: running`, and `gateway_mode: single`; there remains exactly
  one gateway process, and dashboard restart does not create a duplicate. The
  legacy/nonexistent `.gateway` object is not the status contract.
- Zero cron jobs remain zero after restart. Any future job requires its own
  trigger, delivery, idempotency, timeout, model-cost, and mutation review.
- Gateway logs, plist, process environment, and git diff contain no credential
  values or Home Stack secrets.

## Replayability Check

This should not delete app data, project directories, `env.local`, logs, or certs.

```bash
portable/home-stack/scripts/uninstall-launchd.sh --unload
portable/home-stack/scripts/status-launchd.sh
portable/home-stack/scripts/install-launchd.sh
portable/home-stack/scripts/install-launchd.sh --load
portable/home-stack/scripts/status-launchd.sh
```

## Rollback Notes

- For failed Caddy config changes: restore the registry/source change, run `hs sync`, validate the generated Caddyfile, and reload.
- For failed Caddy binary upgrades: restore `portable/home-stack/bin/caddy-cloudflare.prev` and restart Caddy.
- For failed launchd changes: unload the affected service, restore the registry/source, regenerate, reinstall the reviewed plist set, and load/start intentionally.
- For failed DNS/TLS changes: revert DNS and the registry/source change, regenerate the Caddyfile, and restart/reload services as appropriate.
- For failed Portal projections: restore the prior Admin/engine source and Portal `dist`, rebuild Admin, run `hs sync`, restart Admin, and repeat the exact-path/auth checks. Do not patch generated JSON or Caddy output by hand.
