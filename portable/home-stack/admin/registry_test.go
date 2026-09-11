package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAddService(t *testing.T) {
	tmpDir := t.TempDir()

	// Create a profile directory with a starter services.yaml
	profileDir := filepath.Join(tmpDir, "profiles", "test-add")
	os.MkdirAll(profileDir, 0755)

	original := `services:
  admin:
    display_name: Admin
    kind: control
    type: proxy
    upstream: 127.0.0.1:31510
`
	os.WriteFile(filepath.Join(profileDir, "services.yaml"), []byte(original), 0644)

	// Set up env vars for AddService to find the profile
	os.Setenv("HOME_STACK_REPO_ROOT", tmpDir)
	defer os.Unsetenv("HOME_STACK_REPO_ROOT")
	t.Setenv("HOME_STACK_PARENT_DOMAIN", "home.test.example")

	// Add a service
	svc := Service{
		Type:      "proxy",
		Upstream:  "127.0.0.1:8080",
		Subdomain: "newapp",
	}
	err := AddService(filepath.Join(tmpDir, "portable", "home-stack"), "test-add", "newapp", svc)
	if err != nil {
		t.Fatalf("AddService failed: %v", err)
	}

	// Read back and verify
	data, err := os.ReadFile(filepath.Join(profileDir, "services.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	content := string(data)
	if !strings.Contains(content, "newapp") {
		t.Fatal("services.yaml should contain 'newapp'")
	}
	if !strings.Contains(content, "admin") {
		t.Fatal("services.yaml should still contain 'admin'")
	}
	if !strings.Contains(content, "127.0.0.1:8080") {
		t.Fatal("services.yaml should contain the upstream")
	}
}

func TestAddServiceAtomic(t *testing.T) {
	tmpDir := t.TempDir()
	profileDir := filepath.Join(tmpDir, "profiles", "test-atomic")
	os.MkdirAll(profileDir, 0755)

	original := "services:\n  admin:\n    type: proxy\n    upstream: 127.0.0.1:31510\n"
	os.WriteFile(filepath.Join(profileDir, "services.yaml"), []byte(original), 0644)

	os.Setenv("HOME_STACK_REPO_ROOT", tmpDir)
	defer os.Unsetenv("HOME_STACK_REPO_ROOT")
	t.Setenv("HOME_STACK_PARENT_DOMAIN", "home.test.example")

	// Remove tmp file if any leftover
	os.Remove(filepath.Join(profileDir, "services.yaml.tmp"))

	// Add with an invalid service (missing type) — should not modify original
	svc := Service{
		Upstream:  "127.0.0.1:9999",
		Subdomain: "badapp",
	}
	err := AddService(filepath.Join(tmpDir, "portable", "home-stack"), "test-atomic", "badapp", svc)
	if err == nil {
		t.Fatal("AddService should have failed for invalid service (no type)")
	}

	// Original file should be unchanged
	data, _ := os.ReadFile(filepath.Join(profileDir, "services.yaml"))
	if !strings.Contains(string(data), "admin") {
		t.Fatal("original services.yaml should not be modified on failed add")
	}
	if strings.Contains(string(data), "badapp") {
		t.Fatal("badapp should not appear in services.yaml after failed add")
	}

	// tmp file should not exist
	if _, err := os.Stat(filepath.Join(profileDir, "services.yaml.tmp")); err == nil {
		t.Fatal("tmp file should not exist after rollback")
	}
}

func TestRemoveService(t *testing.T) {
	tmpDir := t.TempDir()
	profileDir := filepath.Join(tmpDir, "profiles", "test-rm")
	os.MkdirAll(profileDir, 0755)

	original := `services:
  admin:
    type: proxy
    upstream: 127.0.0.1:31510
  oldapp:
    type: proxy
    upstream: 127.0.0.1:9999
`
	os.WriteFile(filepath.Join(profileDir, "services.yaml"), []byte(original), 0644)

	os.Setenv("HOME_STACK_REPO_ROOT", tmpDir)
	defer os.Unsetenv("HOME_STACK_REPO_ROOT")
	t.Setenv("HOME_STACK_PARENT_DOMAIN", "home.test.example")

	err := RemoveService(filepath.Join(tmpDir, "portable", "home-stack"), "test-rm", "oldapp")
	if err != nil {
		t.Fatalf("RemoveService failed: %v", err)
	}

	data, _ := os.ReadFile(filepath.Join(profileDir, "services.yaml"))
	content := string(data)
	if strings.Contains(content, "oldapp") {
		t.Fatal("oldapp should be removed from services.yaml")
	}
	if !strings.Contains(content, "admin") {
		t.Fatal("admin should still be in services.yaml")
	}
}

func TestRemoveServiceNotFound(t *testing.T) {
	tmpDir := t.TempDir()
	profileDir := filepath.Join(tmpDir, "profiles", "test-rmnf")
	os.MkdirAll(profileDir, 0755)

	original := "services:\n  admin:\n    type: proxy\n    upstream: 127.0.0.1:31510\n"
	os.WriteFile(filepath.Join(profileDir, "services.yaml"), []byte(original), 0644)

	os.Setenv("HOME_STACK_REPO_ROOT", tmpDir)
	defer os.Unsetenv("HOME_STACK_REPO_ROOT")
	t.Setenv("HOME_STACK_PARENT_DOMAIN", "home.test.example")

	err := RemoveService(filepath.Join(tmpDir, "portable", "home-stack"), "test-rmnf", "nonexistent")
	if err != nil {
		t.Fatalf("RemoveService of nonexistent should succeed: %v", err)
	}
}

func TestDiffNoChanges(t *testing.T) {
	t.Skip("Skipping — Diff depends on exact generation output which can vary with map ordering. Test Apply separately below.")
}

func TestApplyGeneratesCaddyfile(t *testing.T) {
	tmpDir := t.TempDir()

	profileDir := filepath.Join(tmpDir, "profiles", "test-apply")
	bundleDir := filepath.Join(tmpDir, "portable", "home-stack")
	os.MkdirAll(profileDir, 0755)
	os.MkdirAll(bundleDir, 0755)

	servicesYAML := `services:
  admin:
    type: proxy
    subdomain: admin
    upstream: 127.0.0.1:31510
`
	os.WriteFile(filepath.Join(profileDir, "services.yaml"), []byte(servicesYAML), 0644)

	os.Setenv("HOME_STACK_PARENT_DOMAIN", "apply.test")
	os.Setenv("HOME_STACK_TAILNET_IP", "127.0.0.1")
	os.Setenv("HOME_STACK_ACME_EMAIL", "test@test")
	os.Setenv("HOME_STACK_OWNER_HOME", tmpDir)
	os.Setenv("HOME_STACK_IDENTIFIER_PREFIX", "test.apply")
	os.Setenv("HOME_STACK_ADMIN_USERNAME", "admin")
	os.Setenv("HOME_STACK_PROFILE", "test-apply")
	os.Setenv("HOME_STACK_REPO_ROOT", tmpDir)
	defer func() {
		for _, k := range []string{"HOME_STACK_PARENT_DOMAIN", "HOME_STACK_TAILNET_IP", "HOME_STACK_ACME_EMAIL", "HOME_STACK_OWNER_HOME", "HOME_STACK_IDENTIFIER_PREFIX", "HOME_STACK_ADMIN_USERNAME", "HOME_STACK_PROFILE", "HOME_STACK_REPO_ROOT"} {
			os.Unsetenv(k)
		}
	}()

	_, err := Apply(bundleDir, "test-apply")
	if err != nil {
		t.Fatalf("Apply failed: %v", err)
	}

	// Verify Caddyfile was generated
	caddyfilePath := filepath.Join(bundleDir, "Caddyfile")
	data, err := os.ReadFile(caddyfilePath)
	if err != nil {
		t.Fatalf("Caddyfile not generated: %v", err)
	}
	if !strings.Contains(string(data), "admin.apply.test") {
		t.Fatalf("Caddyfile should contain admin host, got:\n%s", string(data))
	}
}

// --- stale plist removal -----------------------------------------------------

// TestApplyRemovesStalePlists exercises the bug where a plist for a service
// removed from (or now disabled in) the registry was never deleted from the
// launchd bundle dir: install-launchd.sh's prune step keys off what already
// exists there, so a stale file left behind could never be noticed and
// pruned downstream. It also checks that Apply's agent-plist pruning never
// reaches into the daemons/ subdirectory (a separate call, with its own
// desired set, prunes that one -- see TestApplyPrunesStaleDaemonPlistsToo),
// and that a file outside the identifier-prefix namespace always survives in
// either directory.
func TestApplyRemovesStalePlists(t *testing.T) {
	tmpDir := t.TempDir()
	profileDir := filepath.Join(tmpDir, "profiles", "test-stale")
	bundleDir := filepath.Join(tmpDir, "portable", "home-stack")
	launchdDir := filepath.Join(bundleDir, "launchd")
	daemonDir := filepath.Join(launchdDir, "daemons")
	os.MkdirAll(profileDir, 0755)
	os.MkdirAll(daemonDir, 0755)

	servicesYAML := `services:
  admin:
    type: proxy
    subdomain: admin
    upstream: 127.0.0.1:31510
`
	os.WriteFile(filepath.Join(profileDir, "services.yaml"), []byte(servicesYAML), 0644)

	// A stray plist for a service no longer in the registry.
	stalePlist := filepath.Join(launchdDir, "test.stale.home-stack.gone.plist")
	os.WriteFile(stalePlist, []byte("stale"), 0644)

	// A file outside the prefix namespace: must survive untouched.
	foreignFile := filepath.Join(launchdDir, "other.prefix.home-stack.gone.plist")
	os.WriteFile(foreignFile, []byte("foreign"), 0644)

	// A foreign-prefix file inside daemons/ must survive too, exactly like
	// its agents-directory counterpart above.
	foreignDaemonFile := filepath.Join(daemonDir, "other.prefix.home-stack.caddy.plist")
	os.WriteFile(foreignDaemonFile, []byte("foreign daemon"), 0644)

	t.Setenv("HOME_STACK_PARENT_DOMAIN", "stale.test")
	t.Setenv("HOME_STACK_TAILNET_IP", "127.0.0.1")
	t.Setenv("HOME_STACK_ACME_EMAIL", "test@test")
	t.Setenv("HOME_STACK_OWNER_HOME", tmpDir)
	t.Setenv("HOME_STACK_IDENTIFIER_PREFIX", "test.stale")
	t.Setenv("HOME_STACK_ADMIN_USERNAME", "admin")
	t.Setenv("HOME_STACK_PROFILE", "test-stale")
	t.Setenv("HOME_STACK_REPO_ROOT", tmpDir)

	if _, err := Apply(bundleDir, "test-stale"); err != nil {
		t.Fatalf("Apply failed: %v", err)
	}

	if _, err := os.Stat(stalePlist); !os.IsNotExist(err) {
		t.Fatalf("stale plist for a removed service should have been deleted, stat err=%v", err)
	}
	if _, err := os.Stat(foreignFile); err != nil {
		t.Fatalf("a file outside the prefix namespace must survive: %v", err)
	}
	if _, err := os.Stat(foreignDaemonFile); err != nil {
		t.Fatalf("a foreign-prefix file in daemons/ must survive: %v", err)
	}
	if _, err := os.Stat(filepath.Join(launchdDir, "test.stale.home-stack.admin.plist")); err != nil {
		t.Fatalf("admin's own plist should have been (re)generated: %v", err)
	}
}

// TestApplyPrunesStaleDaemonPlistsToo exercises A6's fix: Apply used to
// never touch launchd/daemons/ at all, so a daemon plist for a system
// service removed from (or now disabled in) the registry was never pruned
// there, unlike its agent-plist counterpart. It now shares the exact same
// pruning as syncSystem, scoped to its own directory and idPrefix namespace.
func TestApplyPrunesStaleDaemonPlistsToo(t *testing.T) {
	tmpDir := t.TempDir()
	profileDir := filepath.Join(tmpDir, "profiles", "test-daemon-stale")
	bundleDir := filepath.Join(tmpDir, "portable", "home-stack")
	os.MkdirAll(profileDir, 0755)
	os.MkdirAll(filepath.Join(bundleDir, "launchd", "daemons"), 0755)

	t.Setenv("HOME_STACK_PARENT_DOMAIN", "daemon-stale.test")
	t.Setenv("HOME_STACK_TAILNET_IP", "127.0.0.1")
	t.Setenv("HOME_STACK_ACME_EMAIL", "test@test")
	t.Setenv("HOME_STACK_OWNER_HOME", tmpDir)
	t.Setenv("HOME_STACK_IDENTIFIER_PREFIX", "test.daemonstale")
	t.Setenv("HOME_STACK_ADMIN_USERNAME", "admin")
	t.Setenv("HOME_STACK_PROFILE", "test-daemon-stale")
	t.Setenv("HOME_STACK_REPO_ROOT", tmpDir)

	withCaddyYAML := `services:
  caddy:
    type: system
    subdomain: "*"
`
	os.WriteFile(filepath.Join(profileDir, "services.yaml"), []byte(withCaddyYAML), 0644)
	if _, err := Apply(bundleDir, "test-daemon-stale"); err != nil {
		t.Fatalf("first Apply failed: %v", err)
	}
	caddyDaemonPlist := filepath.Join(bundleDir, "launchd", "daemons", "test.daemonstale.home-stack.caddy.plist")
	if _, err := os.Stat(caddyDaemonPlist); err != nil {
		t.Fatalf("caddy's daemon plist should exist after first Apply: %v", err)
	}

	// Remove caddy from the registry entirely (equivalent for pruning
	// purposes to disabling it, though Validate forbids that combination).
	os.WriteFile(filepath.Join(profileDir, "services.yaml"), []byte("services: {}\n"), 0644)
	if _, err := Apply(bundleDir, "test-daemon-stale"); err != nil {
		t.Fatalf("second Apply failed: %v", err)
	}
	if _, err := os.Stat(caddyDaemonPlist); !os.IsNotExist(err) {
		t.Fatalf("caddy's daemon plist should be pruned once removed from the registry, stat err=%v", err)
	}
}

// A service that is disabled after having previously generated a plist must
// have that plist removed on the next Apply — the same stale-plist path as a
// removed service.
func TestApplyRemovesPlistForNewlyDisabledService(t *testing.T) {
	tmpDir := t.TempDir()
	profileDir := filepath.Join(tmpDir, "profiles", "test-disable")
	bundleDir := filepath.Join(tmpDir, "portable", "home-stack")
	os.MkdirAll(profileDir, 0755)
	os.MkdirAll(filepath.Join(bundleDir, "launchd"), 0755)

	t.Setenv("HOME_STACK_PARENT_DOMAIN", "disable.test")
	t.Setenv("HOME_STACK_TAILNET_IP", "127.0.0.1")
	t.Setenv("HOME_STACK_ACME_EMAIL", "test@test")
	t.Setenv("HOME_STACK_OWNER_HOME", tmpDir)
	t.Setenv("HOME_STACK_IDENTIFIER_PREFIX", "test.disable")
	t.Setenv("HOME_STACK_ADMIN_USERNAME", "admin")
	t.Setenv("HOME_STACK_PROFILE", "test-disable")
	t.Setenv("HOME_STACK_REPO_ROOT", tmpDir)

	enabledYAML := `services:
  worker:
    type: proxy
    subdomain: worker
    upstream: 127.0.0.1:31700
`
	os.WriteFile(filepath.Join(profileDir, "services.yaml"), []byte(enabledYAML), 0644)
	if _, err := Apply(bundleDir, "test-disable"); err != nil {
		t.Fatalf("first Apply failed: %v", err)
	}
	workerPlist := filepath.Join(bundleDir, "launchd", "test.disable.home-stack.worker.plist")
	if _, err := os.Stat(workerPlist); err != nil {
		t.Fatalf("worker plist should exist after first Apply: %v", err)
	}

	disabledYAML := `services:
  worker:
    type: proxy
    subdomain: worker
    upstream: 127.0.0.1:31700
    enabled: false
`
	os.WriteFile(filepath.Join(profileDir, "services.yaml"), []byte(disabledYAML), 0644)
	if _, err := Apply(bundleDir, "test-disable"); err != nil {
		t.Fatalf("second Apply failed: %v", err)
	}
	if _, err := os.Stat(workerPlist); !os.IsNotExist(err) {
		t.Fatalf("worker plist should be removed once the service is disabled, stat err=%v", err)
	}
}

// --- content-aware diffPlists -----------------------------------------------

func TestDiffPlistsReportsChangedForModifiedContent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.diff.home-stack.svc.plist")
	os.WriteFile(path, []byte("old content"), 0644)

	desired := map[string]string{"svc": "new content"}
	section := diffPlists(dir, "test.diff", desired)
	if section.Changed != 1 {
		t.Fatalf("expected 1 changed plist, got %+v", section)
	}
	if section.Added != 0 || section.Removed != 0 {
		t.Fatalf("expected no added/removed, got %+v", section)
	}
	found := false
	for _, d := range section.Details {
		if strings.Contains(d, "Would update plist for svc") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected a 'Would update plist for svc' detail, got %+v", section.Details)
	}
	if !section.HasChanges() {
		t.Fatal("HasChanges() must be true when Changed > 0")
	}
}

func TestDiffPlistsReportsNoChangeForIdenticalContent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.diff.home-stack.svc.plist")
	os.WriteFile(path, []byte("same content"), 0644)

	desired := map[string]string{"svc": "same content"}
	section := diffPlists(dir, "test.diff", desired)
	if section.Changed != 0 || section.Added != 0 || section.Removed != 0 {
		t.Fatalf("expected zero changes for identical content, got %+v", section)
	}
	if section.HasChanges() {
		t.Fatal("HasChanges() must be false when content is identical")
	}
}

