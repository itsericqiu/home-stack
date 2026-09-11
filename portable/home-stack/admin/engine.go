package main

import (
	"context"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"

	"gopkg.in/yaml.v3"
)

var registryMu sync.Mutex

type Registry struct {
	Services map[string]Service `yaml:"services"`
}

type Service struct {
	DisplayName   string            `yaml:"display_name"`
	Kind          string            `yaml:"kind"`
	Type          string            `yaml:"type"`
	Subdomain     string            `yaml:"subdomain,omitempty"`
	Host          string            `yaml:"host,omitempty"`
	Upstream      string            `yaml:"upstream,omitempty"`
	ProxyIdentity string            `yaml:"proxy_identity,omitempty" json:"proxy_identity,omitempty"`
	Auth          string            `yaml:"auth,omitempty" json:"auth,omitempty"`
	Root          string            `yaml:"root,omitempty"`
	APIPath       string            `yaml:"api_path,omitempty" json:"api_path,omitempty"`
	Lifecycle     string            `yaml:"lifecycle,omitempty" json:"lifecycle,omitempty"`
	Interval      int               `yaml:"interval_seconds,omitempty" json:"interval_seconds,omitempty"`
	Plist         string            `yaml:"plist,omitempty" json:"plist,omitempty"`
	Binary        string            `yaml:"binary,omitempty" json:"binary,omitempty"`
	Args          []string          `yaml:"args,omitempty"`
	WorkingDir    string            `yaml:"working_dir,omitempty"`
	Env           map[string]string `yaml:"env,omitempty"`
	Health        HealthConfig      `yaml:"health"`
	// URL is never read from the registry (yaml:"-"): it is computed by the
	// catalog writer (buildCatalog) from RoutableURL and injected only into
	// the catalog.json artifact, so a shell helper can read one authoritative
	// key instead of re-deriving the subdomain/host composition itself. Like
	// the four HOME_STACK_* keys GenerateLaunchdPlist injects, it cannot be
	// hand-set from services.yaml.
	URL string `yaml:"-" json:"url,omitempty"`
	// Enabled is a pointer so absence (the common case: every service that
	// predates this field) is distinguishable from an explicit false. nil
	// means enabled — see IsEnabled.
	Enabled *bool `yaml:"enabled,omitempty" json:"enabled,omitempty"`
	// Install is the migration/upgrade manifest for a service whose binary is
	// operator-installed rather than vendored: how it got there, what it is
	// pinned to, and how to read its live version. It drives `hs upgrade`
	// (scripts/lib/upgrade.sh) and `hs doctor`'s pin-drift check. Absent means
	// the service is not upgrade-tracked (nothing changes for it). The catalog
	// carries this block unmodified so the shell reads it from catalog.json
	// the same way it already reads `url` — see home_stack_service_url.
	Install *InstallSpec `yaml:"install,omitempty" json:"install,omitempty"`
}

// installMethod is the closed set of ways an operator-installed binary got
// onto the bundle. Like auth: and proxy_identity:, this is a fixed idiom, not
// a free-form directive surface: `hs upgrade` has one reviewed procedure per
// method, hand-written in scripts/lib/upgrade.sh, and an unrecognized method
// has no procedure to run.
type installMethod = string

const (
	installMethodGithubRelease installMethod = "github-release"
	installMethodXcaddy        installMethod = "xcaddy"
	installMethodSourceGo      installMethod = "source-go"
	installMethodNpmGlobal     installMethod = "npm-global"
	installMethodOpencode      installMethod = "opencode"
	installMethodHermesPinned  installMethod = "hermes-pinned"
	installMethodBrew          installMethod = "brew"
)

// InstallSpec is the optional per-service migration/upgrade manifest. Pins
// are deployment-specific (the reviewed target version for THIS host), so
// they live in the owner's profile like every other identity value, not in
// profiles/default/services.yaml's examples.
type InstallSpec struct {
	// Method selects which of scripts/lib/upgrade.sh's reviewed procedures
	// applies. Closed enum -- see installMethod* above.
	Method string `yaml:"method" json:"method"`
	// Source is a repo ("owner/repo"), npm package name, or Homebrew formula,
	// depending on Method. Always required: every method needs to know what
	// upstream thing it is comparing/fetching against.
	Source string `yaml:"source" json:"source"`
	// Pin is the reviewed target version, tag, or full commit -- deployment
	// state, so it is optional here (a registry entry may track upgrades
	// without yet declaring a reviewed pin) but expected to be set in a real
	// profile once an operator has reviewed a version.
	Pin string `yaml:"pin,omitempty" json:"pin,omitempty"`
	// VersionCmd is a shell command whose first line of output names the
	// live version (extracted by scripts/lib/upgrade.sh via regex: a
	// dotted-numeric version or a 7-40 hex commit). Run with the bundle
	// bin/ and PATH prepended, never with HOME_STACK_* secrets.
	VersionCmd string `yaml:"version_cmd,omitempty" json:"version_cmd,omitempty"`
	// Asset is the github-release asset name pattern, e.g.
	// "pocket-id_darwin_{arch}" -- {version} and {arch} are substituted by
	// scripts/lib/upgrade.sh before matching it against the release's assets.
	// Required (with Binary) for method: github-release only.
	Asset string `yaml:"asset,omitempty" json:"asset,omitempty"`
	// Binary is where the installed artifact lives, relative to the bundle
	// directory (e.g. "bin/pocket-id"). Required for github-release; used by
	// xcaddy and source-go too, but Validate does not enforce it there since
	// those methods' procedures fail loudly on their own if it is missing.
	Binary string `yaml:"binary,omitempty" json:"binary,omitempty"`
}

// validMethods for InstallSpec.Method, in error-message order.
var installMethods = []string{
	installMethodGithubRelease,
	installMethodXcaddy,
	installMethodSourceGo,
	installMethodNpmGlobal,
	installMethodOpencode,
	installMethodHermesPinned,
	installMethodBrew,
}

// validateInstall enforces the closed method enum, the fields every method
// needs (source), and the fields only github-release's procedure can run
// without (asset, binary -- it has no other way to know what to download or
// where to put it).
func validateInstall(serviceName string, in *InstallSpec) error {
	if in == nil {
		return nil
	}
	valid := false
	for _, m := range installMethods {
		if in.Method == m {
			valid = true
			break
		}
	}
	if !valid {
		return fmt.Errorf("service %q install.method %q is not one of %s", serviceName, in.Method, strings.Join(installMethods, ", "))
	}
	if err := validateToken("install.source", in.Source, false); err != nil {
		return fmt.Errorf("service %q invalid %w", serviceName, err)
	}
	if err := validateToken("install.pin", in.Pin, true); err != nil {
		return fmt.Errorf("service %q invalid %w", serviceName, err)
	}
	if err := validateToken("install.version_cmd", in.VersionCmd, true); err != nil {
		return fmt.Errorf("service %q invalid %w", serviceName, err)
	}
	if in.Method == installMethodGithubRelease {
		if err := validateToken("install.asset", in.Asset, false); err != nil {
			return fmt.Errorf("service %q invalid %w (required for install.method: github-release)", serviceName, err)
		}
		if err := validateToken("install.binary", in.Binary, false); err != nil {
			return fmt.Errorf("service %q invalid %w (required for install.method: github-release)", serviceName, err)
		}
	}
	return nil
}

