# Home Stack — Plan Audit and Forward Spec

Last updated: 2026-09-10

A coherence audit of every planned workstream against implementation truth, the re-sequenced plan that came out of it, and the specifications each workstream follows. `docs/ROADMAP.md` carries the sequence; this file carries the reasoning and the detail. Re-run §1 when a workstream lands.

Audited at: `feat/tailnet-identity-layer` (24 commits ahead of `main`, merged as #2 and tagged `v0.1.0` the same day) plus the first tenant app's design branch, which has since moved to its own repository. P0 and P1 in §2 are done; findings marked *(fixed in P1)* are resolved by the doc-reconciliation PR this file landed in.

Sources read in full: README, AGENTS, CHANGELOG, GOVERNANCE, INDEX, STATUS, ROADMAP, ARCHITECTURE, SECURITY, SERVICE_INTERFACE, HERMES_OPERATING_MODEL, DECISIONS_LOG, the first tenant app's design (now in its own repository's docs), a real profile's files, `scripts/hs`, `scripts/lib/common.sh`, `Makefile`; headings of RUNBOOK, VERIFICATION, MIGRATION.

---

## 0. Executive summary

The stack's *implemented* core is in good shape and its security model is coherent. The *planning layer* has drifted: `docs/ROADMAP.md` still presents four priorities that `docs/STATUS.md` records as done, README contradicts STATUS in two places, three documents disagree about whether Admin's Basic Auth should be retired, and a set of profile feature flags is dead code that reads as live configuration. The first tenant app's branch was written against `main` and carries three assumptions this branch already invalidated. None of this is dangerous; all of it will confuse the next agent that reads the docs before acting — which is exactly what `INDEX.md` tells agents to do.

Three findings are more than documentation:

1. **`make test` overwrites the production Admin binary** (Makefile `test` target builds `home-stack-admin` at its persistent path). On a feature branch this installs branch code into the path launchd resolves on next restart.
2. **Feature flags don't gate anything.** `HOME_STACK_ENABLE_DEV_GATEWAY=false` sits in the profile while the engine generates and installs the dev-gateway LaunchAgent regardless.
3. **Phase D (remote access) has no registry contract.** The engine's closed-enum discipline (`auth:`, `proxy_identity:`) is the right idiom, but no field, enum, or Caddy block is defined for `.remote.` routes, and `HOME_STACK_REMOTE_DOMAIN` exists only in the ROADMAP's variable table.

Order: (P0, done) merge and tag → (P1, done) one doc-reconciliation PR → (P1′) onboard the first tenant app → (P2) registry `enabled:` + finish `deploy.apply` → (P3) Phase D per `docs/REMOTE_ACCESS.md` → then dev gateway, upgrade tooling, Admin polish, Hermes stages.

---

## 1. Findings

Severity: **H** = will cause a wrong action or a security/ops hazard; **M** = contradiction an agent must resolve before acting; **L** = tidy-up.

### 1A. Branch and process

| # | Sev | Finding | Fix |
|---|---|---|---|
| 1 | M (was H — see §3.8) | The first tenant app's branch is based on `main`, 24 commits behind this branch, and its plan encodes stale state: "No auth exists on main" (its design doc §3 Control surface); Phase 4.1 says the running `hermes gateway` "is not in the registry; either register it or stop it" and to record the version drift — both already decided on this branch (DECISIONS_LOG 2026-08-12: gateway is app-owned by design; STATUS: the pinned Hermes checkout is installed and verified). | Merge `feat/tailnet-identity-layer` first. Rebase the tenant-app branch. Rewrite its Phase 4.1 to cite the app-owned-gateway decision instead of re-opening it; ship `auth: tailnet` in Phase 1, not "when the identity branch merges". |
| 2 | M | `CHANGELOG.md` "Unreleased" spans April→August with ~25 bullets and no tag has ever been cut; GOVERNANCE promises "semantic-ish versioning" and tags. | Tag `v0.1.0` at the merge of this branch; start a dated `## 0.1.0 — 2026-09-xx` section. Future: one tag per merged workstream. |
| 3 | H | `make test` builds the production admin binary in place (`Makefile:40`). Tests run on the live host on a feature branch leave branch code at the path launchd resolves. The first tenant app's design doc §5 already carries the workaround ("restore it from main afterwards") — a guardrail that exists because of a Makefile bug. | Build test binaries to `portable/home-stack/admin/.test-build/` (gitignored); have `tests/*.sh` use `HOME_STACK_ADMIN_BIN` override; only `make build-admin` (explicit) writes the production path. Delete that workaround once done. |

### 1B. Documents contradicting STATUS (stale)

