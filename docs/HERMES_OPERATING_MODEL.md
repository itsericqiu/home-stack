# Hermes Operating Model

Last updated: 2026-09-10

This is the staged contract for using official Hermes Agent as a personal
assistant, remote Mac operator, coding dispatcher, and later automation host.
It does not make unfinished capabilities current implementation; that ledger
remains `docs/STATUS.md`.

## Ownership

Home Stack owns the exposed dashboard's supervision, exact network bind, Caddy
route, health, bounded logs, and reviewed Home Stack recovery entrypoints.
Hermes owns models, auxiliary routing, memories, sessions, skills, MCP
definitions, provider credentials, messaging behavior, cron jobs, and its
official non-network-listening gateway LaunchAgent. Provider accounts own hard
spending limits and privacy/routing policy. macOS permissions, worktrees,
containers, and Keychain provide boundaries below the agent.

No model/API credential belongs in `services.yaml`, a generated plist, tracked
profile data, or the shared Home Stack environment passed to Hermes.

## Pragmatic Operating Baseline

### Personal and remote operator

The authenticated Tailnet dashboard is the normal iPhone/browser/compatible-
client surface. It may research, plan, use approved memory, run diagnostics,
use the normal command-line tools available to the logged-in macOS user,
recover services, and invoke general tools such as Codex, Claude Code,
OpenCode, or a CLI for an everyday task (e.g. ordering/purchasing). Hermes'
native tool settings, smart approvals, and a
small hard-deny credential floor are the ordinary control. Home Stack does not
maintain a wrapper or allowlist for every executable.

This is a trusted-user remote shell mediated by an agent, not a hostile-code
sandbox. Consequential actions such as deployment, Keychain access, `sudo`,
purchases, external messages, and destructive Git operations should show the
concrete effect and ask for confirmation. Hermes cannot enforce that
policy for every command spelling, so the operator must not interpret a silent
tool call as proof of a security boundary.

Profiles are optional organization for different models, memories, projects,
or budgets. They are not required merely to make a CLI usable, and profiles on
the same dashboard are not an authorization boundary. Add a genuinely isolated
Hermes home/process only when experience reveals a concrete need for separate
credentials or authority.

### Coding workers

Hermes may invoke Codex, Claude Code, OpenCode, and its own subagents directly.
For read-only work or one writer, the existing checkout is usually sufficient.
Use named branches/worktrees when work will be concurrent or when isolation is
material; never let two agents write the same checkout simultaneously. Prefer
the coding harness' own branch, approval, diff, and test features before adding
a Home Stack coordinator. Add custom coordination only after repeated real
failures demonstrate that the native tools are insufficient.

### Local operator and break-glass

The authenticated Tailnet operator may perform broad host diagnostics and
recovery while away, including debugging Home Stack when Admin or Caddy is
unavailable. Prefer previews and bounded native commands, keep Tailscale SSH as
the independent recovery path, and require action-specific confirmation for
purchasing, deployment, credential access, and destructive operations. Add a
separate expiring break-glass mechanism only if ordinary Hermes plus Tailscale
SSH proves inadequate.

### Messaging and automation

The official gateway is a separate long-running process from the dashboard.
Use its supported identity allowlists, session controls, tool settings, normal
Hermes configuration, and upstream-generated `ai.hermes.gateway` LaunchAgent.
Home Stack records and verifies that service but does not generate a competing
plist: upstream already owns graceful drain, restart throttling, PATH capture,
profile scoping, resource limits, and update/restart handoff. Start with no
platform or one allowlisted direct channel and expand permissions in response
to actual use. Adding a channel may require an interactive bot/account login;
never enable `GATEWAY_ALLOW_ALL_USERS` as a shortcut.

Cron begins with deterministic read-only reports under `cron_mode: deny`.
Webhooks stay disabled until route-specific profiles, HMAC/timestamp/replay
checks, rate and size limits, idempotency, and prompt-injection tests exist.

## Consequence Classes

Operations are classified by effect rather than by which CLI implements them:

- **Observe:** status, bounded logs, listeners, launchd state, `hs doctor`,
  registry drift, and deployment preview. Normally automatic.
- **Reversible:** restart a named managed service, stop a runaway worker, or
  retry a failed bounded job. Require an iPhone/dashboard confirmation.
- **Consequential:** commit/push, config mutation, messages, purchases, account
  changes, or infrastructure apply. Show the exact target and effect, then
  require immediate explicit confirmation.
- **Break-glass:** temporary broad shell/host authority. Local by default and
  time-limited if remote support is later implemented.

