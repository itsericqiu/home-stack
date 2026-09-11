# Public Release (P-pub)

Status: Phases A and B done (2026-09-10); Phase C not started. Executes
before P3. When complete, this file becomes the standing rule for what may
and may not live in this repository.

## 1. Goal

Make this repository safe to publish and useful to strangers, without making
it harder for the owner to operate. Three tiers, each with one home:

| Tier | Lives in | Examples |
|---|---|---|
| **Machinery and procedures** | this repo (public) | engine, scripts, tests, docs that say *how* |
| **Deployment record** | the owner's private dotfiles overlay | the real profile, version pins, verification transcripts, deployed agent config, Keychain item names |
| **Secrets** | `~/.config/home-stack/env.local` and service-private dirs — never in any repo | tokens, hashes, signing secrets |

The rule after this lands: **nothing in this repository describes a specific
machine.** STATUS says what the code does; the overlay says what is deployed.

## 2. Threat model, stated honestly

Tailscale is the boundary; the docs are not. Nothing here is reachable from
the internet, and the domain and Tailnet IP are already public in DNS
(`*.<parent> → 100.x` answers to anyone). What publishing *would* hand an
attacker who already has a foothold — a compromised tailnet device, or a
prompt-injection path into the agent — is research they would otherwise have
to do: the exact component inventory with version pins (CVE targeting), the
agent's authority model and break-glass design, Keychain item names, and
which services bind loopback versus the Tailnet IP. That is what moves to
the overlay. Hiding the Tailnet IP would need split DNS on the tailnet — a
resolver to run — and is out of scope.

## 3. Audit result (2026-09-10)

- Tracked tree and all 62k lines of history: **no secrets** — no tokens, key
  material, bcrypt/scrypt hashes, or JWTs; the only `PASSWORD=`/`TOKEN=`
  assignments ever committed are test placeholders. `env.local`, `.bak`
  files, keys: never committed. History needs no rewrite for secrets.
- Two files tracked that should not be: `.claude/settings.local.json`
  (per-machine) and `portable/home-stack/launchd/daemons/<prefix>.caddy.plist`
  (generated; the ignore rule `launchd/*.plist` misses the subdirectory).
- Identity literals (the owner's domain, Tailnet IP, home directory path,
  identifier prefix, and ACME email) in 17 tracked files outside the archived
  design-history tree, plus roughly 50 more mentions in that archived tree.
- Deployment record mixed into public docs: RUNBOOK Hermes install and
  verification sections (pins, commit, dates), STATUS Hermes bullets
  (versions, provider/model config, restart dates), README "the owner's
  profile currently deploys…", schema `$id` URLs on the personal domain.
- One test reaches for the personal profile (`tests/status-launchd.test.sh`).
- Public-repo essentials absent: `LICENSE`, top-level `SECURITY.md`
  (GitHub would surface `docs/SECURITY.md`, an internal ops doc, as the
  policy).
- Seven Go call sites and three shell sites hardcode `profiles/<name>` under
  the repo root; no single resolver.

Second pass (broader identifiers — first name, GitHub handle, location,
personal projects, providers, Apple services — over every tracked path
including tooling, web assets, Go tests):
- Go tests use the personal domain as test data (`main_auth_proxy_test.go`,
  `engine_test.go`); fixtures and goldens are clean (`100.64.x`, `*.test`).
- Personal-project and provider references (the owner's first tenant app and
  its earlier working name, a purchasing CLI, a model-routing provider and
  specific model names, Apple Passwords, iCloud) in PLAN (25), RUNBOOK,
  STATUS, HERMES_OPERATING_MODEL, DECISIONS_LOG — deployment record leaking
  into planning docs.
- `home-portal` (the Portal v2 consumer) is a **private** repository; the
  public contract must describe it as an external consumer with the
  fallback page shipping here.
- Commit authorship: 120 commits under the owner's primary email address, 4
  under a variant address at the owner's personal domain, 1 under a
  placeholder. Squashing leaves one author identity; see decision 5.
- Tooling (`tools/`, `Dockerfile.linux-test`, `verify.sh`, `Makefile`, CI),
  `portal-www`, admin templates, dev-gateway: clean. No blob over 1 MB in
  history.

## 4. Phase A — Overlay and the profile interface

Home-stack PR, infra review (profile resolution, ignore rules). One evening.