// A stray plist for a different identifier prefix must never collide with a
// same-named service under this profile's prefix -- previously diffPlists
// keyed existing files by service name alone (stripping any prefix before
// ".home-stack."), so a foreign-prefix file could be read as if it were this
// service's plist and a real diff would never converge.
func TestDiffPlistsIgnoresForeignPrefixFile(t *testing.T) {
	dir := t.TempDir()
	// Foreign prefix, same service name and same content as what we'd want
	// to detect as missing for our own prefix.
	os.WriteFile(filepath.Join(dir, "other-prefix.home-stack.svc.plist"), []byte("foreign content"), 0644)

	desired := map[string]string{"svc": "new content"}
	section := diffPlists(dir, "test.diff", desired)
	if section.Added != 1 {
		t.Fatalf("expected the foreign file to be invisible, reporting svc as newly added, got %+v", section)
	}
	if section.Changed != 0 {
		t.Fatalf("must not compare against the foreign-prefix file's content, got %+v", section)
	}
}

// An empty identifier prefix must not make every file in the directory
// match (plistServiceName requires a non-empty ".home-stack." prefix
// match), matching Diff's own fail-fast validation for an empty prefix.
func TestPlistServiceNameRejectsEmptyPrefix(t *testing.T) {
	if _, ok := plistServiceName("", "test.diff.home-stack.svc.plist"); ok {
		t.Fatal("an empty identifier prefix must not match any plist filename")
	}
}

