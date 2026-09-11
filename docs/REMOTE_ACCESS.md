# Remote Access (Phase D)

Status: designed 2026-09-04, not implemented, **parked** (2026-09-05): build
it the week an app needs to be reached from a machine that cannot run
Tailscale. Prerequisite when that day comes: P2 in `docs/ROADMAP.md`. Supersedes the outline in the
2026-04-27 decision row (same shape, now with a registry contract, an
identity choice, and origin verification).

## 1. Requirement

Reach chosen web apps from a browser on a machine where nothing can be
installed — a work or public computer — such that:

- no reusable secret is ever typed on that machine;
- unauthenticated traffic never reaches the Mac;
- the experience is one URL, one sign-in, one click;
- nothing changes for the tailnet lane.

## 2. Decision

**Cloudflare Tunnel + Cloudflare Access.** Evaluated and rejected:

| Option | Why not |
|---|---|
| ngrok | Custom domain, auth gating and traffic policy need the $20+/mo tier; a second vendor in the trust path; ngrok domains are widely blocked by corporate web filters because of documented malware abuse — the exact place this lane is for. Fine as a hand-run dev tool outside the stack. |
| Tailscale Funnel | No authentication at the edge — every request reaches Caddy and tinyauth becomes the only gate; `*.ts.net` names only; bandwidth caps. Kept as a one-off share recipe in the RUNBOOK, not a lane. |
| Self-hosted edge (Pangolin, a VPS with Caddy + `forward_auth`) | A VPS to operate and defend; more moving parts. Only worth it if Cloudflare seeing plaintext is unacceptable, which it is not for the apps in scope. |
| Client-based ZTNA (Tailscale, WARP, Twingate, NetBird) | Requires a client on the accessing machine. Out by requirement. |
| Browser remote desktop | Hands the whole machine to an untrusted browser. |

### Identity for the external lane

Federating Access to Pocket ID would require Pocket ID to be reachable from
the public internet — the IdP must serve the login page to the off-tailnet
browser — adding a public login surface to the Mac to gain "one identity".

- **D.1 (build this):** Access's own methods only — one-time PIN to email plus
  GitHub or Google as a hosted, passkey-capable IdP. Zero new surface on the
  Mac. Both are single-use or phishing-resistant, so a monitored work computer
  never sees a reusable secret.
- **D.2 (optional, later):** expose Pocket ID through the tunnel *ungated* and
  register it as an Access OIDC IdP, only if a single passkey identity across
  both perimeters turns out to matter. Open decision.

## 3. Contract

### Profile (optional; defaults shown)

| Variable | Default | Notes |
|---|---|---|
| `HOME_STACK_REMOTE_DOMAIN` | `remote.${HOME_STACK_PARENT_DOMAIN}` | remote hostnames are `<name>.<remote domain>` |
| `HOME_STACK_REMOTE_ORIGIN_PORT` | `31530` | Caddy loopback listener for the tunnel |
| `HOME_STACK_ACCESS_TEAM_DOMAIN` | — | `<team>.cloudflareaccess.com`; required when any service sets `remote:` |
| `HOME_STACK_CLOUDFLARE_TUNNEL_ID` | — | tunnel UUID; non-secret |

### Secrets

Service-private (`docs/SECURITY_MODEL.md` → Service-private secrets), **not** in
`env.local`: `~/.config/home-stack/cloudflared/<uuid>.json`, mode 0600. The
DNS-scoped `HOME_STACK_CLOUDFLARE_API_TOKEN` is used only by the operator-run
`hs remote route` helper; `cloudflared` never sees it.

### Registry

Closed enums, fixed blocks — the `auth:` / `proxy_identity:` idiom.

```yaml
  someapp:
    subdomain: someapp
    auth: tailnet-or-sso       # tailnet lane, unchanged
    remote: access             # omitted | none | access
    remote_aud: "a1b2…"        # Access application AUD tag (non-secret); required with access
```

Validation rejects `remote: access` when: the service has no `subdomain`/
`host`; `kind` is `control`, `agent`, `auth`, `backend`, or `ingress` (Admin,
Hermes, Pocket ID, tinyauth, OpenCode, Caddy, dev-gateway — a deny-by-kind
mirroring the native-protocol prohibition); `proxy_identity: upstream` is set;
`enabled: false`; `remote_aud` is missing; `HOME_STACK_ACCESS_TEAM_DOMAIN` is
unset.

## 4. Components

### `cloudflared` (managed service)

Registry entry with `lifecycle: managed`, `type: proxy`, no subdomain (the
`opencode` shape, so it gets `KeepAlive`), `kind: tunnel`. Homebrew binary;
args `tunnel --config ~/.config/home-stack/cloudflared/config.yml run
--metrics 127.0.0.1:20241`. Wrapper `run-cloudflared.sh` sets
`HOME_STACK_SKIP_ENV_LOCAL=1` and a minimal allowlisted environment. Health:
`http_url: http://127.0.0.1:20241/ready` — confirm the path against current
cloudflared docs before wiring.