**A1. One profile resolver.** Go: `profilesDir(bundleDir) string` and
`registryPath(bundleDir, profile)` replace the seven inline
`filepath.Join(bundleDir, "../../profiles", …)` sites (engine.go ×2, main.go
×2, registry.go ×3). Shell: `home_stack_profile_dir <name>` replaces the three
inline `$HOME_STACK_REPO_ROOT/profiles/…` sites in `common.sh` and `hs`.
Both honour an optional `HOME_STACK_PROFILES_DIR` (default
`$REPO_ROOT/profiles`). The **symlink remains the documented mechanism** —
it needs no environment and works for launchd-launched processes; the
override exists so staged tests and CI can point at a fixture tree without
copying. Tests: resolver unit tests; a golden run with `HOME_STACK_PROFILES_DIR`
pointing at `tests/fixtures`.

> **Done (2026-09-10).** `profilesDir`/`registryPath` land in
> `portable/home-stack/admin/registry.go`; `home_stack_profiles_dir`/
> `home_stack_profile_dir` land in `lib/common.sh` (also used by `hs`'s
> `cmd_init` and `cmd_doctor`). Both a Go unit test and an `env-layering`
> shell test cover a symlinked `profiles/<name>`; `profile-portability.test.sh`
> exercises the `HOME_STACK_PROFILES_DIR` override end to end for one fixture.
> `AddService`/`RemoveService` in `registry.go` were flagged here as a
> follow-up still resolving profiles via `HOME_STACK_REPO_ROOT` directly;
> that follow-up landed in PR #5 — both now go through the shared
> `registryPath`/`profilesDir` resolver like every other call site.

**A2. Ignore rules and untracking.**
```
profiles/*/
!profiles/default/
portable/home-stack/launchd/**/*.plist
.claude/settings.local.json
```
`git rm --cached` the daemon plist, `settings.local.json`, and (after A4)
the owner's real profile directory. Any real profile a stranger creates with
`hs init` is therefore gitignored by default — the convention becomes "your
profile is yours; keep it in your own dotfiles".

> **Done (2026-09-10).** `.gitignore` updated as above; the daemon plist and
> `.claude/settings.local.json` untracked. The owner's real profile directory
> was also untracked here rather than deferred to A4 (explicit instruction
> for this PR) — the working files are left on disk untouched, so the live
> host sees no change until the owner separately does the A4 overlay copy.
> Verified: `git ls-files profiles/` shows only `profiles/default/**`; `git
> status --porcelain` shows the three paths as ignored, not `??`.

**A3. Tests.** `status-launchd.test.sh` uses `default` (or a fixture), never a
real profile. New `tests/public-hygiene.test.sh`, run on every tier:
- no tracked file outside `profiles/default/`, `tests/fixtures/`,
  `tests/golden/` matches the identifier pattern list
  (`tests/lib/hygiene-patterns.sh`);
- no tracked path under `profiles/` other than `default/`;
- no tracked generated artifact (`Caddyfile`, `catalog.json`, `*.plist`
  under `portable/`), no `.claude/settings.local.json`, no `env.local`.
The pattern list is data at the top of the test so a new owner can add their
own identifiers.

> **Done (2026-09-10).** `status-launchd.test.sh` now resolves `default` only.
> `tests/public-hygiene.test.sh` added; its identifier scan is scoped to
> `portable/`, `tests/`, `templates/`, `schemas/`, `Makefile`, `.github/`,
> `tools/`, `verify.sh`, `Dockerfile.linux-test` for this PR (marked
> `DOC_PATHS_PENDING_PHASE_B` in the test — docs join the scan once §5 lands);
> its tracked-path checks are repo-wide and active now. The pattern list moved
> to `tests/lib/hygiene-patterns.sh`, sourced by both this test and
> `profile-portability.test.sh`'s own leak scan. Within the current scope the
> scan found and fixed: `main_auth_proxy_test.go` and `engine_test.go` test
> data/assertions, `templates/profile.env.example`'s tailnet-IP example. One
> finding was deliberately left and allow-listed rather than fixed: the
> `schemas/portal/*.schema.json` `$id` values, which are explicitly a Phase B
> item gated on the unresolved owner decision in §8.4 (neutral URN,
> coordinated with the private home-portal mirror) — changing them here would
> make that decision unilaterally. `make test` is green; `go vet ./...` is
> clean.