// ResolvedHost returns the FQDN this service occupies under parentDomain.
func (svc Service) ResolvedHost(parentDomain string) string {
	if svc.Subdomain != "" {
		return svc.Subdomain + "." + parentDomain
	}
	return svc.Host
}

// RoutableHost is ResolvedHost, blank when there is no subdomain/host to
// begin with or when it resolves to a wildcard (e.g. dev-gateway's "*.dev",
// or "caddy"'s own "*") -- a wildcard is not one service's own address, so
// there is no single FQDN to hand back. GenerateLaunchdPlist (for
// HOME_STACK_SELF_HOST), the Portal catalog projection, and collectServices's
// route check each used to repeat this exact test inline; they now all call
// this one definition.
func (svc Service) RoutableHost(parentDomain string) string {
	host := svc.ResolvedHost(parentDomain)
	if host == "" || strings.HasPrefix(host, "*.") {
		return ""
	}
	return host
}

// RoutableURL is RoutableHost with the "https://" prefix Caddy always
// terminates TLS with, empty unless the service is also enabled: a disabled
// service gets no route from the engine (see generatesAgentPlist /
// GenerateCaddyfile), so a URL for it would be one that 404s.
func (svc Service) RoutableURL(parentDomain string) string {
	host := svc.RoutableHost(parentDomain)
	if host == "" || !svc.IsEnabled() {
		return ""
	}
	return "https://" + host
}

// IsEnabled reports whether this service should be active. Absent (nil)
// means enabled: the field is opt-out, so a registry entry written before
// enabled: existed keeps running without edits.
func (svc Service) IsEnabled() bool {
	return svc.Enabled == nil || *svc.Enabled
}

// generatesAgentPlist reports whether this service gets a per-service
// (agent) launchd plist. syncSystem, registry.go Diff, and registry.go Apply
// each used to repeat "svc.Type == \"system\" || svc.Type == \"static\"" inline
// to answer this; a disabled service now joins that skip list in the one
// place, rather than three. It stays registered, validated, and in the
// catalog — the engine just emits nothing for launchd to load. type "system"
// gets a daemon plist instead (a different file, a different directory), not
// an agent one, so it is excluded here regardless of enabled.
func (svc Service) generatesAgentPlist() bool {
	return svc.IsEnabled() && svc.Type != "system" && svc.Type != "static"
}

// Auth modes a routable service may opt into. The set is closed: the engine
// emits one fixed Caddy block per value, so the registry never becomes a
// free-form directive surface (same rule as proxy_identity).
const (
	// authNone leaves the route ungated. Absent auth means this.
	authNone = "none"
	// authTailnet gates on Tailscale identity resolved from the connecting
	// peer. Zero interaction for a user-owned tailnet device; tagged
	// (machine) nodes are rejected by the provider itself.
	authTailnet = "tailnet"
	// authSSO defers to the broker's forward-auth endpoint, which owns the
	// login ceremony and the session.
	authSSO = "sso"
	// authTailnetOrSSO tries tailnet identity first and falls back to the
	// broker for anything arriving off-tailnet.
	authTailnetOrSSO = "tailnet-or-sso"
)

// authBrokerService is the registry entry whose upstream receives forward_auth
// requests. Looked up by name the same way the portal projection finds admin.
const authBrokerService = "tinyauth"

// authIdentityConsumer is the one upstream that verifies ingress-resolved
// identity headers against HOME_STACK_ADMIN_PROXY_SECRET. The secret is the
// capability to be believed by Admin, so it is sent to this upstream only:
// handing it to every gated backend would let any of them impersonate
// arbitrary identities to Admin over loopback.
const authIdentityConsumer = "admin"

// tailnetCGNATRange is Tailscale's CGNAT allocation. It selects which lane a
// request takes in authTailnetOrSSO; it is not the authorization decision —
// tailscale_auth still resolves identity inside the tailnet lane.
const tailnetCGNATRange = "100.64.0.0/10"

// RequiresAuthBroker reports whether this service's auth mode needs a
// forward-auth broker upstream to be present in the registry.
func (svc Service) RequiresAuthBroker() bool {
	return svc.Auth == authSSO || svc.Auth == authTailnetOrSSO
}

// defaultTaskInterval is how often a scheduled task runs when the registry
// entry does not set interval_seconds.
const defaultTaskInterval = 3600

// IsScheduledTask reports whether this service is a periodic job that exits when
// finished, rather than a daemon that should stay resident.
func (svc Service) IsScheduledTask() bool {
	return svc.Type == "task" || svc.Kind == "scheduled"
}

// StartInterval returns the launchd StartInterval, in seconds, for a scheduled
// task, falling back to defaultTaskInterval when unset or invalid.
func (svc Service) StartInterval() int {
	if svc.Interval > 0 {
		return svc.Interval
	}
	return defaultTaskInterval
}

type HealthConfig struct {
	Port    int    `yaml:"port,omitempty"`
	HTTPURL string `yaml:"http_url,omitempty"`
}