| # | Sev | Finding | Fix |
|---|---|---|---|
| 4 | M | README "Current Gaps" (`README.md:198`): "deploy apply-flow through typed actions is preview-only". STATUS: `deploy.apply` is implemented via `/api/actions`, with the honest partial that it does not install/restart LaunchAgents. | README → "deploy apply regenerates and reloads Caddy but does not yet converge launchd; see STATUS". |
| 5 | M | README "What You Get" (`README.md:28`): Admin is "Basic-Auth'd". Actual: `auth: tailnet-or-sso` at the ingress, Basic retained as second factor/break-glass. | Reword. |
| 6 | H | ROADMAP Near-Term Priorities 1–4 (Profiles & Portability, `hs sync`/`hs app add` repair, action descriptors, deploy preview→apply) are recorded as done in STATUS, except descriptors. ROADMAP also carries ~190 lines of "binding" Phase 1 design notes for work that shipped in May. "Last updated 2026-08-12" is misleading — the content is May's. | Move "Phase 1 Design Notes" to `docs/attic/specs/2026-05-02-profiles-portability.md`. Rewrite Near-Term Priorities per §2 below. |
| 7 | H | Three documents disagree about Admin Basic Auth. ROADMAP Admin workstream: "Retire Admin's Basic Auth in favour of the identity layer once root-side WhoIs is confirmed." SECURITY `Admin Control Plane` §2: "Do not remove it: Admin is the tool used to repair a broken identity layer." STATUS: WhoIs is confirmed (admin gate "verified live"). | Delete the ROADMAP bullet. SECURITY is right. If the goal was UX, the correct item is "stop *prompting* for Basic on the browser lane when ingress identity is present" — which STATUS says already happens. |
| 8 | L | A real profile's `services.yaml` dev-gateway comment: "Opt Admin in only after the root-side WhoIs check … passes." Admin is already opted in (line 24). | Replace comment with the actual reason `dev-gateway` is `auth: tailnet` (lowest-stakes route). |
| 9 | M | `docs/INDEX.md` (last updated 2026-05-02) omits HERMES_OPERATING_MODEL, GOVERNANCE, DEVTOOLS_TLS, SESSION_TEMPLATE, CONTRIBUTING, and the incoming first tenant app's design doc. README's repository map omits HERMES_OPERATING_MODEL, DECISIONS_LOG, MIGRATION. `INDEX` is the file agents are told to start from. | Regenerate both maps; add a one-line "purpose" per doc; add an `## Active specs` section pointing at the tenant app's design doc and (after §3.4) REMOTE_ACCESS. |
| 10 | L | `AGENTS.md` (2026-08-08) does not mention the two rules added since: the agent-environment allowlist (SERVICE_INTERFACE §2) and the launchd race rules (`home_stack_wait_label_gone`, kickstart-vs-bootout). Both are exactly the kind of thing an agent will get wrong. | Add a "Runtime rules you will otherwise violate" list of four bullets. |

### 1C. Configuration contract

| # | Sev | Finding | Fix |
|---|---|---|---|
| 11 | H | `HOME_STACK_ENABLE_*` flags (`OPENCODE`, `OPENCHAMBER`, `LOGROTATE`, `CLOUDFLARE_TUNNEL`, `APP_REGISTRY`, `DEV_GATEWAY`) are set in the profile, listed in the ROADMAP variable contract as "feature toggles", and read by **nothing** in `admin/*.go`, `scripts/*.sh`, or `lib/common.sh` (grep-verified). README:39 admits it in a subordinate clause. `dev-gateway` is generated and installed with the flag `false`. | Registry is the toggle. Add `enabled: false` (§3.2), delete the six flags from both profiles and `templates/profile.env.example`, drop the row from the variable contract. |
| 12 | M | `HOME_STACK_REMOTE_DOMAIN` appears in the ROADMAP contract and nowhere in code; `remote_access: true` is listed in STATUS "Not Implemented" but is defined in no spec. `HOME_STACK_DEV_DOMAIN` is exported by `common.sh` but the engine derives `*.dev` from the registry `subdomain: "*.dev"`, so the variable is a second source of truth. | §3.4 defines the remote contract. Retire `HOME_STACK_DEV_DOMAIN`; the registry composes it. |
| 13 | M | `HOME_STACK_POCKET_ID_SUBDOMAIN=id` / `HOME_STACK_TINYAUTH_SUBDOMAIN=auth` in the profile duplicate `subdomain: id` / `subdomain: auth` in the registry. Wrappers (`run-pocket-id.sh:38`, `run-tinyauth.sh:37,80`, `run-hermes.sh:71`) build issuer/app URLs from the env copy with `:-id`/`:-auth` fallbacks. Change one and the other silently disagrees; the fallbacks are exactly the "silent substitution" the 2026-05-02 decision banned. | Engine injects `HOME_STACK_SELF_HOST=<rendered FQDN>` into every managed service's generated plist environment (it already knows the FQDN). Wrappers read that; profile vars and fallbacks go. `hs doctor` check: wrapper-derived URL == registry-rendered FQDN. |
| 14 | L | `HOME_STACK_PHASE_A_CADDY_PORT` / `PHASE_B_CADDY_PORT` defaults survive in `common.sh:37-38` and its export list, though every phase-era script was deleted (CHANGELOG "Removed dead phase-era scripts"). | Delete. |
| 15 | L | ROADMAP variable contract says `HOME_STACK_BIN_DIR` default `${OWNER_HOME}/bin`. | Verified: `common.sh:175` agrees. Closed. |

### 1D. Architecture and security coherence