> **Follow-up (2026-09-10).** `tests/lib/hygiene-patterns.sh` carried the
> owner's own identifiers (handle, domain, IP prefix) as tracked patterns —
> itself a leak once this repository is public. The tracked file now holds
> only generic identifier *classes* that apply to any deployment (a
> Tailscale CGNAT address outside the documented `100.64.0.x` example block,
> a `/Users/<name>` path whose name isn't a documented placeholder, an email
> address off `example.com`/`example.local`/a `.test` TLD/`noreply`, a
> `*.ts.net` hostname, the string `settings.local`). The owner's specific
> identifiers move to an optional, untracked pattern file — set
> `HOME_STACK_HYGIENE_PATTERNS_FILE`, or place one at
> `$HOME/.config/home-stack/hygiene-patterns.sh` — declaring a
> `HOME_STACK_HYGIENE_PRIVATE_PATTERNS` bash array. The owner keeps this file
> in the dotfiles overlay (A4) alongside the other per-machine record and
> links it into `~/.config/home-stack/`, the same way the profile is linked
> in. `tests/public-hygiene.test.sh` prints one line saying whether a
> private pattern file was loaded, so a run's output always says which mode
> it ran in.

**A4. Dotfiles overlay** (`~/.dotfiles`, private): four categories of record,
each its own file — the live profile itself (moved verbatim: `home-stack.env`,
`services.yaml`), an installed-components record (component pins, commits,
install dates, verification transcripts), the deployed agent's configuration
(bind, username, provider/model routing, hard-deny rules), and private
migration rows (Keychain item names, per-machine inventory rows that don't
belong in the public migration doc). A short README in the overlay says what
this is, how it is linked, and that this overlay must never be made public.
`install.sh` gains one conditional step after the existing symlinks: if
`~/github/home-stack` exists, `ln -sfn ~/.dotfiles/home-stack/profiles/<name>
~/github/home-stack/profiles/<name>`. README table gains the row. Commit and
push (private remote).

**A5. Live-host cutover** — *done 2026-09-10: profile symlinked into the overlay; `profiles/*` ignore rule corrected to cover symlinks (`2e37028`). Lesson recorded: checking out across the commit where a file stops being tracked deletes the on-disk copy — back up first.*

**A5 (original text).** (owner's machine, in this order): copy the real
profile directory into the overlay → commit dotfiles → in home-stack
`git rm -r --cached profiles/<name>` → replace the directory with the
symlink → `hs doctor`, `hs status`, `hs deploy --preview` reports in sync →
commit. Running services are unaffected (they do not re-read the profile);
the next `hs sync` reads through the symlink.

## 5. Phase B — Scrub and split the docs

Docs PR, no infra review. One to two evenings; the mechanical bulk.

**B1. Deployment record → overlay.** RUNBOOK: the Hermes "reviewed
installation" and "live infrastructure" sections keep the *procedure*
(install from the official checkout, pin the commit in your overlay's
`INSTALLED.md`, verification checklist) and lose the pins, dates, and
transcripts. STATUS: Hermes and identity-layer bullets state the capability
("managed Hermes dashboard with clean child environment; OIDC or Basic"),
not the deployment (versions, provider models, restart dates, Apple Passwords
arrangement). VERIFICATION: procedures only. CHANGELOG: the `0.1.0` and
`0.2.0` sections condensed to code-level changes.

> **Done (2026-09-10).** RUNBOOK, STATUS, VERIFICATION, and CHANGELOG scrubbed
> as specified. Every removed pin, commit, verification transcript, and
> Hermes-deployed configuration detail was preserved in the handoff
> (`INSTALLED.md`, `hermes-deployed.md`) rather than dropped.

**B2. Placeholder pass.** The owner's personal domain → `home.example.com`;
the owner's literal Tailnet IP → `100.64.0.8` (already the convention in
SERVICE_INTERFACE); the owner's home directory path → `~` or `/Users/<owner>`;
the owner's identifier prefix → `io.example`; the owner's admin email →
`admin@example.com`; the owner's tinyauth breakglass Keychain item name →
`<prefix>.home-stack.tinyauth.breakglass`.
Files: RUNBOOK, VERIFICATION, ARCHITECTURE, SECURITY, STATUS, PLAN,
MIGRATION, DECISIONS_LOG, CHANGELOG, LAYOUTS, AGENTS, README,
`templates/profile.env.example`. Schema `$id` values become a neutral URN
(`urn:home-stack:schemas:catalog:v1`) — **coordinated with the home-portal
mirror** (`npm --prefix ../home-portal run check:schema-sync` must pass).

> **Done (2026-09-10).** Placeholder pass applied across all listed files
> (LAYOUTS.md was deleted per B5 rather than edited). **Deviation from the
> plan above, per explicit direction for this PR:** schema `$id` values were
> left unchanged rather than converted to a neutral URN — see §8 decision 4,
> still open and gated on coordinating with the private `home-portal`
> mirror; they remain allow-listed in `tests/public-hygiene.test.sh`.