var (
	serviceNamePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)
	envKeyPattern      = regexp.MustCompile(`^[A-Z_][A-Z0-9_]*$`)
	hostPattern        = regexp.MustCompile(`^(\*\.)?[a-z0-9][a-z0-9.-]*[a-z0-9]$`)
	identifierPattern  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.-]*$`)
	subdomainPattern   = regexp.MustCompile(`^(\*|\*\.[a-z0-9][a-z0-9.-]*[a-z0-9]|[a-z0-9][a-z0-9.-]*[a-z0-9]|[a-z0-9])$`)
)

// validateEnv ensures every mandatory profile variable is present.
// Returns a single error listing all missing keys.
func validateEnv() error {
	required := []string{
		"HOME_STACK_PARENT_DOMAIN",
		"HOME_STACK_TAILNET_IP",
		"HOME_STACK_ACME_EMAIL",
		"HOME_STACK_OWNER_HOME",
		"HOME_STACK_IDENTIFIER_PREFIX",
		"HOME_STACK_ADMIN_USERNAME",
	}
	var missing []string
	for _, k := range required {
		if os.Getenv(k) == "" {
			missing = append(missing, k)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing mandatory environment variables: %s; populate profiles/<name>/home-stack.env or run hs init", strings.Join(missing, ", "))
	}
	return nil
}

func loadRegistry(path string) (*Registry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var r Registry
	if err := yaml.Unmarshal(data, &r); err != nil {
		return nil, err
	}
	parentDomain, err := requiredParentDomain()
	if err != nil {
		return nil, err
	}
	if err := r.Validate(parentDomain); err != nil {
		return nil, err
	}
	return &r, nil
}

func (r *Registry) saveRegistry(path string) error {
	data, err := yaml.Marshal(r)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".services-*.yaml")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0644); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

func expandPath(path, home string) string {
	if strings.HasPrefix(path, "~/") {
		return filepath.Join(home, path[2:])
	}
	return path
}

func requiredParentDomain() (string, error) {
	v := os.Getenv("HOME_STACK_PARENT_DOMAIN")
	if v == "" {
		return "", fmt.Errorf("HOME_STACK_PARENT_DOMAIN is not set")
	}
	return v, nil
}

func (r *Registry) Validate(parentDomain string) error {
	for name, svc := range r.Services {
		if !serviceNamePattern.MatchString(name) {
			return fmt.Errorf("invalid service name %q", name)
		}
		if svc.Type == "" {
			return fmt.Errorf("service %q missing type", name)
		}
		// enabled: false is opt-out for most services, but a few are load-
		// bearing enough that "disabled" is not a real state for them: the
		// engine would simply stop emitting the thing that makes the rest of
		// the stack reachable at all, with nothing downstream that notices.
		if svc.Type == "system" && !svc.IsEnabled() {
			return fmt.Errorf("service %q is type \"system\" (the ingress) and cannot be disabled; install-launchd.sh hard-requires its daemon plist to exist", name)
		}
		if name == "admin" && !svc.IsEnabled() {
			return fmt.Errorf("service %q cannot be disabled; it owns the Portal projection and the control plane", name)
		}
		switch svc.Lifecycle {
		case "", "managed", "external", "custom":
			// valid; empty means external (route-only)
		default:
			return fmt.Errorf("service %q has unknown lifecycle %q (want managed, external, or custom)", name, svc.Lifecycle)
		}
		switch svc.ProxyIdentity {
		case "":
			// Preserve the incoming Host and Origin headers (Caddy default).
		case "upstream":
			if svc.Type != "proxy" && svc.Type != "split" {
				return fmt.Errorf("service %q proxy_identity is only valid for proxy or split services", name)
			}
		default:
			return fmt.Errorf("service %q has unknown proxy_identity %q (want upstream)", name, svc.ProxyIdentity)
		}
		switch svc.Auth {
		case "", authNone:
			// Ungated. Loopback-only upstreams and the sanitized portal
			// projections rely on this staying the default.
		case authTailnet, authSSO, authTailnetOrSSO:
			// Auth is enforced by Caddy on the way in, so it only means
			// anything for a service Caddy actually routes. A service
			// reachable solely over loopback would silently keep serving
			// unauthenticated traffic, so refuse rather than imply cover.
			if svc.Subdomain == "" && svc.Host == "" {
				return fmt.Errorf("service %q sets auth %q but has no subdomain or host; Caddy cannot gate a route it does not serve", name, svc.Auth)
			}
			if svc.RequiresAuthBroker() {
				broker, ok := r.Services[authBrokerService]
				if !ok {
					return fmt.Errorf("service %q sets auth %q but no %q service is registered to forward auth to", name, svc.Auth, authBrokerService)
				}
				if broker.Upstream == "" {
					return fmt.Errorf("service %q sets auth %q but %q has no upstream", name, svc.Auth, authBrokerService)
				}
			}
		default:
			return fmt.Errorf("service %q has unknown auth %q (want none, tailnet, sso, or tailnet-or-sso)", name, svc.Auth)
		}
		if err := validateDisplayToken("display_name", svc.DisplayName); err != nil {
			return fmt.Errorf("service %q invalid display_name: %w", name, err)
		}
		if err := validateDisplayToken("kind", svc.Kind); err != nil {
			return fmt.Errorf("service %q invalid kind: %w", name, err)
		}
		switch svc.Type {
		case "system", "task":
			// no route shape required
		case "split":
			// split requires both upstream (for API) and root (for static files)
			if svc.Subdomain == "" && svc.Host == "" {
				return fmt.Errorf("service %q must set exactly one of subdomain or host", name)
			}
			if svc.Subdomain != "" && svc.Host != "" {
				return fmt.Errorf("service %q sets both subdomain and host; pick one", name)
			}
			if svc.Subdomain != "" {
				if err := validateSubdomain(name, svc.Subdomain); err != nil {
					return err
				}
			} else {
				if err := validateHost(name, svc.Host); err != nil {
					return err
				}
				if hostOverlapsParent(svc.Host, parentDomain) {
					return fmt.Errorf("service %q host %q overlaps parent_domain %q; use subdomain instead", name, svc.Host, parentDomain)
				}
			}
			if err := validateCaddyToken("upstream", svc.Upstream, false); err != nil {
				return fmt.Errorf("service %q invalid upstream: %w", name, err)
			}
			if err := validateCaddyToken("root", svc.Root, false); err != nil {
				return fmt.Errorf("service %q invalid root: %w", name, err)
			}
		case "static":
			if svc.Subdomain == "" && svc.Host == "" {
				return fmt.Errorf("service %q must set exactly one of subdomain or host", name)
			}
			if svc.Subdomain != "" && svc.Host != "" {
				return fmt.Errorf("service %q sets both subdomain and host; pick one", name)
			}
			if svc.Subdomain != "" {
				if err := validateSubdomain(name, svc.Subdomain); err != nil {
					return err
				}
			} else {
				if err := validateHost(name, svc.Host); err != nil {
					return err
				}
				if hostOverlapsParent(svc.Host, parentDomain) {
					return fmt.Errorf("service %q host %q overlaps parent_domain %q; use subdomain instead", name, svc.Host, parentDomain)
				}
			}
			if err := validateCaddyToken("root", svc.Root, false); err != nil {
				return fmt.Errorf("service %q invalid root: %w", name, err)
			}
		case "proxy":
			// proxy services may be internal-only (neither subdomain nor host).
			if svc.Subdomain != "" && svc.Host != "" {
				return fmt.Errorf("service %q sets both subdomain and host; pick one", name)
			}
			if svc.Subdomain != "" {
				if err := validateSubdomain(name, svc.Subdomain); err != nil {
					return err
				}
			} else if svc.Host != "" {
				if err := validateHost(name, svc.Host); err != nil {
					return err
				}
				if hostOverlapsParent(svc.Host, parentDomain) {
					return fmt.Errorf("service %q host %q overlaps parent_domain %q; use subdomain instead", name, svc.Host, parentDomain)
				}
			}
			if err := validateCaddyToken("upstream", svc.Upstream, false); err != nil {
				return fmt.Errorf("service %q invalid upstream: %w", name, err)
			}
		default:
			return fmt.Errorf("service %q has unsupported type %q", name, svc.Type)
		}
		if svc.Binary != "" {
			if err := validateToken("binary", svc.Binary, true); err != nil {
				return fmt.Errorf("service %q invalid binary: %w", name, err)
			}
		}
		if svc.WorkingDir != "" {
			if err := validateToken("working_dir", svc.WorkingDir, true); err != nil {
				return fmt.Errorf("service %q invalid working_dir: %w", name, err)
			}
		}
		for _, arg := range svc.Args {
			if err := validateToken("arg", arg, true); err != nil {
				return fmt.Errorf("service %q invalid arg: %w", name, err)
			}
		}
		for key, value := range svc.Env {
			if !envKeyPattern.MatchString(key) {
				return fmt.Errorf("service %q invalid env key %q", name, key)
			}
			// HOME_STACK_* is the engine's namespace. A service that set
			// HOME_STACK_PROFILE would load one profile while its Caddyfile
			// route, ports and catalog entry came from another, with nothing
			// to detect the split.
			if strings.HasPrefix(key, "HOME_STACK_") {
				return fmt.Errorf("service %q may not set %q: HOME_STACK_* is reserved for the engine", name, key)
			}
			if err := validateToken("env value", value, true); err != nil {
				return fmt.Errorf("service %q invalid env value for %q: %w", name, key, err)
			}
		}
		if err := validateInstall(name, svc.Install); err != nil {
			return err
		}
	}
	// A disabled auth broker is not caught by the per-service auth: sso /
	// tailnet-or-sso check above (that only requires the broker to exist and
	// have an upstream, not that it be enabled). GenerateCaddyfile still
	// unconditionally emits forward_auth to the broker's upstream for every
	// dependent, disabled or not, so every one of those routes would 502
	// against an upstream nothing supervises any more.
	if broker, ok := r.Services[authBrokerService]; ok && !broker.IsEnabled() {
		var dependents []string
		for depName, depSvc := range r.Services {
			if depName == authBrokerService || !depSvc.IsEnabled() {
				continue
			}
			if depSvc.RequiresAuthBroker() {
				dependents = append(dependents, depName)
			}
		}
		if len(dependents) > 0 {
			sort.Strings(dependents)
			return fmt.Errorf("service %q (the auth broker) is disabled, but %s still depend on it for auth; GenerateCaddyfile would still emit forward_auth to a disabled upstream, so every one of those routes would 502", authBrokerService, strings.Join(dependents, ", "))
		}
	}
	return nil
}

func validateHost(name, host string) error {
	if host == "" {
		return fmt.Errorf("service %q missing host", name)
	}
	if strings.ContainsAny(host, "\r\n\t ") || !hostPattern.MatchString(host) {
		return fmt.Errorf("service %q invalid host %q", name, host)
	}
	return nil
}

func validateSubdomain(name, sub string) error {
	if !subdomainPattern.MatchString(sub) {
		return fmt.Errorf("service %q invalid subdomain %q", name, sub)
	}
	return nil
}

func hostOverlapsParent(host, parent string) bool {
	// Exact match or any subdomain of parent => overlaps.
	if host == parent {
		return true
	}
	if strings.HasSuffix(host, "."+parent) {
		return true
	}
	if strings.HasPrefix(host, "*.") && strings.HasSuffix(host, parent) {
		return true
	}
	return false
}

func validateDisplayToken(field, value string) error {
	if strings.ContainsAny(value, "\r\n\x00") {
		return fmt.Errorf("%s contains control characters", field)
	}
	return nil
}

func validateToken(field, value string, allowEmpty bool) error {
	if value == "" {
		if allowEmpty {
			return nil
		}
		return fmt.Errorf("%s is required", field)
	}
	if strings.ContainsAny(value, "\r\n\x00") {
		return fmt.Errorf("%s contains control characters", field)
	}
	return nil
}

func validateCaddyToken(field, value string, allowEmpty bool) error {
	if err := validateToken(field, value, allowEmpty); err != nil {
		return err
	}
	if value != "" && strings.ContainsAny(value, " \t") {
		return fmt.Errorf("%s contains whitespace", field)
	}
	return nil
}

func caddyMatcherName(name string) string {
	return strings.ReplaceAll(name, "-", "_")
}

// writeReverseProxy emits a proxy route. proxy_identity: upstream is a narrow
// compatibility mode for upstreams that enforce DNS-rebinding checks against
// the address they bind. It preserves Caddy's default X-Forwarded-* headers,
// while presenting the selected upstream as Host and browser WebSocket Origin.
//
// identityHeaders adds the resolved Tailscale identity as X-Webauth-*, which is
// how an upstream learns who the caller is. It is only meaningful beneath a
// tailscale_auth block: the placeholders resolve to empty otherwise, so the
// caller — not this function — decides when they apply.
func writeReverseProxy(sb *strings.Builder, indent, name string, svc Service, identityHeaders bool) {
	var headers []string
	if svc.ProxyIdentity == "upstream" {
		headers = append(headers,
			"header_up Host {upstream_hostport}",
			"header_up Origin http://{upstream_hostport}")
	}
	if identityHeaders {
		headers = append(headers,
			"header_up X-Webauth-User {http.auth.user.tailscale_login}",
			"header_up X-Webauth-Email {http.auth.user.tailscale_user}",
			"header_up X-Webauth-Name {http.auth.user.tailscale_name}",
			// This lane never sets Remote-*; without these deletes a caller
			// could smuggle its own broker-shaped identity through to the
			// upstream alongside the genuinely resolved X-Webauth-* values.
			"header_up -Remote-User",
			"header_up -Remote-Email",
			"header_up -Remote-Groups",
			"header_up -Remote-Name")
	} else if svc.RequiresAuthBroker() {
		// The broker lane's Remote-* headers are safe -- forward_auth's
		// copy_headers compiles to delete-then-set, displacing anything the
		// caller sent. The tailnet-shaped headers are not set by anything in
		// this lane, and Admin prefers X-Webauth-User over Remote-User, so a
		// caller-supplied value would outrank the broker's verified identity.
		headers = append(headers,
			"header_up -X-Webauth-User",
			"header_up -X-Webauth-Email",
			"header_up -X-Webauth-Name")
	}
	if name == authIdentityConsumer && (identityHeaders || svc.RequiresAuthBroker()) {
		// Proof that these identity headers came through this ingress. The
		// upstream listens on loopback, so without it any local process could
		// set X-Webauth-User and be believed. Emitted as an env placeholder so
		// the secret never lands in the generated Caddyfile -- same handling as
		// the Cloudflare token. Sent only to the consumer that verifies it.
		headers = append(headers,
			"header_up X-Home-Stack-Proxy-Auth {env.HOME_STACK_ADMIN_PROXY_SECRET}")
	}
	if len(headers) == 0 {
		sb.WriteString(fmt.Sprintf("%sreverse_proxy %s\n", indent, svc.Upstream))
		return
	}
	sb.WriteString(fmt.Sprintf("%sreverse_proxy %s {\n", indent, svc.Upstream))
	for _, h := range headers {
		sb.WriteString(fmt.Sprintf("%s\t%s\n", indent, h))
	}
	sb.WriteString(fmt.Sprintf("%s}\n", indent))
}

// writeForwardAuth emits the fixed forward_auth block for the broker. Caddy
// copies a non-2xx broker response straight back to the client, so the broker
// itself owns the redirect-to-login behavior; nothing here needs to encode it.
func writeForwardAuth(sb *strings.Builder, indent, brokerUpstream string) {
	sb.WriteString(fmt.Sprintf("%sforward_auth %s {\n", indent, brokerUpstream))
	sb.WriteString(fmt.Sprintf("%s\turi /api/auth/caddy\n", indent))
	sb.WriteString(fmt.Sprintf("%s\tcopy_headers Remote-User Remote-Email Remote-Groups Remote-Name\n", indent))
	sb.WriteString(fmt.Sprintf("%s}\n", indent))
}

func validateIdentifierPrefix(prefix string) error {
	if !identifierPattern.MatchString(prefix) {
		return fmt.Errorf("invalid identifier prefix %q", prefix)
	}
	return nil
}

func xmlText(value string) string {
	var b strings.Builder
	_ = xml.EscapeText(&b, []byte(value))
	return b.String()
}

// GenerateCaddyfile produces the Caddyfile content based on the registry.
func (r *Registry) GenerateCaddyfile(email, tailnetIP, ownerHome, parentDomain string) string {
	var sb strings.Builder
	portalProjectionUpstream := ""
	if admin, ok := r.Services["admin"]; ok {
		portalProjectionUpstream = admin.Upstream
	}

	// Global options. Runtime logs at WARN: at INFO Caddy writes a line for
	// every admin-API request, and the admin service polls /config/ for
	// health, which buried real errors in the daemon log.
	sb.WriteString(fmt.Sprintf("{\n\temail %s\n\tlog {\n\t\tlevel WARN\n\t}\n}\n\n", email))

	// Cloudflare TLS Snippet
	sb.WriteString("(cloudflare_tls) {\n")
	sb.WriteString("\ttls {\n")
	sb.WriteString("\t\tdns cloudflare {env.CLOUDFLARE_API_TOKEN}\n")
	sb.WriteString("\t}\n}\n\n")

	// Main Wildcard Block
	sb.WriteString(fmt.Sprintf("*.%s {\n", parentDomain))
	sb.WriteString(fmt.Sprintf("\tbind %s\n", tailnetIP))
	sb.WriteString("\timport cloudflare_tls\n\n")

	// Sort service names for deterministic output
	var keys []string
	for k := range r.Services {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	for _, name := range keys {
		svc := r.Services[name]
		if !svc.IsEnabled() {
			continue
		}
		if svc.Subdomain == "" && svc.Host == "" {
			continue
		}
		resolvedHost := svc.ResolvedHost(parentDomain)
		if resolvedHost == "*."+parentDomain {
			continue
		}

		// Handle specific wildcards like *.dev.home.example.com
		hostLabel := caddyMatcherName(name)
		if strings.HasPrefix(resolvedHost, "*.") {
			hostLabel = "wildcard_" + hostLabel
		}

		sb.WriteString(fmt.Sprintf("\t@%s host %s\n", hostLabel, resolvedHost))
		sb.WriteString(fmt.Sprintf("\thandle @%s {\n", hostLabel))
		r.writeAuthenticatedBody(&sb, "\t\t", name, svc, ownerHome, portalProjectionUpstream, hostLabel)
		sb.WriteString("\t}\n\n")
	}

	// Catch-all
	sb.WriteString("\thandle {\n\t\tabort\n\t}\n")
	sb.WriteString("}\n")

	return sb.String()
}

// writeAuthenticatedBody emits a routed service's handlers, wrapped in whatever
// auth gate its registry entry asks for. The gate goes first inside the handle
// block so Caddy runs it before the proxy or file server it protects.
func (r *Registry) writeAuthenticatedBody(sb *strings.Builder, indent, name string, svc Service, ownerHome, portalProjectionUpstream, hostLabel string) {
	switch svc.Auth {
	case authTailnet:
		sb.WriteString(fmt.Sprintf("%stailscale_auth\n", indent))
		writeServiceBody(sb, indent, name, svc, ownerHome, portalProjectionUpstream, true)

	case authSSO:
		writeForwardAuth(sb, indent, r.Services[authBrokerService].Upstream)
		writeServiceBody(sb, indent, name, svc, ownerHome, portalProjectionUpstream, false)

	case authTailnetOrSSO:
		// The remote_ip match only selects a lane. Authorization inside the
		// tailnet lane is still tailscale_auth resolving the peer, so a
		// spoofed source address gains nothing — and packets only reach this
		// listener over the WireGuard interface in the first place.
		matcher := "@" + hostLabel + "_tailnet"
		sb.WriteString(fmt.Sprintf("%s%s remote_ip %s\n", indent, matcher, tailnetCGNATRange))
		sb.WriteString(fmt.Sprintf("%shandle %s {\n", indent, matcher))
		sb.WriteString(fmt.Sprintf("%s\ttailscale_auth\n", indent))
		writeServiceBody(sb, indent+"\t", name, svc, ownerHome, portalProjectionUpstream, true)
		sb.WriteString(fmt.Sprintf("%s}\n", indent))
		sb.WriteString(fmt.Sprintf("%shandle {\n", indent))
		writeForwardAuth(sb, indent+"\t", r.Services[authBrokerService].Upstream)
		writeServiceBody(sb, indent+"\t", name, svc, ownerHome, portalProjectionUpstream, false)
		sb.WriteString(fmt.Sprintf("%s}\n", indent))

	default:
		// "" and authNone: unchanged output, so existing routes stay
		// byte-identical to what they generated before auth existed.
		writeServiceBody(sb, indent, name, svc, ownerHome, portalProjectionUpstream, false)
	}
}

// writeServiceBody emits the handlers for a service's shape (static, proxy, or
// split) at the given indent. It is indent-aware because an auth gate may nest
// it one level deeper inside a lane.
func writeServiceBody(sb *strings.Builder, indent, name string, svc Service, ownerHome, portalProjectionUpstream string, identityHeaders bool) {
	switch svc.Type {
	case "static":
		root := expandPath(svc.Root, ownerHome)
		if name == "portal" && portalProjectionUpstream != "" {
			sb.WriteString(fmt.Sprintf("%s@portal_projections path /.well-known/home-stack/catalog.json /.well-known/home-stack/status.json\n", indent))
			sb.WriteString(fmt.Sprintf("%shandle @portal_projections {\n", indent))
			sb.WriteString(fmt.Sprintf("%s\treverse_proxy %s\n", indent, portalProjectionUpstream))
			sb.WriteString(fmt.Sprintf("%s}\n", indent))
			sb.WriteString(fmt.Sprintf("%shandle {\n", indent))
			sb.WriteString(fmt.Sprintf("%s\troot %q\n", indent, root))
			sb.WriteString(fmt.Sprintf("%s\ttry_files {path} /index.html\n", indent))
			sb.WriteString(fmt.Sprintf("%s\tfile_server\n", indent))
			sb.WriteString(fmt.Sprintf("%s}\n", indent))
		} else {
			sb.WriteString(fmt.Sprintf("%sroot %q\n", indent, root))
			sb.WriteString(fmt.Sprintf("%stry_files {path} /index.html\n", indent))
			sb.WriteString(fmt.Sprintf("%sfile_server\n", indent))
		}

	case "proxy":
		writeReverseProxy(sb, indent, name, svc, identityHeaders)

	case "split":
		// API path prefix (default: /api)
		apiPath := svc.APIPath
		if apiPath == "" {
			apiPath = "/api"
		}
		// Split into individual path prefixes
		for _, path := range strings.Split(apiPath, ",") {
			path = strings.TrimSpace(path)
			sb.WriteString(fmt.Sprintf("%shandle %s* {\n", indent, path))
			writeReverseProxy(sb, indent+"\t", name, svc, identityHeaders)
			sb.WriteString(fmt.Sprintf("%s}\n", indent))
		}
		// Serve static files for everything else
		root := expandPath(svc.Root, ownerHome)
		sb.WriteString(fmt.Sprintf("%shandle {\n", indent))
		sb.WriteString(fmt.Sprintf("%s\troot %q\n", indent, root))
		sb.WriteString(fmt.Sprintf("%s\ttry_files {path} /index.html\n", indent))
		sb.WriteString(fmt.Sprintf("%s\tfile_server\n", indent))
		sb.WriteString(fmt.Sprintf("%s}\n", indent))
	}
}

// GenerateLaunchdPlist produces a plist XML string for a service.
//
// profile is passed explicitly rather than read from the process environment:
// it is baked into the generated plist, so a generator that consulted ambient
// state would let an unrelated Setenv elsewhere change what gets written to
// disk. An empty profile is a caller bug, not a default — see the pin below.
//
// parentDomain is needed to compute HOME_STACK_SELF_HOST the same way
// GenerateCaddyfile does, so a wrapper's derived URL always matches the
// route the engine actually emits.
//
// configDir is passed in rather than read from the environment here, so the
// function stays pure: the caller (desiredArtifacts) resolves it once via
// the same envOr("HOME_STACK_CONFIG_DIR", ...) fallback GenerateSystemDaemonPlist
// already uses, so HOME_STACK_DATA_DIR honours the same override the daemon
// plist's directories do instead of always assuming ownerHome/.config/home-stack.
func (r *Registry) GenerateLaunchdPlist(name string, svc Service, profile, bundleDir, ownerHome, identifierPrefix, parentDomain, configDir string) (string, error) {
	if profile == "" {
		return "", fmt.Errorf("cannot generate plist for %s: no profile resolved", name)
	}
	label := fmt.Sprintf("%s.home-stack.%s", identifierPrefix, name)
	logDir := filepath.Join(ownerHome, ".config/home-stack/logs")

	var progArgs []string
	if svc.Binary != "" {
		progArgs = append(progArgs, expandPath(svc.Binary, ownerHome))
		for _, arg := range svc.Args {
			progArgs = append(progArgs, expandPath(arg, ownerHome))
		}
	} else {
		// Default: home-stack repo wrapper script
		program := filepath.Join(bundleDir, "scripts", fmt.Sprintf("run-%s.sh", name))
		if name == "logrotate" {
			program = filepath.Join(bundleDir, "scripts", "rotate-logs.sh")
		}
		progArgs = append(progArgs, program)
	}

	var sb strings.Builder
	sb.WriteString(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>`)
	sb.WriteString(xmlText(label))
	sb.WriteString("</string>\n\t<key>ProgramArguments</key>\n\t<array>\n")
	for _, arg := range progArgs {
		sb.WriteString(fmt.Sprintf("\t\t<string>%s</string>\n", xmlText(arg)))
	}
	sb.WriteString("\t</array>\n")

	if svc.WorkingDir != "" {
		sb.WriteString("\t<key>WorkingDirectory</key>\n\t<string>")
		sb.WriteString(xmlText(expandPath(svc.WorkingDir, ownerHome)))
		sb.WriteString("</string>\n")
	}

	// launchd hands an agent the login user's identity but none of the
	// home-stack environment, so the profile is pinned here rather than
	// resolved at service-start time: that resolution falls back to guessing
	// from the username, which only starts for an operator whose name happens
	// to match a profiles/ directory. GenerateSystemDaemonPlist pins it for the
	// same reason. Pinning also freezes the value at generation time, on a
	// machine that demonstrably has the profile, and turns a later mismatch
	// into a loud "profiles/x does not exist" instead of a silent guess.
	//
	// The pin is an invariant, not a default: Validate rejects HOME_STACK_*
	// in a service's own env, so svc.Env can never point one agent at a
	// different profile than the Caddyfile and catalog were generated from.
	// The same is true of the four keys below: a service cannot override its
	// own identity or data directory from the registry.
	selfHost := svc.RoutableHost(parentDomain)
	selfURL := svc.RoutableURL(parentDomain)
	agentEnv := map[string]string{
		"HOME_STACK_PROFILE":   profile,
		"HOME_STACK_SELF_NAME": name,
		"HOME_STACK_SELF_HOST": selfHost,
		"HOME_STACK_SELF_URL":  selfURL,
		"HOME_STACK_DATA_DIR":  filepath.Join(configDir, "data", name),
	}
	for k, v := range svc.Env {
		agentEnv[k] = v
	}
	sb.WriteString("\t<key>EnvironmentVariables</key>\n\t<dict>\n")
	var envKeys []string
	for k := range agentEnv {
		envKeys = append(envKeys, k)
	}
	sort.Strings(envKeys)
	for _, k := range envKeys {
		sb.WriteString(fmt.Sprintf("\t\t<key>%s</key>\n\t\t<string>%s</string>\n", xmlText(k), xmlText(expandPath(agentEnv[k], ownerHome))))
	}
	sb.WriteString("\t</dict>\n")

	sb.WriteString("\t<key>RunAtLoad</key>\n\t<true/>\n")

	// Long-running services are kept alive; scheduled tasks exit when their work
	// is done, so KeepAlive would respawn them in a throttled hot loop. Those get
	// StartInterval instead.
	if svc.IsScheduledTask() {
		sb.WriteString(fmt.Sprintf("\t<key>StartInterval</key>\n\t<integer>%d</integer>\n", svc.StartInterval()))
	} else {
		sb.WriteString("\t<key>KeepAlive</key>\n\t<true/>\n")
	}

	sb.WriteString(fmt.Sprintf(`	<key>StandardOutPath</key>
	<string>%s/%s.launchd.out.log</string>
	<key>StandardErrorPath</key>
	<string>%s/%s.launchd.err.log</string>
</dict>
</plist>`, xmlText(logDir), xmlText(name), xmlText(logDir), xmlText(name)))

	return sb.String(), nil
}