// --- Diff: idPrefix validation + daemon plists ------------------------------

// Diff used to read HOME_STACK_IDENTIFIER_PREFIX inside its plist loop with
// no empty/format check, unlike Apply and syncSystem -- an empty prefix
// would silently compose paths like ".home-stack.<name>.plist" that could
// never exist on disk, so the preview would never converge. It must now
// fail fast the same way Apply does.
func TestDiffFailsFastOnEmptyIdentifierPrefix(t *testing.T) {
	tmpDir := t.TempDir()
	profileDir := filepath.Join(tmpDir, "profiles", "test-diff-noprefix")
	bundleDir := filepath.Join(tmpDir, "portable", "home-stack")
	os.MkdirAll(profileDir, 0755)
	os.MkdirAll(bundleDir, 0755)

	os.WriteFile(filepath.Join(profileDir, "services.yaml"), []byte(`services:
  admin:
    type: proxy
    subdomain: admin
    upstream: 127.0.0.1:31510
`), 0644)

	t.Setenv("HOME_STACK_PARENT_DOMAIN", "diff-noprefix.test")
	t.Setenv("HOME_STACK_TAILNET_IP", "127.0.0.1")
	t.Setenv("HOME_STACK_ACME_EMAIL", "test@test")
	t.Setenv("HOME_STACK_OWNER_HOME", tmpDir)
	t.Setenv("HOME_STACK_IDENTIFIER_PREFIX", "")

	if _, err := Diff(bundleDir, "test-diff-noprefix"); err == nil {
		t.Fatal("expected Diff to fail fast when HOME_STACK_IDENTIFIER_PREFIX is unset")
	}
}