**B3. README for strangers.** What it is (one Mac, tailnet-only, registry →
Caddy + launchd, Admin control plane, optional identity layer, optional
agent tenants); what it is not (not multi-host, macOS-only, opinionated,
a personal project maintained for one owner); requirements (macOS, Tailscale,
a Cloudflare-managed domain, Go); quick start via `bootstrap.sh` / `hs init`;
the profile-overlay convention; what runs out of the box (Caddy, Admin,
Portal fallback) versus what is example registry entries (Hermes, OpenCode,
OpenChamber, Pocket ID, tinyauth); pointers to STATUS/ROADMAP/PLAN; license.
Remove every "the author's live deployment" sentence.

> **Done (2026-09-10).** README rewritten per this spec.

**B3b. Go tests and planning docs.** Test data in `main_auth_proxy_test.go`
and `engine_test.go` uses example values. PLAN.md, ROADMAP.md,
DECISIONS_LOG.md, HERMES_OPERATING_MODEL.md lose personal-project and
provider references: descriptive phrasing ("the first tenant app", "the
configured provider") replaces the owner's actual personal-project name and
specific AI-provider/model names; purchasing examples generic; Apple
Passwords/iCloud arrangements move to the overlay's `hermes-deployed.md`.
Portal v2 is described as an external consumer of the published schemas;
`portable/home-stack/portal-www` is the shipped fallback.

> **Done (2026-09-10).** PLAN.md, ROADMAP.md, DECISIONS_LOG.md,
> HERMES_OPERATING_MODEL.md, STATUS.md, SECURITY.md, and SERVICE_INTERFACE.md
> genericized. The detailed onboarding notes for the first tenant app moved
> to the handoff's `migration-private.md` under "Tenant notes"; the
> purchasing-CLI example's real identity moved there too. Go test data was
> already clean (verified, not re-touched).

**B4. Attic.** `docs/attic/` stays in the archived private repo only; deleted
from the public tree. INDEX's historical-context section points at the
archive by name only in the overlay README, generically here.

> **Done (2026-09-10).** `git rm -r docs/attic`; every reference to it
> repo-wide (README, INDEX, ROADMAP, STATUS, GOVERNANCE, AGENTS) rewritten to
> point at "the archived private repository" generically instead of a path.

**B5. LAYOUTS.md** describes a `v1.0.0`/`latest` symlink layout that does not
exist; verify and archive it.

> **Done (2026-09-10).** Verified: no `portable/home-stack/v1.0.0` or
> `latest` directory/symlink exists anywhere in the tree. `docs/LAYOUTS.md`
> deleted (not archived, since it never described anything real); its only
> reference was in `docs/INDEX.md`, removed.

**B6. Public-repo essentials.** `LICENSE` (owner's choice; MIT recommended);
top-level `SECURITY.md` — ten lines: personal project, no bug bounty, report
privately via GitHub's advisory form; `docs/SECURITY.md` renamed
`docs/SECURITY_MODEL.md` so GitHub does not surface it as the policy.
`CONTRIBUTING.md` says what is and is not welcome.

> **Done (2026-09-10).** `LICENSE` added (MIT, copyright the owner's legal
> name, 2026 — the one file in the repository expected to carry it).
> Top-level `SECURITY.md` added (12 lines). `git mv docs/SECURITY.md
> docs/SECURITY_MODEL.md`; every reference repo-wide updated
> (`git grep -n "SECURITY.md"` confirmed clean outside this file's own
> historical prose). `docs/CONTRIBUTING.md` rewritten with welcome/not
> welcome/process sections.

**B7. Governance rule.** AGENTS.md and INDEX.md gain the tier table from §1
and the sentence "deployment records never go in this repository; STATUS
describes the code, the overlay describes the machine."

> **Done (2026-09-10).** Tier table and sentence added to both files.
> `tests/public-hygiene.test.sh` widened to scan the whole repository
> (previously `portable/`, `tests/`, `templates/`, `schemas/`, and a handful
> of tooling paths); the `docs/PUBLIC_RELEASE.md` exclusion was dropped
> entirely rather than narrowed — this file's own §3 audit findings and
> historical "Done" logs were rewritten with placeholders so the file passes
> the widened scan like everything else. Added `\bEric\b` to
> `tests/lib/hygiene-patterns.sh`; specific AI-provider/model names and the
> personal-project references above were left out of the automated pattern
> list per instruction and handled by manual review instead — verified clean
> via a full-repo grep during this pass.

## 6. Phase C — Publish

Owner decisions first (§8). One hour.

**C1. Squash-and-replace** (recommended): after A and B are on `main` and
`public-hygiene` is green, rename `github.com/itsericqiu/home-stack` →
`home-stack-archive` (private; archive it after cutover); create
`github.com/itsericqiu/home-stack` public; from the scrubbed tree, an orphan
branch with one commit "home-stack v0.3.0 — public baseline"; push as `main`;
tag `v0.3.0`; repoint the local checkout's `origin`; delete stale local
branches and the leftover worktree. The archive keeps full history and PRs
#1–#4; `DECISIONS_LOG.md` and `CHANGELOG.md` carry the narrative forward.
Alternative, if the owner prefers to keep history public: `git filter-repo`
replacing the identity literals and deleting the archived design-history
tree, the daemon plist, and `.claude/` from every revision — accepted cost:
old STATUS/RUNBOOK revisions still carry deployment detail.

**C2. GitHub settings:** branch protection on `main` (PR + green CI);
secret scanning and push protection on; Dependabot alerts on (config already
present); Actions default permissions read (already); fork-PR workflow
approval left at GitHub's default; description and topics; Issues on,
Discussions off.

**C3. Post-publish verification:** a fresh clone into a temp dir on this Mac:
`hs init acme` with the fixture values, `hs doctor`, `make test` green, the
portability test against a staged bundle, `git log` shows one commit, the
hygiene test green. Live host: `hs doctor`, `hs status`, `git status` clean,
`origin` points at the public repo.

## 6b. Verification passes (one per phase boundary)

Each phase ends with an independent pass whose job is to find what the
phase missed. They are run by a fresh reviewer (a subagent with no memory of
the edits), and their findings are fixed before the next phase starts.

**Pass 1 — complete inventory (before A; done 2026-09-10, results in §3).**
Mechanical scan of every tracked path with the broad identifier list plus a
high-entropy scan; every hit gets a disposition (scrub / move to overlay /
allowed). The identifier list becomes the data file the hygiene test reads.

**Pass 2 — two-persona read-through (after B).** *Done 2026-09-10: newcomer found the promoted quick start broken (`bootstrap.sh` never built the admin binary) plus four doc contradictions; insider found the hygiene pattern file itself disclosed the owner's identifiers, and the spec named the projects it told other docs to drop. All fixed in `14985fc`; owner-specific patterns now live in the private overlay and load from `~/.config/home-stack/hygiene-patterns.sh`.*
- *Newcomer:* reads only the public tree, follows README → ONBOARDING →
  `bootstrap.sh` / `hs init` as someone with a Mac, Tailscale, and a
  Cloudflare domain. Flags every assumption about the owner's machine, every
  reference to a private repository or nonexistent path, every step that
  cannot be completed from the public tree alone, and every place the docs
  contradict each other.
- *Insider:* reads the public tree as someone with a tailnet foothold and
  writes down everything learned about the specific deployment — versions,
  addresses, usernames, item names, provider accounts, personal projects.
  Anything on that list is a deployment record that escaped and goes to the
  overlay.

**Pass 3 — fresh-clone rehearsal (before C).** *Done 2026-09-10: `hs init acme` → doctor names exactly the three remaining stranger steps (secrets, Caddy build, `make build-admin`) → `make build-admin` + `hs sync` clean → `make test` green with no private patterns.* A clone of the scrubbed
`main` into a temp dir on this Mac: `hs init acme` with fixture values,
`hs doctor`, `make test`, the portability test against a staged bundle, the
hygiene test. Nothing may depend on the owner's overlay being present.

**Pass 4 — post-publish check (after C).** Hygiene test green in CI on the
public repo; secret scanning and push protection confirmed on; `gh api`
shows only `main` and `v0.3.0`; the live host's `origin` is the public repo
and `hs doctor` is green; the archive is private and archived.



- Hide the Tailnet IP or domain (DNS-public; split DNS is out of scope).
- Pretend obscurity is the boundary — Tailscale is.
- Rewrite the private repo's history in place.
- Move secrets into dotfiles — they stay in `env.local`, as dotfiles' own
  convention already does for its secrets.

## 8. Owner decisions

1. **History:** squash-and-replace — *decided 2026-09-10.*
2. **License:** MIT — *in tree.*
3. **Names:** public `home-stack`, archive `home-stack-archive` — *decided.*
4. **Schema `$id`:** neutral URN with a coordinated home-portal change
   (recommended), or leave the personal-domain URLs (they are only
   identifiers, and the domain is DNS-public). Note (Phase B, 2026-09-10):
   left unchanged pending this decision, per explicit instruction for that PR.
5. **Commit identity:** GitHub noreply address — *decided; repo-local config
   in home-stack, home-portal, and the dotfiles overlay.*
6. **home-portal:** published alongside — *decided; see §6d.*