// GenerateSystemDaemonPlist produces the LaunchDaemon plist for a
// type: "system" service (Caddy). Daemons differ from agents: they run
// pre-login as root, need the home-stack environment launchd won't otherwise
// provide, and carry a ThrottleInterval so a crash-looping ingress does not
// spin. Directory layout matches scripts/lib/common.sh defaults; the
// HOME_STACK_* env vars override them the same way they do at runtime.
func (r *Registry) GenerateSystemDaemonPlist(name string, svc Service, profile, bundleDir, ownerHome, identifierPrefix string) (string, error) {
	if profile == "" {
		return "", fmt.Errorf("cannot generate daemon plist for %s: no profile resolved", name)
	}
	label := fmt.Sprintf("%s.home-stack.%s", identifierPrefix, name)
	configDir := envOr("HOME_STACK_CONFIG_DIR", filepath.Join(ownerHome, ".config/home-stack"))
	logDir := envOr("HOME_STACK_LOG_DIR", filepath.Join(configDir, "logs"))
	caddyConfigDir := envOr("HOME_STACK_CADDY_CONFIG_DIR", filepath.Join(configDir, "caddy/config"))
	caddyDataDir := envOr("HOME_STACK_CADDY_DATA_DIR", filepath.Join(configDir, "caddy/data"))
	program := filepath.Join(bundleDir, "scripts", fmt.Sprintf("run-%s.sh", name))

	env := [][2]string{
		{"HOME_STACK_PROFILE", profile},
		{"HOME_STACK_OWNER_HOME", ownerHome},
		{"HOME_STACK_BUNDLE_DIR", bundleDir},
		{"HOME_STACK_CONFIG_DIR", configDir},
		{"HOME", ownerHome},
		{"XDG_CONFIG_HOME", caddyConfigDir},
		{"XDG_DATA_HOME", caddyDataDir},
	}

	var sb strings.Builder
	sb.WriteString(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>`)
	sb.WriteString(xmlText(label))
	sb.WriteString("</string>\n\t<key>ProgramArguments</key>\n\t<array>\n")
	sb.WriteString(fmt.Sprintf("\t\t<string>%s</string>\n", xmlText(program)))
	sb.WriteString("\t</array>\n")
	sb.WriteString(fmt.Sprintf("\t<key>WorkingDirectory</key>\n\t<string>%s</string>\n", xmlText(bundleDir)))
	sb.WriteString("\t<key>EnvironmentVariables</key>\n\t<dict>\n")
	for _, kv := range env {
		sb.WriteString(fmt.Sprintf("\t\t<key>%s</key>\n\t\t<string>%s</string>\n", xmlText(kv[0]), xmlText(kv[1])))
	}
	sb.WriteString("\t</dict>\n")
	sb.WriteString("\t<key>RunAtLoad</key>\n\t<true/>\n\t<key>KeepAlive</key>\n\t<true/>\n\t<key>ThrottleInterval</key>\n\t<integer>10</integer>\n")
	sb.WriteString(fmt.Sprintf(`	<key>StandardOutPath</key>
	<string>%s/%s.launchd.out.log</string>
	<key>StandardErrorPath</key>
	<string>%s/%s.launchd.err.log</string>
</dict>
</plist>`, xmlText(logDir), xmlText(name), xmlText(logDir), xmlText(name)))
	return sb.String(), nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func (s *server) addServiceToRegistry(name string, svc Service) error {
	registryMu.Lock()
	defer registryMu.Unlock()

	profile := os.Getenv("HOME_STACK_PROFILE")
	if profile == "" {
		profile = os.Getenv("USER")
	}
	regPath := registryPath(s.bundleDir, profile)

	r, err := loadRegistry(regPath)
	if err != nil {
		return err
	}

	if r.Services == nil {
		r.Services = make(map[string]Service)
	}
	if _, exists := r.Services[name]; exists {
		return fmt.Errorf("service %q already exists", name)
	}

	r.Services[name] = svc
	parentDomain, err := requiredParentDomain()
	if err != nil {
		return err
	}
	if err := r.Validate(parentDomain); err != nil {
		return err
	}
	return r.saveRegistry(regPath)
}

// generatedArtifacts is everything the registry compiles down to: the
// Caddyfile, every managed service's agent or daemon plist (keyed by service
// name, not path — the writer decides the filename), and the catalog bytes.
type generatedArtifacts struct {
	caddyfile    string
	agentPlists  map[string]string
	daemonPlists map[string]string
	catalog      []byte
}

// buildCatalog projects the registry into the shape written to catalog.json:
// args and env stripped (they can carry secrets or local paths — see the
// Portal projection's stricter sibling in portal.go), and url computed once
// here via RoutableURL so a shell helper reads one authoritative key instead
// of re-deriving the subdomain/host composition itself.
func buildCatalog(r *Registry, parentDomain string) map[string]Service {
	catalog := make(map[string]Service, len(r.Services))
	for name, svc := range r.Services {
		svc.Args = nil
		svc.Env = nil
		svc.URL = svc.RoutableURL(parentDomain)
		catalog[name] = svc
	}
	return catalog
}

// desiredArtifacts computes everything the registry generates, in one place.
// syncSystem, Apply, and Diff each used to hand-roll their own copy of this
// loop, and had already diverged: Apply never generated the daemon plist,
// Diff never compared it, and neither pruned launchd/daemons/. All three now
// build on this single pipeline, so a fix here never needs to be repeated
// twice more, and Diff gets exactly what syncSystem and Apply would write.
func (r *Registry) desiredArtifacts(profile, bundleDir, ownerHome, idPrefix, parentDomain, email, tailnetIP string) (generatedArtifacts, error) {
	if err := validateCaddyToken("email", email, false); err != nil {
		return generatedArtifacts{}, err
	}
	if err := validateCaddyToken("tailnet IP", tailnetIP, false); err != nil {
		return generatedArtifacts{}, err
	}
	if err := validateHost("parent domain", parentDomain); err != nil {
		return generatedArtifacts{}, err
	}
	if idPrefix == "" {
		return generatedArtifacts{}, fmt.Errorf("HOME_STACK_IDENTIFIER_PREFIX is not set")
	}
	if err := validateIdentifierPrefix(idPrefix); err != nil {
		return generatedArtifacts{}, err
	}

	configDir := envOr("HOME_STACK_CONFIG_DIR", filepath.Join(ownerHome, ".config/home-stack"))

	a := generatedArtifacts{
		caddyfile:    r.GenerateCaddyfile(email, tailnetIP, ownerHome, parentDomain),
		agentPlists:  make(map[string]string),
		daemonPlists: make(map[string]string),
	}

	for name, svc := range r.Services {
		switch {
		case svc.Type == "system":
			if !svc.IsEnabled() {
				continue // disabled: no daemon plist either (Validate forbids this anyway)
			}
			// System daemons (Caddy) generate alongside agents so there is
			// exactly one launchd generation pipeline.
			plist, genErr := r.GenerateSystemDaemonPlist(name, svc, profile, bundleDir, ownerHome, idPrefix)
			if genErr != nil {
				return generatedArtifacts{}, genErr
			}
			a.daemonPlists[name] = plist
		case !svc.generatesAgentPlist():
			continue // static routes have no process to supervise; disabled services get no plist
		default:
			plist, genErr := r.GenerateLaunchdPlist(name, svc, profile, bundleDir, ownerHome, idPrefix, parentDomain, configDir)
			if genErr != nil {
				return generatedArtifacts{}, genErr
			}
			a.agentPlists[name] = plist
		}
	}

	catalogData, err := json.MarshalIndent(buildCatalog(r, parentDomain), "", "  ")
	if err != nil {
		return generatedArtifacts{}, fmt.Errorf("failed to marshal catalog: %w", err)
	}
	a.catalog = catalogData

	return a, nil
}

// writeArtifacts materializes generatedArtifacts to disk and prunes any
// stale <idPrefix>.home-stack.*.plist left over in both the agents directory
// and launchd/daemons/ — a service removed from the registry, or newly
// disabled, has its plist deleted the moment it stops being desired, in
// whichever directory it used to live in. install-launchd.sh's own prune
// step keys off what already exists in each directory, so this is what lets
// it actually notice and uninstall a decommissioned or disabled service.
func writeArtifacts(bundleDir, idPrefix string, a generatedArtifacts) ([]string, error) {
	var logs []string

	caddyfilePath := filepath.Join(bundleDir, "Caddyfile")
	if err := os.WriteFile(caddyfilePath, []byte(a.caddyfile), 0644); err != nil {
		return nil, fmt.Errorf("failed to write Caddyfile: %w", err)
	}
	logs = append(logs, "Generated Caddyfile")

	launchdDir := filepath.Join(bundleDir, "launchd")
	if err := os.MkdirAll(launchdDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create launchd dir: %w", err)
	}
	daemonDir := filepath.Join(launchdDir, "daemons")
	if err := os.MkdirAll(daemonDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create launchd daemons dir: %w", err)
	}

	desiredAgents := make(map[string]bool, len(a.agentPlists))
	for name, plist := range a.agentPlists {
		path := filepath.Join(launchdDir, agentPlistFilename(idPrefix, name))
		if err := os.WriteFile(path, []byte(plist), 0644); err != nil {
			return nil, fmt.Errorf("failed to write plist for %s: %w", name, err)
		}
		logs = append(logs, fmt.Sprintf("Generated plist for %s in bundle", name))
		desiredAgents[name] = true
	}
	logs = append(logs, pruneStalePlists(launchdDir, idPrefix, desiredAgents)...)

	desiredDaemons := make(map[string]bool, len(a.daemonPlists))
	for name, plist := range a.daemonPlists {
		path := filepath.Join(daemonDir, agentPlistFilename(idPrefix, name))
		if err := os.WriteFile(path, []byte(plist), 0644); err != nil {
			return nil, fmt.Errorf("failed to write daemon plist for %s: %w", name, err)
		}
		logs = append(logs, fmt.Sprintf("Generated daemon plist for %s in bundle", name))
		desiredDaemons[name] = true
	}
	logs = append(logs, pruneStalePlists(daemonDir, idPrefix, desiredDaemons)...)

	catalogPath := filepath.Join(bundleDir, "catalog.json")
	if err := os.WriteFile(catalogPath, a.catalog, 0644); err != nil {
		return nil, fmt.Errorf("failed to write catalog: %w", err)
	}
	logs = append(logs, "Generated catalog.json")

	return logs, nil
}

func (s *server) syncSystem() (string, error) {
	profile := os.Getenv("HOME_STACK_PROFILE")
	if profile == "" {
		profile = os.Getenv("USER")
	}
	ownerHome := os.Getenv("HOME_STACK_OWNER_HOME")
	if ownerHome == "" {
		return "", fmt.Errorf("HOME_STACK_OWNER_HOME is not set")
	}
	parentDomain, err := requiredParentDomain()
	if err != nil {
		return "", err
	}
	idPrefix := os.Getenv("HOME_STACK_IDENTIFIER_PREFIX")
	if idPrefix == "" {
		return "", fmt.Errorf("HOME_STACK_IDENTIFIER_PREFIX is not set")
	}
	if err := validateIdentifierPrefix(idPrefix); err != nil {
		return "", err
	}

	regPath := registryPath(s.bundleDir, profile)
	if _, statErr := os.Stat(regPath); statErr != nil {
		return "", fmt.Errorf("profile registry not found at %s; set HOME_STACK_PROFILE or USER to a valid profile name, or HOME_STACK_PROFILES_DIR to override the profiles directory", regPath)
	}
	r, err := loadRegistry(regPath)
	if err != nil {
		return "", fmt.Errorf("failed to load registry: %w", err)
	}

	email := os.Getenv("HOME_STACK_ACME_EMAIL")
	if email == "" {
		return "", fmt.Errorf("HOME_STACK_ACME_EMAIL is not set")
	}
	tailnetIP := os.Getenv("HOME_STACK_TAILNET_IP")

	artifacts, err := r.desiredArtifacts(profile, s.bundleDir, ownerHome, idPrefix, parentDomain, email, tailnetIP)
	if err != nil {
		return "", err
	}
	logs, err := writeArtifacts(s.bundleDir, idPrefix, artifacts)
	if err != nil {
		return "", err
	}

	out, err := s.run(context.Background(), filepath.Join(s.bundleDir, "scripts", "reload-caddy.sh"))
	if err != nil {
		return "", fmt.Errorf("failed to reload caddy: %s", out)
	}
	logs = append(logs, "Reloaded Caddy")

	return strings.Join(logs, "\n"), nil
}