LLM-based `smart` approval improves usability but is not the security boundary.
In Hermes the smart reviewer runs only after Hermes' built-in detector
flags a command; operator policy text does not turn otherwise-unrecognized
commands into approval prompts. Keep `cron_mode: deny`, no global YOLO/off
mode, and no permanent broad command allowlist. Use the supported hard-deny
floor for obvious direct credential, Keychain-password, and environment dumps.
Treat confirmation for purchases, Git publication, Home Stack apply/install,
and cloud/DNS administration as an operating contract rather than claiming the
current terminal detector enforces it universally. Broad remote terminal access
means the authenticated Hermes user is trusted at the logged-in macOS user's
authority; it is not an OS sandbox.

## Home Stack Recovery

Remote-operator recovery should prefer existing typed Home Stack commands and
previews over ad hoc shell text. This does not require a wrapper per CLI:

- Observe Admin/service state and run bounded diagnostics automatically.
- Restart a named managed service only after confirmation.
- Show deploy/sync/plist/Caddy changes as an infra-review preview; never apply
  from a vague natural-language request.
- If Caddy fails, retain the raw authenticated Tailnet Hermes endpoint.
- If Admin fails, a reviewed operator command may inspect/restart Admin through
  launchd.
- If Hermes fails, launchd and a separately maintained Tailscale SSH path are
  the break-glass mechanisms; Hermes cannot repair its own dead process.
- If Tailscale fails, there is intentionally no public Hermes fallback.

## General CLI access

Hermes receives the normal user command path and may discover CLI syntax with
`--help`, just as a person or coding agent would. Home Stack does not register,
template, or wrap every CLI. The approval policy classifies effects across all
commands: reading/searching is ordinarily automatic; external communication,
purchases, credential access, persistent configuration, Git publication, and
infrastructure mutation require a fresh confirmation showing the concrete
effect.

Add a wrapper only after direct use exposes a repeated problem that the
underlying CLI and Hermes cannot address: idempotency/replay protection,
bounded output, or a particularly hazardous workflow. For example, a
purchasing CLI may be used directly for discovery and cart work, but a final
order should show merchant, items, address effect, fees, tip, and total for
confirmation immediately before purchase. The same general policy applies to
future CLIs without changing the Home Stack registry.

## Models, Providers, and Cost

A model-routing/aggregation provider is a first-class candidate for
personal/dispatcher and unattended work. Prefer a dedicated Hermes key/account
scope with hard provider-side spend limits, usage alerts, no-training policy,
and explicit provider data-collection and routing constraints. Reusing an
OpenCode key is allowed as a reviewed bootstrap, but a new key gives better
attribution, revocation, and budgets.

An interactive coding-assistant OAuth login is for interactive supervised
coding rather than an unattended availability or budget fallback. Choose live
models through a task evaluation rather than copying stale OpenCode model
names.

Pin every auxiliary task explicitly. `auto` can inherit the main model or use
fallback/discovery, and main provider routing is not a privacy/cost policy for
every auxiliary call. Trace one representative personal, coding, and automation
turn and reject the configuration if any model/provider call is unexpected.

## Memory, Skills, MCP, Browser, and Computer Use

Start with built-in local memory, `memory.write_approval: true`, skill-write
approval, and separate personal/coding state. Do not automatically promote web,
gateway, or repository content into durable memory. Enable an external memory
provider only after export/delete/retention/backup testing and a sensitive-
canary test.

Start with no optional MCP servers. Pin and review each server/skill, whitelist
specific tools, pass no broad environment, and do not auto-install catalog
entries. Gateway/automation lanes do not inherit MCP toolsets by default.

Signed-in browser and macOS computer-use are local supervised capabilities,
not background or gateway tools. A clean dedicated browser profile is required
before coding automation receives browser access.

## Staged Delivery

1. Harden the existing dashboard wrapper, reconcile source/version docs, and
   repeat raw/HTTPS auth, listener, WebSocket, restart, and peer-health checks.
2. Configure the personal/remote-operator baseline: local memory approvals,
   useful general tools, explicit model/aux routing, provider budgets, and
   backups.
3. Exercise existing Home Stack status, doctor, preview, and lifecycle commands
   through Hermes; add structure only where direct use repeatedly fails.
4. Validate general CLI discovery and consequence-aware approvals. Add narrow
   wrappers only for typed recovery, idempotency, or repeatedly hazardous
   operations—not as an application allowlist.
5. Exercise Codex/Claude/OpenCode delegation using their native controls; adopt
   worktrees for concurrent writers and add coordination only if needed.
6. Run the official upstream-supervised gateway, then add one allowlisted
   messaging channel only if its UX is useful beyond the dashboard or
   compatible mobile client.
7. Add deterministic read-only cron, then individually reviewed mutating
   workflows. Webhooks and computer-use remain last.

Each phase needs repository/config review before mutation and live verification
after deployment. These are pragmatic defaults, not a requirement to build
custom policy infrastructure before Hermes can be useful. If normal use is too
constrained, broaden the relevant native Hermes setting deliberately, observe
the result, and retain only controls that solve a demonstrated problem.