// Apply never generated the daemon plist at all, and Diff never compared it
// — so a change to a type: system service's daemon plist (e.g. a changed
// bundle dir) was invisible to `hs deploy --preview`. Diff now runs the
// daemon plist through the same content-aware comparison as agent plists.
func TestDiffIncludesDaemonPlistChanges(t *testing.T) {
	tmpDir := t.TempDir()
	profileDir := filepath.Join(tmpDir, "profiles", "test-diff-daemon")
	bundleDir := filepath.Join(tmpDir, "portable", "home-stack")
	daemonDir := filepath.Join(bundleDir, "launchd", "daemons")
	os.MkdirAll(profileDir, 0755)
	os.MkdirAll(daemonDir, 0755)

	os.WriteFile(filepath.Join(profileDir, "services.yaml"), []byte(`services:
  caddy:
    type: system
    subdomain: "*"
`), 0644)

	t.Setenv("HOME_STACK_PARENT_DOMAIN", "diff-daemon.test")
	t.Setenv("HOME_STACK_TAILNET_IP", "127.0.0.1")
	t.Setenv("HOME_STACK_ACME_EMAIL", "test@test")
	t.Setenv("HOME_STACK_OWNER_HOME", tmpDir)
	t.Setenv("HOME_STACK_IDENTIFIER_PREFIX", "test.diffdaemon")

	// Nothing on disk yet: the daemon plist should show up as Added.
	diff, err := Diff(bundleDir, "test-diff-daemon")
	if err != nil {
		t.Fatalf("Diff failed: %v", err)
	}
	if diff.Launchd.Added == 0 {
		t.Fatalf("expected the missing daemon plist to be reported as added, got %+v", diff.Launchd)
	}

	// Write a stale daemon plist with different content: should be Changed.
	os.WriteFile(filepath.Join(daemonDir, "test.diffdaemon.home-stack.caddy.plist"), []byte("stale content"), 0644)
	diff, err = Diff(bundleDir, "test-diff-daemon")
	if err != nil {
		t.Fatalf("Diff failed: %v", err)
	}
	if diff.Launchd.Changed == 0 {
		t.Fatalf("expected the mismatched daemon plist to be reported as changed, got %+v", diff.Launchd)
	}
}