The engine writes `~/.config/home-stack/cloudflared/config.yml` on sync,
gitignored like the Caddyfile:

```yaml
tunnel: <uuid>
credentials-file: /Users/<owner>/.config/home-stack/cloudflared/<uuid>.json
metrics: 127.0.0.1:20241
ingress:
  - hostname: someapp.remote.home.example.com
    service: http://127.0.0.1:31530
    originRequest: { httpHostHeader: someapp.remote.home.example.com }
  - service: http_status:404
```

### `access-verify` (managed service)

A ~120-line Go service on `127.0.0.1:31531`, no subdomain, `kind: auth`.
`GET /verify`:

1. reads `Cf-Access-Jwt-Assertion`;
2. validates the signature against
   `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs` (cached;
   tolerant of the 7-day rotation overlap);
3. checks `iss` == the team domain, `exp`, and `aud` ∈ the set passed by the
   Caddy block as `X-Home-Stack-Remote-Aud`;
4. returns 200 with `X-Webauth-Email` from the `email` claim, else 401.

Rejected alternative: embedding this in Admin. Admin is the privileged control
plane and must not sit in the path of public requests, even loopback ones.

### Engine emission — one fixed block per remote service

```
http://someapp.remote.home.example.com {
    bind 127.0.0.1
    forward_auth 127.0.0.1:31531 {
        uri /verify
        header_up X-Home-Stack-Remote-Aud "a1b2…"
        copy_headers X-Webauth-Email
    }
    request_header -X-Webauth-User
    request_header -Remote-User
    reverse_proxy 127.0.0.1:<port>
}
```

Plus a global `servers 127.0.0.1:31530 { trusted_proxies static 127.0.0.1/32 }`
so `X-Forwarded-For` from cloudflared is honoured.

Why plain HTTP on loopback: the tunnel is encrypted edge→agent, and the
agent→Caddy hop never leaves the host; issuing a `*.remote` certificate for a
hop nobody else can observe adds a DNS-01 order for no security. The block
strips the tailnet lane's identity headers and forwards only the email Access
verified, so an upstream cannot confuse the two lanes.

## 5. Access side (operator-run, RUNBOOK)

1. Create the Zero Trust team domain.
2. Login methods: one-time PIN; GitHub (or Google).
3. One Access Application per remote hostname; policy: allow `email == <you>`;
   session duration 8 h. Copy each AUD into `remote_aud:`.
4. Enable the App Launcher, restricted to the same policy — this is the one
   URL to remember.
5. `hs remote route <service>` wraps `cloudflared tunnel route dns <uuid>
   <host>` with the DNS-scoped token, idempotently; `hs remote unroute`
   reverses it.

`hs doctor` gains a section: cloudflared binary and version; config present
and equal to what sync would generate; credentials file mode 0600; tunnel id
set; `ready` endpoint; certs URL reachable; every `remote: access` service has
an AUD and a resolving CNAME; no remote on denied kinds.

## 6. Tests

- Engine goldens for a fixture with two remote services: the remote blocks,
  the cloudflared config, the global `trusted_proxies`; non-remote output
  byte-identical to the current golden.
- The full validation table above, one rejection per test.
- Portability scan extended to the generated cloudflared config.
- `access-verify` unit tests with a local JWKS: good, expired, wrong `aud`,
  wrong `iss`, `alg: none`.
- Wrapper test proving cloudflared's environment carries no `HOME_STACK_*`
  variable and no API token.
- Linux-tier test: `hs doctor` fails when a remote service lacks an AUD.

## 7. Acceptance

- From a browser with no Tailscale: App Launcher → OTP or GitHub passkey →
  tile → app loads.
- `curl https://someapp.remote.<parent>` with no session → Access login (302);
  never a response from the Mac.
- A forged `Cf-Access-Jwt-Assertion` sent straight to `127.0.0.1:31530` → 401
  from `access-verify`.
- The Caddyfile for non-remote services is byte-identical (golden).
- `hs doctor` green; Admin shows `cloudflared` and `access-verify` healthy;
  Access logs show the login.

## 8. Rollback

`remote: none` → `hs deploy --apply` removes the block, rewrites the config to
the 404 catch-all, restarts cloudflared. `hs service stop cloudflared`
removes the public path entirely. CNAMEs may stay (they 404 at the edge) or go
via `hs remote unroute`.

## 9. Non-goals

- Remote Admin — never (`kind: control`).
- Remote Hermes — never (native-protocol exception).
- TCP or SSH through the tunnel — Tailscale covers it.
- Tailscale Funnel as a general lane — RUNBOOK one-off share recipe only.

## 10. Verification ledger

Verified from Cloudflare's documentation on 2026-09-04: one-time PIN login and
its coexistence with other IdPs; the App Launcher; JWT validation via
`/cdn-cgi/access/certs` with `iss`/`aud` checks. Not yet verified: the Zero
Trust free-tier seat count (only matters above one user); cloudflared's
`/ready` metrics path.