| # | Sev | Finding | Fix |
|---|---|---|---|
| 16 | H | Phase D will contradict three absolute statements: README:55 "nothing is ever served through Cloudflare"; README:57 "All exposure is Tailnet-only"; ARCHITECTURE:45 / SERVICE_INTERFACE:20 "Cloudflare Tunnel routes remain prohibited" (stated for the native-protocol exception but reads as global). SECURITY "Network Exposure" has no external-perimeter section at all. | Reword to "by default"; add SECURITY §"External perimeter (Phase D)" from §3.4; keep the *native-protocol* prohibition absolute (Hermes never gets a remote route). |
| 17 | H | The `.remote.` lane's relationship to the `auth:` enum is undefined. ARCHITECTURE:220 says the `sso` tier "is also the path that survives going off-tailnet", but no transport reaches Caddy from off-tailnet today; and tinyauth's login page would itself need to be reachable from off-tailnet, which is not planned. | §3.4 introduces a separate `remote:` field; Cloudflare Access is the off-tailnet gate, verified at origin. Rewrite ARCHITECTURE:220 to say tinyauth serves the tailnet's *session* need, and Access serves the off-tailnet one. |
| 18 | M | The first tenant app introduces service-private secrets at `~/.config/home-stack/<tenant>/` (0600 JSON) with `HOME_STACK_SKIP_ENV_LOCAL=1`. SECURITY §Secrets says secrets live in `env.local`. The rationale is sound (don't hand the Cloudflare token to a daemon that will later spawn Chrome) and Hermes already follows the same shape with `~/.hermes`. It is a *pattern*, not an exception, and needs to be written down once. | SECURITY + SERVICE_INTERFACE: "Service-private secrets: a managed service whose wrapper sets `HOME_STACK_SKIP_ENV_LOCAL=1` may keep its own 0600 secret file under `~/.config/home-stack/<service>/`; `hs doctor` checks mode; never under `data/` (the backup folder)." Phase D's tunnel credentials use the same rule. |
| 19 | M | GOVERNANCE.md: Roles list duplicated, "Cadence:" twice, references a non-existent `plan.md`, escalation "to the org" for a single-maintainer repo. | Rewrite to ~15 lines: owner, agents as contributors, infra-review rule, tag cadence, decision-log rule. |
| 20 | M | `hs app` still dispatches to `cmd_app_add` (stub printing a migration message); ROADMAP and STATUS still promise a "full `hs app` helper family (Phase F)". But Phase F shipped as `hs service add/remove` + `hs deploy` (DECISIONS 2026-05-04). Two nouns for one thing. | Declare Phase F delivered as `hs service`. Remove the `hs app` stub and every roadmap mention. Remaining ideas (`open`, `doctor`, `init` per service) become `hs service <verb>`. |
| 21 | M | STATUS "Deploy cockpit" partial: `deploy.apply` regenerates and reloads Caddy but does not install/restart changed LaunchAgents. The reason it was left out (bootout race) was retired on 2026-08-08. | §3.3: finish apply with the race-free converge. |
| 22 | L | ARCHITECTURE "Upgrade Model" wants install method/binary path/version tracked per component; no registry field exists. | §3.6 defines `install:` block. |
| 23 | L | STATUS "Hermes iPhone client" partial depends on `goncharik/hermes-mobile` (Basic-only). The mosh/Moshi research in this session is a separate lane (terminal access, not Hermes) and should not be conflated; but Moshi's agent-inbox features may reduce the need for a Hermes-specific phone client. | Record as an option in the Hermes doc's "Personal and remote operator" section; no action. |
| 24 | L | Dev gateway: `subdomain: "*.dev"` + `auth: tailnet` is registered and installed but STATUS says unreachable "until `*.dev` has a certificate". Caddy's DNS-01 will issue `*.dev.<parent>` automatically for that site block; the likely missing piece is the DNS record `*.dev.<parent-domain> → tailnet IP`, not the cert. | §3.5. |

### 1E. What is *not* wrong (checked, keep)

- The identity-layer model (Tiers 0–3, `auth:` closed enum, proxy-secret proof-of-hop for Admin, brokers ungated, break-glass paths) is internally consistent across ARCHITECTURE, SECURITY, SERVICE_INTERFACE and the registry.
- Hermes ownership split (dashboard = Home Stack, gateway = app-owned) is consistent across all five docs that mention it.
- Portal projection boundary and schemas: consistent.
- The launchd race retirement is reflected in CHANGELOG, DECISIONS_LOG, and code; only AGENTS.md lags (#10).
- The first tenant app's design is a strong spec; its issues are branch-staleness (#1) and one undocumented pattern (#18), not design.

---

## 2. Realigned plan

### Principles (unchanged, restated so the sequence below is checkable against them)

1. Registry is the only source of truth; the engine emits fixed, reviewed blocks from closed enums. No directive surfaces, no shell interpolation, no env flags that shadow registry state.
2. Nothing listens publicly **by default**; every public route is an explicit, per-service, registry-declared, edge-authenticated, origin-verified exception. Native-protocol exceptions never get one.
3. Fewest moving parts: no VPS, no containers, no second supervisor, no wrapper per CLI.
4. Docs are governance: STATUS is truth, ROADMAP is intent, DECISIONS_LOG is why. A change that lands without touching the three is incomplete.

### Sequence (revised 2026-09-05, trimmed)

Direction: the host is a laptop for the foreseeable future and may move to a new Mac at any point; reliability and a known migration procedure outrank features. This is a personal project — build only what a real need pulls. The full statement is `docs/ROADMAP.md` → Direction; earlier sequences are in git history.

| Order | Workstream | Depends on | Infra review | Spec |
|---|---|---|---|---|
| P0 ✓ | Merge `feat/tailnet-identity-layer` → `main` (#2); tag `v0.1.0` | — | no | done 2026-09-04 |
| P1 ✓ | Doc reconciliation and direction (§3.1) | P0 | no | done 2026-09-05 |
| P2 | Tenant-ready registry (§3.2): `enabled:`; `HOME_STACK_SELF_*` / `HOME_STACK_DATA_DIR` injection; flag/var retirement; `make test` isolation | P1 | **yes** (generation) | 2 evenings |
| P3 | Reliability (§3.10, trimmed): prefix-isolated launchd tests on the host; lifecycle bug list; `deploy.apply` converge (§3.3); sleep/reboot runbook + doctor checks | P2 | **yes** (launchd) | 3–4 evenings |
| P4 | Migration (§3.11, trimmed): inventory table; one export command; reinstall table | P3 | no | 1 evening |
| Pulled by need | `hs upgrade caddy` (§3.6); shared notifier (§3.12); Phase D (§3.4); dev gateway (§3.5); Admin backlog (§3.7) | — | yes | — |
| — | Remote terminal (mosh) note in RUNBOOK (§3.9) | none | no | 20 min |

Tenant apps onboard themselves when ready — that is their scope, not this roadmap's. The first tenant app (its own repository) is first; §3.8 records what home-stack owes it, which is P2.

---

## 3. Specifications

Each spec: goal · contract · engine/scripts · tests · docs · acceptance · rollback.

### 3.1 Doc-reconciliation PR (done — this file landed in it)

Goal: after this PR, an agent that reads INDEX → STATUS → ROADMAP acts on current truth.

Edits (file → change):

- `README.md`: #4, #5, #16 rewording (":55 nothing served through Cloudflare **by default**"; ":57 all exposure Tailnet-only **unless a service declares `remote:`**"); repository map adds HERMES_OPERATING_MODEL, DECISIONS_LOG, MIGRATION, PLAN.
- `docs/INDEX.md`: full regeneration (#9); add "Active specs" (the tenant app's onboarding doc, REMOTE_ACCESS when written, PLAN).
- `docs/ROADMAP.md`: replace Near-Term Priorities with §2's table; move Phase 1 Design Notes to `docs/attic/specs/2026-05-02-profiles-portability.md`; delete the Basic-Auth retirement bullet (#7); delete `hs app` family (#20); Remote Access section points to §3.4's spec file; Dev Gateway section rewritten per §3.5; add Upgrade `install:` block (#22).
- `docs/STATUS.md`: "Not Implemented" — remove `hs app` family; rename `remote_access: true` → `remote:` field; add "make test builds production binary (fix in P2)"; add "feature flags are inert (removal in P2)".
- `docs/ARCHITECTURE.md`: :45 scope the tunnel prohibition to native-protocol exceptions; :220 rewrite the off-tailnet sentence (#17); add "External perimeter" subsection summarising §3.4; "Upgrade Model" references `install:`.
- `docs/SECURITY_MODEL.md`: add "Service-private secrets" rule (#18); add "External perimeter" section (Access-before-origin, JWT verified at origin, eligibility rules, never Admin/Hermes/brokers).
- `docs/SERVICE_INTERFACE.md`: #18 rule; `enabled:` and `remote:` fields in the field table (after P2/P3 land, otherwise as "planned").
- `docs/GOVERNANCE.md`: rewrite (#19).
- `AGENTS.md`: #10 runtime rules; note `make test` hazard until P2 lands.
- `CHANGELOG.md`: cut `0.1.0` section (#2).
- A real profile's `services.yaml`: comment fix (#8) — profile file, so bundle with P2 rather than a docs PR if you want the docs PR to be zero-risk.
- `docs/DECISIONS_LOG.md`: one row — "2026-09-04 | Plan realignment: registry-only toggles, `remote:` as a closed enum, Phase D revalidated against browser-only off-tailnet requirement | … | Superseded: retire-Basic-Auth bullet; `hs app` family; env feature flags".

Acceptance: `grep -n "preview-only\|Basic-Auth'd\|hs app\|ENABLE_DEV_GATEWAY" README.md docs/*.md` returns nothing; INDEX lists every file in `docs/`.

### 3.2 Registry `enabled:` + contract cleanup

Goal: the registry alone decides what exists; wrappers derive hostnames from the engine, not from parallel env vars.

Contract:
- New optional registry field `enabled: true|false` (default `true`). `false` ⇒ service is validated and appears in Admin inventory as `disabled` (a fifth, neutral signal state) but the engine emits **no** Caddy route, **no** plist, and the catalog projection marks it `launchable: false, lifecycle: disabled`. `install-launchd.sh` prunes a previously-installed plist for a now-disabled service (the existing removal-propagation path).
- Delete `HOME_STACK_ENABLE_*` from both profiles, `templates/profile.env.example`, ROADMAP contract, README:39.
- Delete `HOME_STACK_PHASE_A/B_CADDY_PORT`, `HOME_STACK_DEV_DOMAIN`, `HOME_STACK_POCKET_ID_SUBDOMAIN`, `HOME_STACK_TINYAUTH_SUBDOMAIN`.
- Engine injects into every managed service's plist `EnvironmentVariables`: `HOME_STACK_SELF_NAME`, `HOME_STACK_SELF_HOST` (rendered FQDN or empty), `HOME_STACK_SELF_URL` (`https://<host>` or empty). Wrappers `run-pocket-id.sh`, `run-tinyauth.sh`, `run-hermes.sh` use `HOME_STACK_SELF_URL` / look up the sibling's URL from `catalog.json` (generated, private, already on disk) instead of env fallbacks. Fail fast if absent — no `:-id`.
- `make test`: `GOBUILDENV go build -o .test-build/home-stack-admin`; tests honour `HOME_STACK_ADMIN_BIN`; new explicit `make build-admin` writes the production path; `.gitignore` `.test-build/`.

Tests: engine golden with one `enabled: false` fixture (route/plist absent, catalog entry present); idempotency; portability scan unchanged; wrapper tests assert the derived URL equals the fixture FQDN and that a missing `HOME_STACK_SELF_URL` aborts; `plist-lint` accepts the new env keys; a Makefile test proving `make test` leaves `home-stack-admin`'s mtime untouched.

Docs: SERVICE_INTERFACE field table; STATUS; CHANGELOG; DECISIONS_LOG row ("registry-only toggles; env-derived hostnames retired").

Acceptance: `hs sync` on the live profile with `dev-gateway: enabled: false` removes its route and plist, Admin shows it `disabled`, Portal catalog still lists it non-launchable; `grep -rn ENABLE_ profiles templates docs` empty.

Rollback: field is additive; remove it and re-sync.

### 3.3 Finish `deploy.apply` (launchd converge)

Goal: "apply" means the host matches the registry, including launchd.

Behaviour: after regenerate + Caddy reload, `deploy.apply` calls the same converge logic as `install-launchd.sh --load` (byte-identical plist ⇒ leave alone; changed ⇒ `home_stack_wait_label_gone` + bootstrap; removed/disabled ⇒ bootout + prune; Caddy daemon plist changes ⇒ *not* applied automatically — surfaced as a "requires sudo, run manually" item in the plan, because Admin runs unprivileged). Apply plan lists each service with the verb it will receive; the confirmation sheet shows it; events record per-service outcome.

Tests: `hs-deploy.test.sh` extended with a plist-change fixture on Linux (dry-run mode that prints the converge plan without `launchctl`); Tart tier runs it for real. Never on the live host (memory: destructive test guard).

Docs: STATUS "Deploy cockpit" moves to Implemented; RUNBOOK sync workflow step 3 becomes `hs deploy --apply`.

Acceptance: change a managed service's `args`, `hs deploy --apply`, service restarted with new args, unchanged siblings untouched (PIDs stable), event log shows the plan and outcomes.

### 3.4 Phase D — Remote access

Specified in full in `docs/REMOTE_ACCESS.md`; the summary below is kept so this file reads end to end.

**Requirement (2026-09-04):** reach chosen web apps from a browser on a machine where nothing can be installed (work/public computer), with authentication that never types a reusable secret on that machine, with unauthenticated traffic never reaching the Mac, and with the simplest possible "one URL, sign in, click" experience.

**Decision (supersedes nothing; refines the 2026-04-27 row):** Cloudflare Tunnel + Cloudflare Access. Evaluated: ngrok (out — paid for parity, second vendor, domains widely blocked by corporate filters), Tailscale Funnel (exception lane only — no edge auth, `ts.net` names, bandwidth caps), self-hosted edge/Pangolin (out — a VPS to defend), client-based ZTNA (out by requirement), browser RDP (out — hands the whole machine to an untrusted browser).

**Identity for the external lane — a correction to advice given earlier in this session.** Federating Access to Pocket ID would require Pocket ID itself to be reachable from the public internet (the IdP must serve the login page to the off-tailnet browser). That adds a public login surface to satisfy "one identity", which conflicts with "protect the machine best". Recommended: **D.1 uses Access's built-in methods only** — one-time PIN to email (verified) plus GitHub or Google as a passkey-capable IdP that Cloudflare hosts. Zero new public surface on the Mac. **D.2 (optional, later):** expose Pocket ID via the tunnel *without* an Access gate and register it as an Access OIDC IdP, if a single passkey identity across both perimeters turns out to matter. Record as an open decision.

**Contract**

Profile (optional, defaults shown):
- `HOME_STACK_REMOTE_DOMAIN` = `remote.${HOME_STACK_PARENT_DOMAIN}`
- `HOME_STACK_REMOTE_ORIGIN_PORT` = `31530` (Caddy loopback listener for the tunnel)
- `HOME_STACK_ACCESS_TEAM_DOMAIN` = `<team>.cloudflareaccess.com` (non-secret; required when any service sets `remote:`)

Secrets (service-private per #18, **not** `env.local`): `~/.config/home-stack/cloudflared/<tunnel-uuid>.json` (tunnel credentials, 0600). The existing `HOME_STACK_CLOUDFLARE_API_TOKEN` (DNS-scoped) is reused only by the operator-run `hs remote route` helper to create CNAMEs; `cloudflared` never sees it.

Registry (closed enums, fixed blocks — same idiom as `auth:`):
```yaml
  someapp:
    subdomain: someapp
    auth: tailnet-or-sso       # tailnet lane unchanged
    remote: access             # omitted|none|access
    remote_aud: "a1b2…"        # Access application AUD tag (non-secret), required when remote: access
```
Validation rejects `remote: access` on: services without `subdomain`/`host`; `kind: control|agent|auth|backend|ingress` (Admin, Hermes, Pocket ID, tinyauth, OpenCode, Caddy, dev-gateway — hard-coded deny by kind, mirroring the native-protocol prohibition); services with `proxy_identity: upstream` (Hermes); `enabled: false`; missing `remote_aud`; missing `HOME_STACK_ACCESS_TEAM_DOMAIN`.

New managed services (registry entries in the profile, engine-generated plists):
- `cloudflared` — `lifecycle: managed`, `type: task`-like long-runner (needs `KeepAlive`; use `type: proxy` with no subdomain, as `opencode` does), binary from Homebrew, args `tunnel --config ~/.config/home-stack/cloudflared/config.yml run`, wrapper `run-cloudflared.sh` sets `HOME_STACK_SKIP_ENV_LOCAL=1` and a minimal allowlisted environment. Health: `port: 0` n/a → use `http_url: http://127.0.0.1:20241/ready` (cloudflared metrics/ready endpoint, loopback, set via `--metrics 127.0.0.1:20241`).
- `access-verify` — ~120-line Go service, `127.0.0.1:31531`, no subdomain. `GET /verify` reads `Cf-Access-Jwt-Assertion`, validates signature against `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs` (cached, 7-day rotation tolerant), `iss` == team domain, `aud` ∈ allowed set passed as `X-Home-Stack-Remote-Aud` by the Caddy block, `exp`; returns 200 with `X-Webauth-Email` (from the `email` claim) or 401. Same-origin/CSRF not applicable (GET, no state). Rejected alternative: embedding this in Admin — Admin is the privileged control plane and must not be in the path of public requests, even loopback ones.

**Engine emission** (one fixed block per remote service):
```
http://someapp.remote.home.example.com {
    bind 127.0.0.1
    # only cloudflared reaches this listener; port from HOME_STACK_REMOTE_ORIGIN_PORT
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
Plus a global `servers 127.0.0.1:31530 { trusted_proxies static 127.0.0.1/32 }` so `X-Forwarded-For` from cloudflared is honoured (fixes ROADMAP's "add trusted_proxies" item). The listener is plain HTTP on loopback — the tunnel is encrypted edge→agent and the agent→Caddy hop never leaves the host; this avoids issuing a `*.remote.<parent>` certificate for a hop nobody else can observe. Header hygiene: the block strips the tailnet lane's identity headers and only forwards the email Access verified, so an upstream cannot confuse the two lanes.

Also generated: `~/.config/home-stack/cloudflared/config.yml` (registry-derived, gitignored, written by sync like the Caddyfile):
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
The tunnel UUID is non-secret and lives in the profile as `HOME_STACK_CLOUDFLARE_TUNNEL_ID`.

**Access side (operator-run, documented in RUNBOOK, not engine-managed):** create team domain; enable OTP + GitHub (or Google) IdP; one Access Application per remote hostname with policy `allow email == <you>`; copy each AUD into `remote_aud:`; enable App Launcher, restrict its visibility to the same policy; session duration for these apps: 8 h (override per app if needed); disable "automatic cloudflared authentication". `hs remote route <service>` = `cloudflared tunnel route dns <uuid> <host>` using the DNS-scoped token (idempotent). `hs doctor` section 10: cloudflared binary + version, config present and equal to what sync would generate, credentials file 0600, tunnel id set, `ready` endpoint, certs URL reachable, every `remote: access` service has an AUD and a DNS CNAME (via `dig`), no remote on denied kinds.

**Tests:** engine goldens (remote block, cloudflared config, `trusted_proxies` global) for a fixture with two remote services; validation table (every rejection above); portability scan extended to the cloudflared config; `access-verify` unit tests with a local JWKS and tokens for good/expired/wrong-aud/wrong-iss/none-alg; wrapper test proving `cloudflared`'s environment contains no `HOME_STACK_*` and no Cloudflare API token; a Linux-tier test that `hs doctor` fails when a remote service lacks an AUD.

**Docs:** REMOTE_ACCESS.md (this section expanded with the Access click-path), SECURITY external-perimeter section, ARCHITECTURE remote model, SERVICE_INTERFACE fields, RUNBOOK install/verify/rollback, VERIFICATION checklist, STATUS, CHANGELOG, DECISIONS_LOG row (identity choice D.1 vs D.2; loopback HTTP origin; standalone verifier).

**Acceptance:** from a browser with no Tailscale: App Launcher URL → OTP or GitHub passkey → tile → app loads; `curl https://someapp.remote…` without a session → Access login page (302), never a Mac response; a forged `Cf-Access-Jwt-Assertion` sent to `127.0.0.1:31530` directly → 401 from `access-verify`; tailnet route unchanged (byte-identical Caddyfile for non-remote services — golden test); `hs doctor` green; Admin shows `cloudflared` and `access-verify` healthy; Cloudflare Access logs show the login.

**Rollback:** set `remote: none` (or delete the field) → `hs deploy --apply` removes the block, rewrites `config.yml` to the 404 catch-all, restarts cloudflared; `hs service stop cloudflared` removes the public path entirely; CNAMEs can stay (they 404 at the edge) or be removed with `hs remote unroute`.

**Explicit non-goals:** remote Admin (never — Admin is `kind: control`); remote Hermes (native-protocol exception); TCP/SSH via tunnel (Tailscale covers it); Tailscale Funnel as a general lane (document it in RUNBOOK as a one-off share recipe only).

### 3.5 Dev gateway enablement

Goal: `https://<app>.dev.<your-domain>` works on the tailnet with zero-click auth.

Steps: (1) DNS: `*.dev.<parent>` A/AAAA → tailnet IP in the Cloudflare zone (same as the existing `*.<parent>` record; verify with `dig`). (2) `enabled: true` on `dev-gateway` after §3.2. (3) Confirm Caddy issued `*.dev.<parent>` via DNS-01 (Caddy does this per site block; the `*.dev` SAN is a separate wildcard order). (4) `hs doctor`: DNS resolution for `probe.dev.<parent>` equals tailnet IP; cert SAN present in Caddy's data dir. Then the `hs dev` helper family from ROADMAP, unchanged, as `hs dev scan|list|add|publish|remove|open|doctor`. Keep "remote dev exposure" out of scope: `dev-gateway` is `kind: ingress`, denied for `remote:` by §3.4.

### 3.6 Upgrade tooling (reduced 2026-09-05 to `hs upgrade caddy`; the `install:` block moved to §3.11)

Contract: optional registry block per managed service
```yaml
    install:
      method: brew|xcaddy|source|release   # how the binary got there
      source: "cloudflare/cloudflare/cloudflared" # brew formula, repo, or URL
      pin: "2026.8.1"                      # expected version or commit
      version_cmd: "cloudflared --version" # how to read the live version
```
`hs upgrade status` renders a table (service, method, pinned, live, drift). `hs upgrade caddy` = the RUNBOOK xcaddy recipe with both plugins, build to a staging path, `caddy validate` against the generated Caddyfile, swap with a `.bak`, `kickstart -k` the daemon (sudo prompt), health check, auto-revert on failure. `hs upgrade all` stays out of scope (ROADMAP already says so). Admin Doctor gains the version drift check (closes part of STATUS "deeper Doctor checks").

### 3.7 Admin backlog (unchanged scope, ordered)

1. `GET /api/actions` descriptors derived from the same `lifecycle:` logic the allowlists already use — removes frontend hardcoding (ROADMAP #3; small, no infra review).
2. Confirmation sheet fed by the §3.3 apply plan.
3. Doctor parity: Admin `/api/doctor` runs the same sections as `hs doctor` (it is the same Go binary; expose the CLI's sections).
4. Event filtering; log tailing (bounded, redacted — reuse the events redaction path).
5. Resource metrics last; only via `launchctl`/`proc_pidinfo`-level reads, no new privileges.

### 3.8 The first tenant app (onboarding is its own scope)

The first tenant app lives in its own repository, whose own onboarding
document is the contract between the two repos. That onboarding PR is raised
from the tenant side when the app is ready; home-stack's obligation is P2 —
land `enabled:` and the `HOME_STACK_SELF_*`/`HOME_STACK_DATA_DIR` injection
(§3.2) so an external binary can learn its own public URL and data directory
without sourcing `common.sh`, and keep the service-private-secrets rule (#18)
documented as the default for external binaries. Home-stack's side of any
tenant is a registry entry only (no wrapper script) plus a one-paragraph
pointer in INDEX "Active specs"; the tenant's own repository owns its design,
plan, and docs. Detailed onboarding notes for this specific app are kept in
the owner's private overlay, not here.

### 3.9 Remote terminal (mosh) — RUNBOOK note only

Not a stack service. RUNBOOK "Remote terminal" paragraph: `brew install mosh`; requires macOS Remote Login (sshd) on the tailnet — Tailscale SSH intercepting port 22 breaks the mosh bootstrap, so document which one this host runs; pair with `tmux new -A -s main`; two client entries (mosh lane, plain-SSH lane) to the same tmux session; iOS clients evaluated 2026-09-04 (Blink primary; Prompt 3, Moshi, La Terminal, Hoshi as alternatives). No registry entry, no launchd, no Caddy.

---

### 3.10 Reliability tier

Goal: launchd behaviour is tested off the live host, the known lifecycle bugs are verified or fixed, and the laptop's sleep/reboot behaviour is stated truthfully and observable.

**Prefix-isolated host tests** (replaces the Tart tier, 2026-09-05): the identifier-prefix parameterization already exists, so the launchd tests run on this host under `<prefix>.hstest.*` labels, test ports, a temporary `HOME_STACK_CONFIG_DIR`, and an ephemeral bundle copy. Nothing they bootstrap, write, or delete can collide with a production label or file. `hs status`/`uninstall` under the test prefix must never enumerate production labels (assert it). The destructive-test guard becomes "no production label, no source-tree write". Tart stays disabled; revisit only if prefix isolation proves insufficient.

**Destructive-test staging:** `service-lifecycle`, `identifier-prefix-flow`, `install-launchd-e2e` copy the bundle into a temp root and operate there on every tier; delete the source-tree writes. Extend the destructive-test guard test to assert no test writes under `$ROOT_DIR`.

**Lifecycle bug list** (one PR each; verify first, fix if real): `diffPlists` names-only (`hs deploy --preview` blind to content changes); `lifecycle: external` bootstrapped into a KeepAlive respawn loop; `uninstall-launchd.sh` without `--unload` orphaning running jobs invisible to `hs status`; `run-admin.sh` never rebuilding a stale binary; identifier-prefix validation living only in `hs doctor`, not `common.sh`. Believed fixed by the 2026-08-08 race work, confirm in the VM: `admin.restart` self-kill; `install-launchd.sh --load` dead-ingress exit path.

**`deploy.apply` converge** per §3.3, merged after the plist-change fixture runs under the test prefix on the host.

**Sleep and reboot runbook** — state, do not fight, the platform: AC-powered with `pmset` sleep disabled; lid-closed on battery sleeps and there is no fix; FileVault means a reboot needs a GUI login before LaunchAgents start (Caddy, a LaunchDaemon, starts pre-login); disable unattended OS-update restarts on watch days. `hs doctor` gains: `pmset -g` sleep/SleepDisabled on AC; "every managed agent loaded since boot" (compare launchd load time to boot time); the registry's literal Tailnet IP (Hermes upstream) equals `HOME_STACK_TAILNET_IP`. A daily health push lands once §3.12 exists.

### 3.11 Migration (trimmed 2026-09-05)

Goal: a new Mac is a procedure — export, clone, import, sync, install, verify — with nothing outside git forgotten. No tool family; a table and a command.

**Inventory** (new `MIGRATION.md` §"What lives outside git"): `~/.config/home-stack/env.local` (secrets; copy); `~/.config/home-stack/data/*` per service (copy — includes Pocket ID's passkey database and tinyauth's store; losing either means re-enrolling); service-private secret dirs `~/.config/home-stack/<service>/` (copy, 0600); `tls/` and `caddy/` (re-issued by DNS-01; do not copy); `logs/`, `pids/`, `admin-events.jsonl` (do not copy); `~/.hermes` (copy — Hermes owns it); Keychain items (`<prefix>.home-stack.tinyauth.breakglass`, the Hermes Apple Passwords record — list, recreate manually); tenant binaries (rebuild from their repos); the Portal build (`~/github/home-portal/dist`; rebuild); installed plists (regenerated; do not copy). Identity that changes on a new Mac: `HOME_STACK_TAILNET_IP` in the profile *and* the literal Hermes upstream in `services.yaml`; `HOME_STACK_OWNER_HOME` if the username differs; architecture (handled by the Makefile).

**Export**: one documented `tar` of the copy-class entries into a 0600 archive, with the restore steps beside it. **Reinstall table**: per managed component, how it was installed and how to reinstall (Homebrew formula, xcaddy recipe, repo + `make install`). `hs doctor` already checks binary presence. Housekeeping: `env-set.sh` keeps the last five backups.

**Rehearsal**: the real one — the day a new Mac arrives, follow the doc and fix what it gets wrong. If a VM rehearsal ever seems worth its cost, that is the moment to revisit Tart.

### 3.12 Shared notifier (sketch; pulled by need)

Extract from the first tenant's Web Push code when a second client — Hermes approvals — is actually being built. Not before. Sketch of the target shape:

Goal: one stack-owned way to reach the owner's phone, usable by tenants and Hermes, with no third-party push app or relay.

**Service `notify`**: managed Go service on `127.0.0.1:31540`, `subdomain: notify`, `auth: tailnet`, `kind: app`. Serves a home-screen web app (manifest, service worker with a `push` fallback that always calls `showNotification`, subscription status page, test push). API: `POST /api/push` `{title, body, url, ttl, urgency, dedupe_key}` from loopback callers with a per-client bearer token (tenants get one each, stored service-private on both sides); `GET /api/health`. Delivery: declarative Web Push via Apple's relay, `Urgency: high` for hits, TTL from the caller, delete subscriptions on 404/410, retry 429/5xx. Every push shows a notification (iOS revokes after three silent pushes). Subscriptions re-checked on every app launch; a 09:45 daily health push proves the path.

**State**: subscriptions and a bounded delivery log in `~/.config/home-stack/data/notify/` (migration inventory); VAPID keys in `~/.config/home-stack/notify/` (service-private). `--gen-vapid` refuses to overwrite.

**Clients**: the first tenant app first — its own Web Push code retires and it posts to `notify` instead; then Hermes approvals (P6) and `hs doctor` daily health. Tests: payload builder unit tests, a fake push endpoint for delivery/retry/revocation, wrapper test for the clean environment, engine golden for the registry entry. Acceptance: closed app, locked phone, VPN off — a test push shows and its tap opens the hub's page; a tenant's push arrives within 5 s of the POST.

## 4. Open decisions for the owner

1. **Phase D identity:** D.1 (Access OTP + GitHub/Google, zero new surface) now; D.2 (public Pocket ID as Access IdP) only if a single passkey identity matters. Recommendation: D.1.
2. **Which services get `remote: access` first?** Suggest one low-stakes read-mostly app to prove the lane; candidates from the current registry are limited (Portal is public-shaped already; OpenChamber is a coding UI — high stakes). This may mean Phase D's first customer is the first tenant app or a future app, which argues for not rushing P3 ahead of P2.
3. **`access-verify` standalone vs embedded in Admin.** Recommendation: standalone (keeps Admin out of the public path).
4. ~~Tag now or after P1?~~ Tagged at P0.
5. **Retire `hs app` naming entirely** (recommendation) vs keep as alias.

## 5. Verification ledger for this audit

Grep-verified in code: dead `ENABLE_*` flags; wrapper subdomain fallbacks; `make test` build path; `HOME_STACK_SKIP_ENV_LOCAL` exists; no `remote_access`/`REMOTE_DOMAIN` in code; PHASE_A/B ports present. Verified from primary docs earlier this session: Cloudflare Access OTP, App Launcher, JWT validation (`/cdn-cgi/access/certs`, `iss`/`aud`), Tailscale Funnel limits, ngrok pricing/corporate blocking. **Not verified:** Zero Trust free-tier seat count (only matters for >1 user); cloudflared's `--metrics` ready endpoint path (`/ready`) — confirm against the current cloudflared docs before wiring the health check; `HOME_STACK_BIN_DIR` default (#15).