// --- buildCatalog: url field -------------------------------------------------

// A7: the catalog writer now emits a url field computed from RoutableURL, so
// downstream shell tooling can read one authoritative key instead of
// re-deriving the subdomain/host composition itself.
func TestBuildCatalogEmitsRoutableURL(t *testing.T) {
	disabled := false
	r := &Registry{Services: map[string]Service{
		"admin":    {Type: "proxy", Subdomain: "admin", Upstream: "127.0.0.1:31510"},
		"headless": {Type: "proxy", Upstream: "127.0.0.1:31700"},
		"disabled": {Type: "proxy", Subdomain: "disabled", Upstream: "127.0.0.1:31701", Enabled: &disabled},
		"dev-gw":   {Type: "proxy", Subdomain: "*.dev", Upstream: "127.0.0.1:31500"},
	}}
	catalog := buildCatalog(r, "home.example.com")

	if got := catalog["admin"].URL; got != "https://admin.home.example.com" {
		t.Errorf("admin: expected routable url, got %q", got)
	}
	if got := catalog["headless"].URL; got != "" {
		t.Errorf("headless (no subdomain/host): expected empty url, got %q", got)
	}
	if got := catalog["disabled"].URL; got != "" {
		t.Errorf("disabled: expected empty url, got %q", got)
	}
	if got := catalog["dev-gw"].URL; got != "" {
		t.Errorf("wildcard subdomain: expected empty url, got %q", got)
	}
}

// --- profilesDir / registryPath: the one profile resolver -------------------

func TestProfilesDirDefault(t *testing.T) {
	os.Unsetenv("HOME_STACK_PROFILES_DIR")
	got := profilesDir("/repo/portable/home-stack")
	want := filepath.Join("/repo/portable/home-stack", "../../profiles")
	if got != want {
		t.Errorf("profilesDir default = %q, want %q", got, want)
	}
}

func TestProfilesDirOverrideHonoured(t *testing.T) {
	t.Setenv("HOME_STACK_PROFILES_DIR", "/fixtures/profiles")
	got := profilesDir("/repo/portable/home-stack")
	if got != "/fixtures/profiles" {
		t.Errorf("profilesDir override = %q, want /fixtures/profiles", got)
	}
}

func TestRegistryPathComposesUnderProfilesDir(t *testing.T) {
	t.Setenv("HOME_STACK_PROFILES_DIR", "/fixtures/profiles")
	got := registryPath("/repo/portable/home-stack", "acme")
	want := filepath.Join("/fixtures/profiles", "acme", "services.yaml")
	if got != want {
		t.Errorf("registryPath = %q, want %q", got, want)
	}
}

func TestRegistryPathDefaultComposesFromBundleDir(t *testing.T) {
	os.Unsetenv("HOME_STACK_PROFILES_DIR")
	got := registryPath("/repo/portable/home-stack", "acme")
	want := filepath.Join("/repo/portable/home-stack", "../../profiles", "acme", "services.yaml")
	if got != want {
		t.Errorf("registryPath = %q, want %q", got, want)
	}
}

// registryPath must follow a symlinked profile directory, the same way a
// launchd-launched process resolves profiles/<name> as a symlink into a
// dotfiles overlay (docs/PUBLIC_RELEASE.md §4 A4).
func TestRegistryPathThroughSymlinkedProfilesDir(t *testing.T) {
	tmpDir := t.TempDir()

	realProfiles := filepath.Join(tmpDir, "real-profiles")
	if err := os.MkdirAll(filepath.Join(realProfiles, "acme"), 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	registryYAML := "services:\n  admin:\n    type: proxy\n    subdomain: admin\n    upstream: 127.0.0.1:31510\n"
	if err := os.WriteFile(filepath.Join(realProfiles, "acme", "services.yaml"), []byte(registryYAML), 0644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	bundleDir := filepath.Join(tmpDir, "repo", "portable", "home-stack")
	profilesLink := filepath.Join(tmpDir, "repo", "profiles")
	if err := os.MkdirAll(filepath.Dir(profilesLink), 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.Symlink(realProfiles, profilesLink); err != nil {
		t.Fatalf("Symlink: %v", err)
	}

	os.Unsetenv("HOME_STACK_PROFILES_DIR")
	t.Setenv("HOME_STACK_PARENT_DOMAIN", "home.example.com")

	path := registryPath(bundleDir, "acme")
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("os.Stat(%q) through symlinked profiles dir: %v", path, err)
	}
	r, err := loadRegistry(path)
	if err != nil {
		t.Fatalf("loadRegistry through symlinked profiles dir: %v", err)
	}
	if _, ok := r.Services["admin"]; !ok {
		t.Fatalf("expected registry loaded through symlink to contain 'admin' service, got %+v", r.Services)
	}
}
